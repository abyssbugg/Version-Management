#!/usr/bin/env bash
# =============================================================================
# Integration tests: p10k project-context segment (display layer)
# =============================================================================
# Contract under test (P3 review, direction b):
#   - config/p10k-project-context.zsh is zsh-parse-clean and sources
#     standalone without noise or nonzero exit.
#   - The chpwd hook regenerates the cache file on directory change with the
#     current project's pin-file state (multi-pin and no-pin directories).
#   - Fail-open: an unwritable cache directory must not crash the shell or
#     leak stale pins, and the callback renders nothing when the cache is
#     unreadable.
#   - DISPLAY-ONLY: the segment never invokes the version manager's machine
#     status API and never installs anything.
# =============================================================================

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 1
SEGMENT="$ROOT_DIR/config/p10k-project-context.zsh"

PASS_COUNT=0
FAIL_COUNT=0

t_pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  ✓ %s\n' "$1"; }
t_fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '  ✗ %s\n' "$1"; }

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

SB="$(mktemp -d "${TMPDIR:-/tmp}/vms-r1-ctx.XXXXXX")"
export XDG_CACHE_HOME="$SB/cache"
export HOME="$SB/home"
mkdir -p "$XDG_CACHE_HOME" "$HOME"

cleanup() {
    # Drivers may leave a chmod-500 cache dir behind on unexpected exits.
    chmod -R u+rwx "$SB/cache" 2>/dev/null
    rm -rf "$SB"
}
trap cleanup EXIT

# Environment shared by every zsh driver (exported once).
export SEGMENT_PATH="$SEGMENT"

# Project fixtures.
PROJ_MULTI="$SB/multi"     # all five pin files
PROJ_OTHER="$SB/other"     # a different single pin
PROJ_EMPTY="$SB/empty"     # no pins at all
mkdir -p "$PROJ_MULTI" "$PROJ_OTHER" "$PROJ_EMPTY"
printf '20.19.2\n' > "$PROJ_MULTI/.nvmrc"
printf '3.12.0\n' > "$PROJ_MULTI/.python-version"
printf '1.22.0\n' > "$PROJ_MULTI/.go-version"
printf '1.79.0\n' > "$PROJ_MULTI/.rust-toolchain"
printf '8.3.0\n' > "$PROJ_MULTI/.php-version"
printf '99.99.99\n' > "$PROJ_OTHER/.nvmrc"
export PROJ_MULTI PROJ_OTHER PROJ_EMPTY

# zsh driver builder: writes the driver to $1 and runs it.
run_zsh_driver() {
    local driver="$1"
    zsh "$driver" > "$SB/driver.out" 2> "$SB/driver.err"
}

# =============================================================================
echo "--- p10k project-context segment integration tests ---"
# =============================================================================

# 1. Parse gate (also enforced by make syntax-check; asserted here directly).
zsh -n "$SEGMENT" 2> "$SB/parse.err"
assert_eq "segment is zsh -n clean" "0" "$?"

# 2. Standalone sourcing: silent, exit 0.
cat > "$SB/standalone.zsh" <<'EOF'
source "$SEGMENT_PATH"
print -r -- standalone-ok
EOF
out="$(SEGMENT_PATH="$SEGMENT" zsh "$SB/standalone.zsh" 2>&1)"
assert_eq "standalone sourcing is silent except its marker" "standalone-ok" "$out"

# 3. Documentation surface: registration + display-only warning present.
seg_src="$(cat "$SEGMENT")"
assert_contains "documents POWERLEVEL9K_CUSTOM_PROJECT_CONTEXT" \
    "POWERLEVEL9K_CUSTOM_PROJECT_CONTEXT" "$seg_src"
assert_contains "carries the display-only warning" "DISPLAY-ONLY" "$seg_src"

# 4. Display-only contract: no machine-status API calls, no install commands.
forbidden="vm_status_json|version-manager\.sh|nvm install|pyenv install|rbenv install|brew install"
if grep -En "$forbidden" "$SEGMENT" > "$SB/forbidden.txt" 2>&1; then
    t_fail "display-only: no forbidden invocations"
    sed 's/^/      hit: /' "$SB/forbidden.txt"
else
    t_pass "display-only: no forbidden invocations"
fi

# 5. chpwd refresh end-to-end: cache tracks the current directory's pins.
cat > "$SB/chpwd.zsh" <<'EOF'
source "$SEGMENT_PATH" || exit 10
CACHE="$_VMS_PROMPT_CTX_CACHE"
cd "$PROJ_MULTI" || exit 12
[[ -s "$CACHE" ]] || exit 13
grep -q $'^node\t20.19.2' "$CACHE" || exit 14
grep -q $'^php\t8.3.0' "$CACHE" || exit 15
cd "$PROJ_OTHER" || exit 16
grep -q $'^node\t99.99.99' "$CACHE" || exit 17
grep -q '20.19.2' "$CACHE" && exit 18
cd "$PROJ_EMPTY" || exit 19
[[ -f "$CACHE" ]] || exit 20
grep -q '99.99.99' "$CACHE" && exit 21
grep -q '20.19.2' "$CACHE" && exit 22
exit 0
EOF
run_zsh_driver "$SB/chpwd.zsh"
rc=$?
if [[ "$rc" -eq 0 ]]; then
    t_pass "chpwd hook refreshes cache on directory change"
else
    t_fail "chpwd hook refreshes cache on directory change (driver exit $rc)"
    sed 's/^/      /' "$SB/driver.out" "$SB/driver.err" 2>/dev/null
fi

# 6. Fail-open: unwritable cache directory — no crash, no stale pin leak.
if [[ "$(id -u)" -eq 0 ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '  ⊘ fail-open unwritable cache dir (running as root — not testable)\n'
else
    cat > "$SB/failopen.zsh" <<'EOF'
# Restore permissions even on unexpected exits so the sandbox can be cleaned.
trap 'chmod 700 "${CACHE:h}" 2>/dev/null; chmod 644 "$CACHE" 2>/dev/null' EXIT
source "$SEGMENT_PATH" || exit 10
CACHE="$_VMS_PROMPT_CTX_CACHE"
mkdir -p "${CACHE:h}" || exit 11
# Unwritable cache: the DIRECTORY blocks creation/unlink, and the FILE's
# mode blocks the >| clobber (truncating an existing file needs file-write,
# not directory-write — both must be locked down to fail the refresh).
chmod 500 "${CACHE:h}" || exit 11
chmod 400 "$CACHE" || exit 11
cd "$PROJ_OTHER" || exit 12
# The refresh must have failed silently; the shell is still alive.
# No stale or new pin content may appear from THIS directory.
if grep -q '99.99.99' "$CACHE" 2>/dev/null; then
    print -r -- "cache contained 99.99.99 despite unwritable cache:"
    ls -ld "${CACHE:h}" "$CACHE" 2>/dev/null
    head -n 5 "$CACHE" 2>/dev/null
    exit 13
fi
chmod 700 "${CACHE:h}" || exit 14
chmod 644 "$CACHE" || exit 14
# Callback renders nothing when the cache is gone.
rm -f -- "$CACHE"
out="$(vms_prompt_context)" || exit 15
[[ -z "$out" ]] || exit 16
exit 0
EOF
    run_zsh_driver "$SB/failopen.zsh"
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
        t_pass "fail-open: unwritable cache degrades silently"
    else
        t_fail "fail-open: unwritable cache degrades silently (driver exit $rc)"
        sed 's/^/      /' "$SB/driver.out" "$SB/driver.err" 2>/dev/null
    fi
fi

# 7. Callback rendering: deterministic hand-written cache -> exact segment.
cat > "$SB/render.zsh" <<'EOF'
source "$SEGMENT_PATH" || exit 10
CACHE="$_VMS_PROMPT_CTX_CACHE"
mkdir -p "${CACHE:h}" || exit 11
print -r -- $'node\t20.19.2\tv20.19.2\t1' >| "$CACHE" || exit 12
out="$(vms_prompt_context)" || exit 13
[[ "$out" == "node:20.19.2→v20.19.2✓" ]] || exit 14
print -r -- $'node\t18.0.0\tv20.19.2\t0' >| "$CACHE" || exit 15
out="$(vms_prompt_context)" || exit 16
[[ "$out" == "node:18.0.0→v20.19.2✗" ]] || exit 17
# pinned but not installed
print -r -- $'rust\t1.79.0\t\t0' >| "$CACHE" || exit 18
out="$(vms_prompt_context)" || exit 19
[[ "$out" == "rust:1.79.0✗" ]] || exit 20
# no pin, active only: informational, no mismatch icon
print -r -- $'go\t\tgo1.22.0\t0' >| "$CACHE" || exit 21
out="$(vms_prompt_context)" || exit 22
[[ "$out" == "go:go1.22.0" ]] || exit 23
# empty cache -> no segment
: >| "$CACHE"
out="$(vms_prompt_context)" || exit 24
[[ -z "$out" ]] || exit 25
# malformed lines are skipped
print -r -- $'garbage-line-without-tabs\nnode\t20.19.2\tv20.19.2\t1' >| "$CACHE" || exit 26
out="$(vms_prompt_context)" || exit 27
[[ "$out" == "node:20.19.2→v20.19.2✓" ]] || exit 28
exit 0
EOF
run_zsh_driver "$SB/render.zsh"
rc=$?
if [[ "$rc" -eq 0 ]]; then
    t_pass "callback rendering: match/mismatch/missing/informational/empty/malformed"
else
    t_fail "callback rendering (driver exit $rc)"
    sed 's/^/      /' "$SB/driver.out" "$SB/driver.err" 2>/dev/null
fi

# =============================================================================
echo ""
echo "====== context-prompt integration summary: passed=$PASS_COUNT failed=$FAIL_COUNT ======"
if (( FAIL_COUNT > 0 )); then
    exit 1
fi
exit 0
