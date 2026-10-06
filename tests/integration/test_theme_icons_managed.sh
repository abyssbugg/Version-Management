#!/usr/bin/env bash
# P3-1: actual icon edits, literal input, zero-write previews and rollback.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/tmp_rovodev_icons.XXXXXX")"
SB=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$SB")
trap 'rm -rf -- "$SB"' EXIT
export HOME="$SB/home" TMPDIR="$SB/tmp" XDG_CONFIG_HOME="$SB/home/.config"
export XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
unset BACKUP_DIR TRANSACTION_DRY_RUN TXN_AUDIT_LOG
export LOG_FILE="$HOME/inherited.log"
REPO="$SB/repo's copy"
mkdir -p "$HOME" "$TMPDIR" "$REPO/scripts" "$REPO/config"
ln -s "$ROOT/lib" "$REPO/lib"
if [[ -n "${VMS_TEST_BASELINE:-}" ]]; then
    git -C "$ROOT" show "$VMS_TEST_BASELINE:scripts/theme-icon-manager.sh" >"$REPO/scripts/theme-icon-manager.sh"
else
    cp "$ROOT/scripts/theme-icon-manager.sh" "$REPO/scripts/"
fi
cp "$ROOT"/config/*-p10k.zsh "$REPO/config/"
SCRIPT="$REPO/scripts/theme-icon-manager.sh"
FILE="$HOME/.p10k.zsh"
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
fixture() {
    cat >"$FILE" <<'ZSH'
# untouched comment
 typeset -g POWERLEVEL9K_OS_ICON_CONTENT_EXPANSION='📁'
 typeset -g POWERLEVEL9K_FOLDER_ICON='📂'
 typeset -g POWERLEVEL9K_VCS_BRANCH_ICON='old '
 typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_CONTENT_EXPANSION='a'
 typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_VICMD_CONTENT_EXPANSION='b'
 typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_VIINS_CONTENT_EXPANSION='error'
ZSH
}
fixture
before=$(snapshot)
check run --fix --dry-run
check test "$before" = "$(snapshot)"
check run --dry-run --reset
check test "$before" = "$(snapshot)"
check run --preview
check run --help
check test "$before" = "$(snapshot)"
if run --fix --reset; then check false; fi
if run --unknown; then check false; fi
check test "$before" = "$(snapshot)"
check run --customize <<<'5'
check run --customize </dev/null
check test "$before" = "$(snapshot)"
check run --fix
check grep -q '' "$FILE"
check grep -q '' "$FILE"
before=$(snapshot)
check run --fix
check test "$before" = "$(snapshot)"
# Controlled fixture only: verify assignment values, not a real user config.
icon="quote' slash/ pipe| amp& back\\ \$(touch \"$HOME/EXECUTED\")"
for choice in 1 2 3 4; do
    fixture
    before=$(snapshot)
    check run --customize --dry-run <<<"$choice
$icon"
    check test "$before" = "$(snapshot)"
    check run --customize <<<"$choice
$icon"
    check test ! -e "$HOME/EXECUTED"
    check zsh -fn "$FILE"
    check zsh -fc '
        source "$1"
        case "$2" in
            1) [[ "$POWERLEVEL9K_OS_ICON_CONTENT_EXPANSION" == "$3" ]] ;;
            2) [[ "$POWERLEVEL9K_FOLDER_ICON" == "$3" ]] ;;
            3) [[ "$POWERLEVEL9K_VCS_BRANCH_ICON" == "$3 " ]] ;;
            4) [[ "$POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_CONTENT_EXPANSION" == "$3" && "$POWERLEVEL9K_PROMPT_CHAR_OK_VICMD_CONTENT_EXPANSION" == "$3" && "$POWERLEVEL9K_PROMPT_CHAR_ERROR_VIINS_CONTENT_EXPANSION" == error ]] ;;
        esac
    ' zsh "$FILE" "$choice" "$icon"
    check test ! -e "$HOME/EXECUTED"
    before=$(snapshot)
    check run --customize <<<"$choice
$icon"
    check test "$before" = "$(snapshot)"
done
printf '# no assignments\n' >"$FILE"
before=$(snapshot)
if run --customize <<<'2
new'; then check false; fi
check test "$before" = "$(snapshot)"
for theme in professional apple minimal rainbow; do
    case "$theme" in
        professional)
            marker='Professional'
            template=professional-dev
            ;;
        apple)
            marker='Apple Monterey'
            template=apple-style
            ;;
        minimal)
            marker='Minimal Theme'
            template=minimal
            ;;
        rainbow)
            marker='Rainbow'
            template=rainbow
            ;;
    esac
    printf '# %s\n' "$marker" >"$FILE"
    check run --reset
    check cmp -s "$FILE" "$REPO/config/$template-p10k.zsh"
    before=$(snapshot)
    check run --reset
    check test "$before" = "$(snapshot)"
done
fixture
mv "$FILE" "$HOME/target's file"
ln -s "target's file" "$FILE"
chmod 640 "$HOME/target's file"
check run --fix
check test -L "$FILE"
check test "$(readlink "$FILE")" = "target's file"
check python3 - "$FILE" <<'PY'
import os, stat, sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o640
PY
# Corrupt after successful rename, or fail after replacing the original.
export VMS_TEST_TARGET="$HOME/target's file"
mv() {
    command mv "$@" || return
    if [[ "${*: -1}" == "$VMS_TEST_TARGET" ]]; then
        printf 'corrupted bytes\n' >"$VMS_TEST_TARGET"
        return "${VMS_MV_RC:-0}"
    fi
}
export -f mv
for code in 0 73; do
    fixture
    cp "$FILE" "$SB/prestate"
    if VMS_MV_RC="$code" run --fix; then check false; fi
    check cmp -s "$FILE" "$SB/prestate"
    check test -L "$FILE"
    check test -z "$(find "$HOME" -name '.vms-icons.*' -print)"
done
unset -f mv
check grep -q rollback "$HOME/.config/version-manager/audit.log"
rm "$FILE"
for kind in missing dangling directory fifo; do
    case "$kind" in
        dangling) ln -s "$SB/absent" "$FILE" ;;
        directory) mkdir "$FILE" ;;
        fifo) mkfifo "$FILE" ;;
    esac
    before=$(snapshot)
    if run --fix; then check false; fi
    check test "$before" = "$(snapshot)"
    if [[ "$kind" == directory ]]; then rmdir "$FILE"; else rm -f "$FILE"; fi
done
if [[ -z "${VMS_TEST_BASELINE:-}" ]]; then
    fixture
    before=$(snapshot)
    if bash -c '
        source "$1"
        source "$_VMS_ICONS_ROOT/lib/lock.sh"
        lock_acquire() { return 73; }
        main --fix
    ' bash "$SCRIPT" >"$SB/output.log" 2>&1; then check false; fi
    check test "$before" = "$(snapshot)"
    printf 'typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD}_CONTENT_EXPANSION="old"\n' >"$FILE"
    check run --customize <<<'4
new'
    check zsh -fc 'source "$1"; [[ "$POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_CONTENT_EXPANSION" == new && "$POWERLEVEL9K_PROMPT_CHAR_OK_VICMD_CONTENT_EXPANSION" == new ]]' zsh "$FILE"
fi
printf 'Icon safety: %s failure(s)\n' "$failures"
[[ "$failures" == 0 ]]
