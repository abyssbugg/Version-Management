#!/usr/bin/env bash
# P3-1 / B1.9: generated settings must never destroy a valid pre-state.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tmp_rovodev_vscode.XXXXXX")"
SANDBOX=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$SANDBOX")
trap 'rm -rf -- "$SANDBOX"' EXIT
export HOME="$SANDBOX/home" XDG_CONFIG_HOME="$SANDBOX/home/.config"
export XDG_CACHE_HOME="$SANDBOX/home/.cache" XDG_DATA_HOME="$SANDBOX/home/.local/share"
export XDG_STATE_HOME="$SANDBOX/home/.local/state"
unset LOG_FILE BACKUP_DIR TRANSACTION_DRY_RUN NVM_DIR
mkdir -p "$HOME"
REPO="$SANDBOX/repo's copy"
mkdir -p "$REPO/scripts" "$REPO/config"
if [[ -n "${VMS_TEST_BASELINE:-}" ]]; then
    baseline="$VMS_TEST_BASELINE"
    [[ "$baseline" != 1 ]] || baseline=40562ee34bbc6de18e9ff1c99a198bcbeba5b397
    git -C "$ROOT" show "$baseline:scripts/generate-vscode-settings.sh" >"$REPO/scripts/generate-vscode-settings.sh"
else
    cp "$ROOT/scripts/generate-vscode-settings.sh" "$REPO/scripts/"
fi
ln -s "$ROOT/lib" "$REPO/lib"
printf '20.19.2\n' >"$REPO/.nvmrc"
SCRIPT="$REPO/scripts/generate-vscode-settings.sh"
TEMPLATE="$REPO/config/vscode-settings.template.json"
OUTPUT="$REPO/vscode-settings.json"
export NVM_DIR="$HOME/nvm & a'quote\"back\\slash"
failures=0
check() {
    if "$@"; then printf 'PASS: %s\n' "$1"; else
        printf 'FAIL: %s\n' "$1"
        failures=$((failures + 1))
    fi
}
run() {
    local rc=0
    bash "$SCRIPT" "$@" >"$SANDBOX/output.log" 2>&1 || rc=$?
    return "$rc"
}
snapshot() {
    python3 - "$REPO" "$HOME" <<'PY'
import hashlib, os, sys
for root in sys.argv[1:]:
    for directory, dirs, files in os.walk(root):
        for name in sorted(dirs + files):
            path = os.path.join(directory, name)
            if os.path.islink(path):
                print(path, 'link', os.readlink(path))
            elif os.path.isfile(path):
                print(path, os.stat(path).st_mode, hashlib.sha256(open(path, 'rb').read()).hexdigest())
            else:
                print(path, 'dir')
PY
}
cp "$ROOT/config/vscode-settings.template.json" "$TEMPLATE"
before="$(snapshot)"
check run --dry-run
check test "$before" = "$(snapshot)"
check run --help
check test "$before" = "$(snapshot)"
if run --unknown; then check false; else check test "$before" = "$(snapshot)"; fi

# Values are data, including quotes, backslashes, ampersands and dollar syntax.
check run
check python3 - "$OUTPUT" <<'PY'
import os, stat, sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o644
PY
check python3 - "$OUTPUT" "$NVM_DIR" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    data = json.load(stream)
assert data['eslint.runtime'] == sys.argv[2] + '/versions/node/20.19.2/bin/node'
assert data['// PLACEHOLDERS'].startswith('All {{PLACEHOLDER}}')
PY
if [[ -f "$OUTPUT" ]]; then
    chmod 640 "$OUTPUT"
    cp -p "$OUTPUT" "$SANDBOX/expected.json"
    before="$(snapshot)"
    check run
    check test "$before" = "$(snapshot)"
fi

# Invalid candidates must not touch existing output or backup/journal state.
printf '{"old":true}\n' >"$OUTPUT"
cp "$OUTPUT" "$SANDBOX/prestate"
for content in '{broken' '{"value":"{{UNKNOWN}}"}'; do
    printf '%s\n' "$content" >"$TEMPLATE"
    before="$(snapshot)"
    if run; then check false; fi
    check cmp -s "$OUTPUT" "$SANDBOX/prestate"
    check test "$before" = "$(snapshot)"
done

# Preserve link topology and content permissions when publishing.
printf '{"value":"{{NVM_DIR}}"}\n' >"$TEMPLATE"
mv "$OUTPUT" "$REPO/target.json"
chmod 640 "$REPO/target.json"
ln -s target.json "$OUTPUT"
check run
check test -L "$OUTPUT"
check test "$(readlink "$OUTPUT")" = target.json
check python3 - "$REPO/target.json" "$NVM_DIR" <<'PY'
import json, os, stat, sys
assert json.load(open(sys.argv[1]))['value'] == sys.argv[2]
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o640
PY

# Root-proof publish corruption forces post-apply verification and rollback.
# The mv shim changes ONLY the generated target after a successful rename.
# It does not intercept backup.sh's cp-based rollback.
mkdir -p "$SANDBOX/bin"
REAL_MV="$(command -v mv)"
export REAL_MV VMS_TEST_TARGET="$REPO/target.json"
cat >"$SANDBOX/bin/mv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
"$REAL_MV" "$@"
if [[ "${*: -1}" == "$VMS_TEST_TARGET" ]]; then
    printf 'invalid JSON\n' > "$VMS_TEST_TARGET"
fi
SH
chmod +x "$SANDBOX/bin/mv"
printf '{"value":"changed"}\n' >"$TEMPLATE"
cp "$REPO/target.json" "$SANDBOX/prestate"
if PATH="$SANDBOX/bin:$PATH" run; then check false; fi
check cmp -s "$REPO/target.json" "$SANDBOX/prestate"
check test -L "$OUTPUT"
check test -f "$XDG_CONFIG_HOME/version-manager/audit.log"
if [[ -f "$XDG_CONFIG_HOME/version-manager/audit.log" ]]; then
    check grep -q rollback "$XDG_CONFIG_HOME/version-manager/audit.log"
fi

# Dangling links fail closed; no new content appears behind them.
rm "$OUTPUT"
ln -s missing.json "$OUTPUT"
before="$(snapshot)"
if run; then check false; fi
check test "$before" = "$(snapshot)"
check test ! -e "$REPO/missing.json"

# Removing a newly published file is also part of rollback, not just restore.
rm "$OUTPUT"
export VMS_TEST_TARGET="$OUTPUT"
if PATH="$SANDBOX/bin:$PATH" run; then check false; fi
check test ! -e "$OUTPUT"
check grep -q rollback "$XDG_CONFIG_HOME/version-manager/audit.log"

# Root-proof failure BEFORE rename preserves the old bytes and removes staging.
cat >"$SANDBOX/bin/mv" <<'SH'
#!/usr/bin/env bash
exit 73
SH
printf '{"old":true}\n' >"$OUTPUT"
cp "$OUTPUT" "$SANDBOX/prestate"
if PATH="$SANDBOX/bin:$PATH" run; then check false; fi
check cmp -s "$OUTPUT" "$SANDBOX/prestate"
check test -z "$(find "$REPO" -name '.vms-vscode.*' -print)"

# A competing generator must never reach publication while this lock is held.
# Mock the shared lock API, not filesystem permissions (valid even as root).
printf '{"value":"lock-contention"}\n' >"$TEMPLATE"
cp "$OUTPUT" "$SANDBOX/prestate"
if bash -c '
    source "$1"
    source "$repo_root/lib/lock.sh"
    lock_acquire() { return 73; }
    main
' bash "$SCRIPT" >"$SANDBOX/output.log" 2>&1; then check false; fi
check cmp -s "$OUTPUT" "$SANDBOX/prestate"

# Explicit parser fallback, hiding discovery only (no host PATH modifications).
if command -v node >/dev/null 2>&1; then
    printf '{"value":"{{NVM_DIR}}","nested":["{{HOME}}"]}\n' >"$TEMPLATE"
    check bash -c '
        source "$1"
        command() {
            if [[ "$1" == -v && "$2" == python3 ]]; then return 1; fi
            builtin command "$@"
        }
        main
    ' bash "$SCRIPT"
    check python3 - "$OUTPUT" "$NVM_DIR" "$HOME" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
assert value == {'value': sys.argv[2], 'nested': [sys.argv[3]]}
PY
else
    printf 'SKIP: Node fallback requires node\n'
fi
before="$(snapshot)"
if bash -c '
    source "$1"
    command() {
        if [[ "$1" == -v && ( "$2" == python3 || "$2" == node ) ]]; then return 1; fi
        builtin command "$@"
    }
    main
' bash "$SCRIPT" >"$SANDBOX/output.log" 2>&1; then check false; fi
check test "$before" = "$(snapshot)"

# Dry-run never sources NVM init or writes through an inherited LOG_FILE.
rm "$REPO/.nvmrc"
mkdir -p "$NVM_DIR"
printf 'touch "$HOME/UNEXPECTED_NVM_SOURCE"\n' >"$NVM_DIR/nvm.sh"
before="$(snapshot)"
check env LOG_FILE="$HOME/preview.log" bash "$SCRIPT" --dry-run
check test "$before" = "$(snapshot)"
check test ! -e "$HOME/UNEXPECTED_NVM_SOURCE"
# Immutable inputs must fail without stranding an immutable staging file.
if [[ "$OSTYPE" == darwin* && -z "${VMS_TEST_BASELINE:-}" ]]; then
    printf '{"value":"immutable-source"}\n' >"$TEMPLATE"
    cp "$OUTPUT" "$SANDBOX/prestate"
    chflags uchg "$OUTPUT"
    if run; then check false; fi
    chflags nouchg "$OUTPUT"
    check cmp -s "$OUTPUT" "$SANDBOX/prestate"
    check test -z "$(find "$REPO" -name '.vms-vscode.*' -print)"
fi
printf 'VS Code mutation regressions: %s failure(s)\n' "$failures"
[[ "$failures" -eq 0 ]]
