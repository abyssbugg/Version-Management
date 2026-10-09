#!/usr/bin/env bash
# =============================================================================
# Unit tests: read-only project status API (vm_status_json / vm_status)
# =============================================================================
# Contract under test (P3 review, direction b):
#   - `version-manager.sh status-json` emits one valid JSON object:
#     {"project": "<cwd>", "runtime": {"<name>": {"expected": str|null,
#      "active": str|null, "match": bool}, ...}}
#   - expected comes from pin files (.nvmrc, .python-version, .go-version,
#     .rust-toolchain, .php-version); active from the installed runtimes.
#   - Fail-open: absent runtimes / missing pins never fail the command.
#   - match is true iff both sides are present and equal after
#     normalization (one leading 'v' / 'go' prefix stripped).
#   - ZERO writes: no XDG/config/cache/state directories are created and
#     the project directory is byte-identical after the run.
#
# Runtime isolation: every invocation runs under `env -i` with a strict
# PATH built from an allowlisted bin dir, so host runtimes cannot leak
# into assertions. Runtime shims live in a per-case mock dir.
# =============================================================================

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
VM_SCRIPT="$ROOT_DIR/version-manager.sh"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

t_pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  ✓ %s\n' "$1"; }
t_fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  ✗ %s\n' "$1"; }
t_skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); printf '  ⊘ %s\n' "$1"; }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        t_pass "$label"
    else
        t_fail "$label"
        printf '      expected: %q\n      actual:   %q\n' "$expected" "$actual"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        t_pass "$label"
    else
        t_fail "$label"
        printf '      expected to contain: %q\n      actual: %q\n' "$needle" "$haystack"
    fi
}

assert_file_absent() {
    local label="$1" path="$2"
    if [[ ! -e "$path" ]]; then
        t_pass "$label"
    else
        t_fail "$label"
        printf '      unexpectedly exists: %q\n' "$path"
    fi
}

# Real python3, captured BEFORE any PATH manipulation. Used to validate the
# machine output; also baked into the python3 shim so that the status API's
# preferred assembly path keeps working under the mock.
PY_REAL="$(command -v python3 2>/dev/null || true)"
HAVE_PY=0
if [[ -n "$PY_REAL" ]] && "$PY_REAL" -c 'import json' >/dev/null 2>&1; then
    HAVE_PY=1
fi

# Strict bin dir: only the coreutils the script (and lib sourcing) needs —
# deliberately NOT node/python3/go/rustc/php, so the host cannot leak.
STRICTBIN="$(mktemp -d "${TMPDIR:-/tmp}/vms-r1-strictbin.XXXXXX")"
for util in bash sh env dirname basename date head tail cat tr awk sed grep \
    sort cut ls mkdir rmdir rm cp mv touch uname sleep printf true false \
    test '[' find readlink; do
    src="$(command -v "$util" 2>/dev/null || true)"
    [[ -n "$src" ]] && ln -sf "$src" "$STRICTBIN/$util"
done

cleanup() {
    [[ -n "${SB:-}" && "$SB" == */vms-r1-status.* ]] && rm -rf "$SB"
    rm -rf "$STRICTBIN"
}
trap cleanup EXIT

# new_case <case-name>: fresh sandbox with home/, proj/, bin/ dirs.
# Sets SB, HOME_DIR, PROJ, MOCKBIN, OUT. PROJ is canonicalized through
# pwd -P so assertions match the CLI's own project detection (macOS /private
# prefix, TMPDIR double slashes).
new_case() {
    SB="$(mktemp -d "${TMPDIR:-/tmp}/vms-r1-status.XXXXXX")"
    HOME_DIR="$SB/home"
    MOCKBIN="$SB/bin"
    OUT="$SB/out.json"
    mkdir -p "$HOME_DIR" "$SB/proj" "$MOCKBIN"
    PROJ="$(cd "$SB/proj" && pwd -P)"
}

# write_pin <name> <content>: create a pin file in $PROJ.
write_pin() {
    printf '%s\n' "$2" > "$PROJ/$1"
}

# make_runtime_shims: fill $MOCKBIN with deterministic runtime shims.
# The python3 shim mocks only `--version` and delegates everything else
# (including the JSON assembly and -m json.tool) to the real python3.
make_runtime_shims() {
    printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "--version" ]]; then echo "v20.19.2"; exit 0; fi\nexit 1\n' > "$MOCKBIN/node"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'if [[ "${1:-}" == "--version" ]]; then echo "Python 3.12.0"; exit 0; fi\n'
        if [[ -n "$PY_REAL" ]]; then
            printf 'exec "%s" "$@"\n' "$PY_REAL"
        else
            printf 'exit 1\n'
        fi
    } > "$MOCKBIN/python3"
    printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "version" ]]; then echo "go version go1.22.0 darwin/arm64"; exit 0; fi\nexit 1\n' > "$MOCKBIN/go"
    printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "--version" ]]; then echo "rustc 1.79.0 (abc123 2024-01-01)"; exit 0; fi\nexit 1\n' > "$MOCKBIN/rustc"
    printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "--version" ]]; then echo "PHP 8.3.0 (cli)"; echo "Copyright (c) The PHP Group"; exit 0; fi\nexit 1\n' > "$MOCKBIN/php"
    chmod +x "$MOCKBIN"/*
}

# run_status_json: execute the CLI inside $PROJ with the given PATH
# (pass "strict" for no runtimes, "mock" for shims). Output -> $OUT.
# Args after the mode are extra env assignments (NAME=value).
run_status_json() {
    local mode="$1"
    shift
    local run_path="$STRICTBIN"
    if [[ "$mode" == "mock" ]]; then
        run_path="$MOCKBIN:$STRICTBIN"
    fi
    (
        cd "$PROJ" || exit 99
        exec env -i HOME="$HOME_DIR" PATH="$run_path" "$@" \
            bash "$VM_SCRIPT" status-json
    ) > "$OUT" 2>"$SB/err.txt"
}

# run_status: human variant, same conventions, output -> $OUT.
run_status() {
    local mode="$1"
    shift
    local run_path="$STRICTBIN"
    if [[ "$mode" == "mock" ]]; then
        run_path="$MOCKBIN:$STRICTBIN"
    fi
    (
        cd "$PROJ" || exit 99
        exec env -i HOME="$HOME_DIR" PATH="$run_path" "$@" \
            bash "$VM_SCRIPT" status
    ) > "$OUT" 2>"$SB/err.txt"
}

# json_get <file> <key>... : print the value at the nested key path, or the
# literal string "null" for a missing/null field; booleans become true/false.
json_get() {
    local f="$1"
    shift
    "$PY_REAL" - "$f" "$@" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
cur = data
for k in sys.argv[2:]:
    if isinstance(cur, dict):
        cur = cur.get(k)
    else:
        cur = None
    if cur is None:
        break
if cur is None:
    print("null")
elif isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print(cur)
PYEOF
}

# =============================================================================
echo "--- status API unit tests ---"
# =============================================================================

# 1. Happy path: all five runtimes pinned and mocked; every value asserted.
if [[ "$HAVE_PY" -eq 1 ]]; then
    new_case
    make_runtime_shims
    write_pin ".nvmrc" "20.19.2"
    write_pin ".python-version" "3.12.0"
    write_pin ".go-version" "1.22.0"
    write_pin ".rust-toolchain" "1.79.0"
    write_pin ".php-version" "8.3.0"
    run_status_json mock
    assert_eq "happy path: exit 0" "0" "$?"
    "$PY_REAL" -m json.tool "$OUT" >/dev/null 2>&1
    assert_eq "happy path: output is valid JSON (python3 -m json.tool)" "0" "$?"
    assert_contains "happy path: project is the cwd" "$PROJ" "$(cat "$OUT")"
    assert_eq "happy path: node.expected" "20.19.2" "$(json_get "$OUT" runtime node expected)"
    assert_eq "happy path: node.active" "v20.19.2" "$(json_get "$OUT" runtime node active)"
    assert_eq "happy path: node.match" "true" "$(json_get "$OUT" runtime node match)"
    assert_eq "happy path: python.match" "true" "$(json_get "$OUT" runtime python match)"
    # TEMP CI DIAGNOSTIC (remove once the Linux python.match regression is
    # root-caused): on failure, surface the values the macOS host cannot show.
    if [[ "$(json_get "$OUT" runtime python match)" != "true" ]]; then
        printf '  ✗ [diag] python.expected=%q python.active=%q\n' \
            "$(json_get "$OUT" runtime python expected)" \
            "$(json_get "$OUT" runtime python active)"
        printf '  ✗ [diag] shim --version (harness env) => %q\n' \
            "$(PATH="$MOCKBIN:$STRICTBIN" python3 --version 2>&1 | head -n1)"
        printf '  ✗ [diag] shim --version (env -i, status PATH) => %q\n' \
            "$(env -i HOME="$HOME_DIR" PATH="$MOCKBIN:$STRICTBIN" python3 --version 2>&1 | head -n1)"
        printf '  ✗ [diag] cat shim: %q\n' "$(cat "$MOCKBIN/python3" 2>&1)"
        printf '  ✗ [diag] env -i bash present => %q\n' \
            "$(env -i PATH="$MOCKBIN:$STRICTBIN" command -v bash 2>&1 || echo MISSING)"
    fi
    assert_eq "happy path: go.active (toolchain-reported form)" "go1.22.0" "$(json_get "$OUT" runtime go active)"
    assert_eq "happy path: go.match (go-prefix normalized)" "true" "$(json_get "$OUT" runtime go match)"
    assert_eq "happy path: rust.match" "true" "$(json_get "$OUT" runtime rust match)"
    assert_eq "happy path: php.match" "true" "$(json_get "$OUT" runtime php match)"
else
    t_skip "happy path (python3 unavailable — JSON validation skipped)"
fi

# 2. Mismatch + v-prefix normalization on the pin side.
if [[ "$HAVE_PY" -eq 1 ]]; then
    new_case
    make_runtime_shims
    write_pin ".nvmrc" "18.0.0"
    write_pin ".python-version" "v3.12.0"
    run_status_json mock
    assert_eq "mismatch: exit 0" "0" "$?"
    assert_eq "mismatch: node.match is false" "false" "$(json_get "$OUT" runtime node match)"
    assert_eq "mismatch: python pin 'v3.12.0' normalizes to match" "true" "$(json_get "$OUT" runtime python match)"
else
    t_skip "mismatch (python3 unavailable)"
fi

# 3. Fail-open: pin files present, NO runtimes on PATH.
if [[ "$HAVE_PY" -eq 1 ]]; then
    new_case
    write_pin ".nvmrc" "20.19.2"
    write_pin ".go-version" "1.22.0"
    run_status_json strict
    assert_eq "fail-open (no runtimes): exit 0" "0" "$?"
    "$PY_REAL" -m json.tool "$OUT" >/dev/null 2>&1
    assert_eq "fail-open (no runtimes): valid JSON" "0" "$?"
    assert_eq "fail-open: node.expected preserved" "20.19.2" "$(json_get "$OUT" runtime node expected)"
    assert_eq "fail-open: node.active is null" "null" "$(json_get "$OUT" runtime node active)"
    assert_eq "fail-open: node.match is false" "false" "$(json_get "$OUT" runtime node match)"
else
    t_skip "fail-open no-runtimes (python3 unavailable)"
fi

# 4. Fail-open: no pins, no runtimes -> empty runtime object.
if [[ "$HAVE_PY" -eq 1 ]]; then
    new_case
    run_status_json strict
    assert_eq "no pins no runtimes: exit 0" "0" "$?"
    "$PY_REAL" -m json.tool "$OUT" >/dev/null 2>&1
    assert_eq "no pins no runtimes: valid JSON" "0" "$?"
    assert_eq "no pins no runtimes: runtime is empty object" "{}" "$(json_get "$OUT" runtime | tr -d ' ')"
    assert_eq "no pins no runtimes: project is cwd" "$PROJ" "$(json_get "$OUT" project)"
else
    t_skip "no pins no runtimes (python3 unavailable)"
fi

# 5. Active runtime without a pin file: reported with expected=null.
if [[ "$HAVE_PY" -eq 1 ]]; then
    new_case
    make_runtime_shims
    run_status_json mock
    assert_eq "active without pin: exit 0" "0" "$?"
    assert_eq "active without pin: node.expected is null" "null" "$(json_get "$OUT" runtime node expected)"
    assert_eq "active without pin: node.active detected" "v20.19.2" "$(json_get "$OUT" runtime node active)"
    assert_eq "active without pin: node.match is false" "false" "$(json_get "$OUT" runtime node match)"
else
    t_skip "active without pin (python3 unavailable)"
fi

# 6. printf fallback: JSON stays valid when python3 is unavailable.
new_case
make_runtime_shims
rm -f "$MOCKBIN/python3"   # shim delegates to real python3; remove it so the
                           # status API finds NO python3 -> documented fallback
write_pin ".nvmrc" "20.19.2"
write_pin ".php-version" "8.3.0"
(
    cd "$PROJ" || exit 99
    exec env -i HOME="$HOME_DIR" PATH="$MOCKBIN:$STRICTBIN" bash "$VM_SCRIPT" status-json
) > "$OUT" 2>"$SB/err.txt"
assert_eq "printf fallback: exit 0" "0" "$?"
assert_contains "printf fallback: node entry present" '"node"' "$(cat "$OUT")"
assert_contains "printf fallback: match literal true" '"match":true' "$(cat "$OUT")"
if [[ "$HAVE_PY" -eq 1 ]]; then
    "$PY_REAL" -m json.tool "$OUT" >/dev/null 2>&1
    assert_eq "printf fallback: output is valid JSON" "0" "$?"
    assert_eq "printf fallback: node.match" "true" "$(json_get "$OUT" runtime node match)"
else
    t_skip "printf fallback JSON validation (python3 unavailable)"
fi

# 7. Garbage pin content: still valid JSON, match=false, exit 0.
if [[ "$HAVE_PY" -eq 1 ]]; then
    new_case
    make_runtime_shims
    printf 'he said "hi" \\ back\n' > "$PROJ/.nvmrc"
    run_status_json mock
    assert_eq "garbage pin: exit 0" "0" "$?"
    "$PY_REAL" -m json.tool "$OUT" >/dev/null 2>&1
    assert_eq "garbage pin: valid JSON (escaped by python3)" "0" "$?"
    assert_eq "garbage pin: node.match is false" "false" "$(json_get "$OUT" runtime node match)"
else
    t_skip "garbage pin (python3 unavailable)"
fi

# 8. Read-only proof: fresh HOME, strict PATH — no XDG dirs appear and the
# project directory is byte-identical after the run.
new_case
make_runtime_shims
write_pin ".nvmrc" "20.19.2"
printf 'x\n' > "$PROJ/.keep"
proj_before="$(find "$PROJ" -type f | sort)"
home_before="$(find "$HOME_DIR" -mindepth 1 | sort)"
run_status_json mock
assert_eq "read-only: exit 0" "0" "$?"
assert_eq "read-only: project tree unchanged" "$proj_before" "$(find "$PROJ" -type f | sort)"
assert_eq "read-only: HOME tree unchanged" "$home_before" "$(find "$HOME_DIR" -mindepth 1 | sort)"
assert_file_absent "read-only: no .cache created" "$HOME_DIR/.cache"
assert_file_absent "read-only: no .config created" "$HOME_DIR/.config"
assert_file_absent "read-only: no .local created" "$HOME_DIR/.local"

# 9. Human variant: same data, plain text, exit 0.
new_case
make_runtime_shims
write_pin ".nvmrc" "18.0.0"
run_status mock
assert_eq "human variant: exit 0" "0" "$?"
human_out="$(cat "$OUT")"
assert_contains "human variant: project line" "project:" "$human_out"
assert_contains "human variant: node row" "node" "$human_out"
assert_contains "human variant: expected column" "expected:" "$human_out"
assert_contains "human variant: mismatch surfaced" "MISMATCH" "$human_out"

# 10. Human variant, empty project: informational, exit 0.
new_case
run_status strict
assert_eq "human variant empty: exit 0" "0" "$?"
assert_contains "human variant empty: informational line" "no pin files" "$(cat "$OUT")"

# 11. Direct function contract: sourcing must define the API and the
# private normalizer must behave (canary-lesson: no lib may disturb this).
SRC_SCRIPT="$SB/src-contract.sh"
cat > "$SRC_SCRIPT" <<'EOF'
set -uo pipefail
source "$VM_SCRIPT_PATH"
declare -F vm_status_json >/dev/null 2>&1 || exit 2
declare -F vm_status >/dev/null 2>&1 || exit 3
[[ "$(_vm_status_normalize "v20.19.2")" == "20.19.2" ]] || exit 4
[[ "$(_vm_status_normalize "go1.22.0")" == "1.22.0" ]] || exit 5
[[ "$(_vm_status_normalize "1.79.0")" == "1.79.0" ]] || exit 6
exit 0
EOF
VM_SCRIPT_PATH="$VM_SCRIPT" bash "$SRC_SCRIPT" >/dev/null 2>&1
src_rc=$?
assert_eq "source contract: API + normalizer" "0" "$src_rc"

# =============================================================================
echo ""
echo "====== status-json unit summary: passed=$PASS_COUNT failed=$FAIL_COUNT skipped=$SKIP_COUNT ======"
if (( FAIL_COUNT > 0 )); then
    exit 1
fi
exit 0
