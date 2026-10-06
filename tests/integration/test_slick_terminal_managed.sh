#!/usr/bin/env bash
# P3-1: the font bundle and generated artifacts are one rollback unit.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/tmp_rovodev_slick.XXXXXX")"
SB=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$SB")
trap 'rm -rf -- "$SB"' EXIT
export HOME="$SB/home" TMPDIR="$SB/tmp" XDG_CONFIG_HOME="$SB/home/.config"
export XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
unset TRANSACTION_DRY_RUN BACKUP_DIR TXN_AUDIT_LOG
export LOG_FILE="$HOME/inherited.log"
REPO="$SB/repo's copy"
mkdir -p "$REPO" "$HOME" "$TMPDIR"
ln -s "$ROOT/lib" "$REPO/lib"
if [[ -n "${VMS_TEST_BASELINE:-}" ]]; then
    git -C "$ROOT" show "$VMS_TEST_BASELINE:setup-slick-terminal.sh" >"$REPO/setup-slick-terminal.sh"
else
    cp "$ROOT/setup-slick-terminal.sh" "$REPO/"
fi
SCRIPT="$REPO/setup-slick-terminal.sh"
JSON="$REPO/vscode-terminal-fonts.json"
DEMO="$REPO/test-nerd-font-icons.sh"
FONT="$HOME/Library/Fonts/Meslo Regular.ttf"
printf 'new font one\n' >"$REPO/Meslo Regular.ttf"
printf 'new font two\n' >"$REPO/Meslo Bold.ttf"
export CACHE_MARKER="$HOME/cache-refreshed"
fc-cache() {
    printf '%s\n' "$*" >>"$CACHE_MARKER"
    return "${VMS_CACHE_RC:-0}"
}
export -f fc-cache
failures=0
check() { if "$@"; then printf 'PASS: %s\n' "$1"; else
    printf 'FAIL: %s\n' "$*"
    failures=$((failures + 1))
fi; }
run() { bash "$SCRIPT" "$@" >"$SB/output.log" 2>&1; }
snapshot() {
    python3 - "$HOME" "$REPO" "$TMPDIR" <<'PY'
import os, sys, hashlib
for root in sys.argv[1:]:
    for directory, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(dirs + files):
            path = os.path.join(directory, name)
            if os.path.islink(path): print(path, 'link', os.readlink(path))
            elif os.path.isfile(path): print(path, os.stat(path).st_mode, hashlib.sha256(open(path, 'rb').read()).hexdigest())
            else: print(path, 'dir')
PY
}
before=$(snapshot)
check run --help
check test "$before" = "$(snapshot)"
if run --unknown; then check false; fi
check test "$before" = "$(snapshot)"
check run --dry-run
check test "$before" = "$(snapshot)"
check run
check cmp -s "$FONT" "$REPO/Meslo Regular.ttf"
check python3 - "$JSON" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert len(s) == 17, s
assert s['terminal.integrated.fontFamily'] == 'MesloLGS NF'
assert s['terminal.integrated.fontSize'] == 14
assert s['editor.fontLigatures'] is True
PY
check test -x "$DEMO"
check bash -n "$DEMO"
check grep -q '' "$DEMO"
check grep -q 'Library/Fonts' "$CACHE_MARKER"
before=$(snapshot)
check run
check test "$before" = "$(snapshot)"
# Preserve existing link, target mode and bytes on a real update.
"$(type -P mv)" "$JSON" "$REPO/settings' target.json"
ln -s "settings' target.json" "$JSON"
printf '{"old":true}\n' >"$JSON"
chmod 640 "$REPO/settings' target.json"
check run
check test -L "$JSON"
check test "$(readlink "$JSON")" = "settings' target.json"
check python3 - "$JSON" <<'PY'
import stat, os, sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o640
PY
# A failure at the demo (last target) must restore earlier font/JSON writes.
export VMS_TEST_TARGET="$DEMO"
mv() {
    command mv "$@" || return
    if [[ "${*: -1}" == "$VMS_TEST_TARGET" ]]; then
        printf 'corrupted\n' >"$VMS_TEST_TARGET"
        return "${VMS_MV_RC:-0}"
    fi
}
export -f mv
for code in 0 73; do
    printf 'old font\n' >"$FONT"
    printf '{"old":true}\n' >"$JSON"
    printf '#!/usr/bin/env bash\necho old\n' >"$DEMO"
    cp "$FONT" "$SB/font-before"
    cp "$JSON" "$SB/json-before"
    cp "$DEMO" "$SB/demo-before"
    if VMS_MV_RC="$code" run; then check false; fi
    check cmp -s "$FONT" "$SB/font-before"
    check cmp -s "$JSON" "$SB/json-before"
    check cmp -s "$DEMO" "$SB/demo-before"
    check test -L "$JSON"
    check test -z "$(find "$HOME" "$REPO" -name '.vms-slick.*' -print)"
done
# New-file rollback also prunes only the directories created by the invocation.
rm "$JSON" "$REPO/settings' target.json" "$DEMO" "$HOME/Library/Fonts/"*.ttf
rmdir "$HOME/Library/Fonts" "$HOME/Library"
if VMS_MV_RC=73 run; then check false; fi
check test ! -e "$JSON"
check test ! -e "$DEMO"
check test ! -e "$HOME/Library"
unset -f mv
check run
printf 'different font\n' >"$REPO/Meslo Regular.ttf"
cp "$FONT" "$SB/font-before"
if VMS_CACHE_RC=73 run; then check false; fi
check cmp -s "$FONT" "$SB/font-before"
check grep -q rollback "$HOME/.config/version-manager/audit.log"
# No fonts is a legitimate artifact-only setup; never refresh the font cache.
rm "$REPO/"*.ttf
before=$(snapshot)
check run
check test "$before" = "$(snapshot)"
rm "$JSON"
for kind in dangling directory fifo; do
    if [[ "$kind" == fifo && -n "${VMS_TEST_BASELINE:-}" ]]; then continue; fi
    case "$kind" in
        dangling) ln -s "$SB/missing" "$JSON" ;;
        directory) mkdir "$JSON" ;;
        fifo) mkfifo "$JSON" ;;
    esac
    before=$(snapshot)
    if run; then check false; fi
    check test "$before" = "$(snapshot)"
    if [[ "$kind" == directory ]]; then rmdir "$JSON"; else rm -f "$JSON"; fi
done
# Missing parsers and lock contention fail before publication, without test hooks.
if [[ -z "${VMS_TEST_BASELINE:-}" ]]; then
    before=$(snapshot)
    if bash -c '
        source "$1"
        command() {
            if [[ "$1" == -v && ( "$2" == python3 || "$2" == node ) ]]; then return 1; fi
            builtin command "$@"
        }
        main
    ' bash "$SCRIPT" >"$SB/output.log" 2>&1; then check false; fi
    check test "$before" = "$(snapshot)"
    if bash -c '
        source "$1"
        source "$_VMS_SLICK_ROOT/lib/lock.sh"
        lock_acquire() { return 73; }
        main
    ' bash "$SCRIPT" >"$SB/output.log" 2>&1; then check false; fi
    check test "$before" = "$(snapshot)"
    if command -v node >/dev/null 2>&1; then
        check bash -c '
            source "$1"
            command() {
                if [[ "$1" == -v && "$2" == python3 ]]; then return 1; fi
                builtin command "$@"
            }
            main
        ' bash "$SCRIPT"
    fi
fi
printf 'Slick safety: %s failure(s)\n' "$failures"
[[ "$failures" == 0 ]]
