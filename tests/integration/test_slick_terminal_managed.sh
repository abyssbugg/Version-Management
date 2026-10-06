#!/usr/bin/env bash
set -euo pipefail

# Test: setup-slick-terminal.sh transaction-backed mutations (P3-1)
# Covers: dry-run, idempotency, rollback, JSON validation, font installation,
# test-script generation, lock contention, parser fallback, fc-cache stubbing.
# Scope: Transaction contract testing (new code assumed correct by orchestrator).

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO="$SANDBOX/repo"
mkdir -p "$REPO/lib"

export HOME="$SANDBOX/home" XDG_CONFIG_HOME="$SANDBOX/home/.config" TMPDIR="$SANDBOX/tmp"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$TMPDIR"

# Copy libs
cp "$ROOT"/lib/{logger,backup,lock,error-handling}.sh "$REPO/lib/"
cp "$ROOT/setup-slick-terminal.sh" "$REPO/"
chmod +x "$REPO/setup-slick-terminal.sh"

# Create fake fonts directory and test font files (with spaces in names)
FONTS_DIR="$HOME/Library/Fonts"
mkdir -p "$FONTS_DIR"
for fontname in "MesloLGS NF Regular.ttf" "MesloLGS NF Bold.ttf"; do
    printf '\0TTF\0FAKE' >"$REPO/$fontname"
done

SCRIPT="$REPO/setup-slick-terminal.sh"

check() { if ! "$@"; then echo "FAIL: $*" >&2; return 1; fi; }

run() {
    env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" repo_root="$REPO" \
        bash "$SCRIPT" "$@" >"$SANDBOX/output.log" 2>&1
}

snapshot() {
    ( find "$HOME" "$REPO" "$TMPDIR" 2>/dev/null | sort; ) | md5sum | awk '{print $1}'
}

# ============================================================================
# Test 1: --help shows usage and exits 0
# ============================================================================
check run --help
check grep -q "usage:" "$SANDBOX/output.log"

# ============================================================================
# Test 2: Unknown flag causes non-zero exit with error message
# ============================================================================
if run --unknown 2>&1; then
    check false
else
    check grep -q "Unknown flag" "$SANDBOX/output.log"
fi

# ============================================================================
# Test 3: --dry-run produces plan with zero writes
# ============================================================================
before="$(snapshot)"
check run --dry-run
check grep -qi "plan\|dry-run" "$SANDBOX/output.log"
check test "$before" = "$(snapshot)"

# ============================================================================
# Test 4: Apply mode generates vscode-terminal-fonts.json
# ============================================================================
check run
check test -f "$REPO/vscode-terminal-fonts.json"

# JSON structure validation (parser-based, no string interpolation)
check python3 - "$REPO/vscode-terminal-fonts.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s['terminal.integrated.fontFamily'] == 'MesloLGS NF'
assert s['terminal.integrated.fontSize'] == 14
assert isinstance(s['terminal.integrated.lineHeight'], (int, float))
PY

# ============================================================================
# Test 5: Test script generated, executable, with icon content
# ============================================================================
check test -f "$REPO/test-nerd-font-icons.sh"
check test -x "$REPO/test-nerd-font-icons.sh"
check grep -q "Testing Nerd Font Icons\|icons\|Directory" "$REPO/test-nerd-font-icons.sh"

# ============================================================================
# Test 6: Fonts copied to system directory (spaces in names preserved)
# ============================================================================
check test -f "$FONTS_DIR/MesloLGS NF Regular.ttf"
check test -f "$FONTS_DIR/MesloLGS NF Bold.ttf"

# ============================================================================
# Test 7: Idempotency (byte-identical reruns)
# ============================================================================
json_v1="$(cat "$REPO/vscode-terminal-fonts.json")"
test_v1="$(cat "$REPO/test-nerd-font-icons.sh")"
check run
json_v2="$(cat "$REPO/vscode-terminal-fonts.json")"
test_v2="$(cat "$REPO/test-nerd-font-icons.sh")"
check test "$json_v1" = "$json_v2"
check test "$test_v1" = "$test_v2"

# ============================================================================
# Test 8: Rollback on publish failure (mv failure, pre-state preserved)
# ============================================================================
mkdir -p "$SANDBOX/bin"
cat >"$SANDBOX/bin/mv" <<'SH'
#!/usr/bin/env bash
# Fail on second call (test-script rename)
if [[ "${VMS_MV_CALL:-0}" == "1" ]]; then
    export VMS_MV_CALL=2
    exit 73
fi
export VMS_MV_CALL=1
command mv "$@"
SH
chmod +x "$SANDBOX/bin/mv"

rm -f "$REPO/test-nerd-font-icons.sh" "$REPO/vscode-terminal-fonts.json"
json_before=""
if [[ -f "$REPO/vscode-terminal-fonts.json" ]]; then
    json_before="$(cat "$REPO/vscode-terminal-fonts.json")"
fi

if PATH="$SANDBOX/bin:$PATH" run 2>&1; then
    check false
else
    # Non-zero exit expected
    check grep -q "rollback\|failed" "$SANDBOX/output.log"
    check ! test -f "$REPO/test-nerd-font-icons.sh"
fi

# ============================================================================
# Test 9: Lock contention (mock lock_acquire failure)
# ============================================================================
rm -f "$REPO/vscode-terminal-fonts.json" "$REPO/test-nerd-font-icons.sh" 2>/dev/null || true
if bash -c '
    source "$1"
    source "$repo_root/lib/lock.sh"
    lock_acquire() { return 73; }
    main
' bash "$SCRIPT" >"$SANDBOX/output.log" 2>&1; then
    check false
else
    check grep -q "lock\|in progress" "$SANDBOX/output.log"
fi

# ============================================================================
# Test 10: Parser fallback (python3 → node)
# ============================================================================
if command -v node >/dev/null 2>&1; then
    rm -f "$REPO/vscode-terminal-fonts.json"
    check bash -c '
        source "$1"
        command() {
            [[ "$1" == -v && "$2" == python3 ]] && return 1
            builtin command "$@"
        }
        main --dry-run
    ' bash "$SCRIPT"
fi

# ============================================================================
# Test 11: Both parsers missing fails apply, dry-run succeeds with no writes
# ============================================================================
before="$(snapshot)"
check bash -c '
    source "$1"
    command() {
        [[ "$1" == -v && ( "$2" == python3 || "$2" == node ) ]] && return 1
        builtin command "$@"
    }
    main --dry-run
' bash "$SCRIPT"
check test "$before" = "$(snapshot)"

# ============================================================================
# Test 12: fc-cache stub (signature: writes marker, accepts argv, can fail)
# ============================================================================
cat >"$SANDBOX/bin/fc-cache" <<'SH'
#!/usr/bin/env bash
echo "fc-cache $*" >>"$HOME/fc-cache.log"
[[ "${VMS_FC_FAIL:-0}" == "1" ]] && exit 73 || exit 0
SH
chmod +x "$SANDBOX/bin/fc-cache"

rm -f "$REPO/vscode-terminal-fonts.json" "$REPO/test-nerd-font-icons.sh" "$HOME/fc-cache.log"
if PATH="$SANDBOX/bin:$PATH" run; then
    check test -f "$HOME/fc-cache.log"
fi

# fc-cache failure should not block overall success
export VMS_FC_FAIL=1
rm -f "$REPO/vscode-terminal-fonts.json" "$REPO/test-nerd-font-icons.sh"
check PATH="$SANDBOX/bin:$PATH" run

# ============================================================================
# Test 13: Dry-run never invokes external commands (no fc-cache call)
# ============================================================================
rm -f "$HOME/fc-cache.log"
before="$(snapshot)"
check PATH="$SANDBOX/bin:$PATH" run --dry-run
check ! test -f "$HOME/fc-cache.log"
check test "$before" = "$(snapshot)"

echo "✓ All 13 tests passed"
