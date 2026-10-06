#!/usr/bin/env bash
# P3-1: transaction-safe theme icon mutations with regression tests
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tmp_rovodev_theme_icons.XXXXXX")"
trap 'rm -rf -- "$SANDBOX"' EXIT
export HOME="$SANDBOX/home" XDG_CONFIG_HOME="$SANDBOX/home/.config"
export XDG_CACHE_HOME="$SANDBOX/home/.cache" XDG_DATA_HOME="$SANDBOX/home/.local/share"
export XDG_STATE_HOME="$SANDBOX/home/.local/state"
unset LOG_FILE BACKUP_DIR TRANSACTION_DRY_RUN NVM_DIR
mkdir -p "$HOME"
REPO="$SANDBOX/repo's copy"
mkdir -p "$REPO/scripts" "$REPO/config"
if [[ "${VMS_TEST_BASELINE:-0}" == 1 ]]; then
	git -C "$ROOT" show 96da206:scripts/theme-icon-manager.sh >"$REPO/scripts/theme-icon-manager.sh"
else
	cp "$ROOT/scripts/theme-icon-manager.sh" "$REPO/scripts/"
fi
ln -s "$ROOT/lib" "$REPO/lib"
SCRIPT="$REPO/scripts/theme-icon-manager.sh"
P10K_CONFIG="$HOME/.p10k.zsh"
THEME_DIR="$REPO/config"
mkdir -p "$THEME_DIR"
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
cat >"$THEME_DIR/professional-dev-p10k.zsh" <<'CONFIG'
# P10k professional theme
typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(os dir vcs)
typeset -g POWERLEVEL9K_OS_ICON_CONTENT_EXPANSION='🍎'
typeset -g POWERLEVEL9K_FOLDER_ICON='📁'
typeset -g POWERLEVEL9K_VCS_BRANCH_ICON='🌿'
typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_CONTENT_EXPANSION='❯'
typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_VIINS_CONTENT_EXPANSION='❯'
CONFIG
cat >"$THEME_DIR/apple-style-p10k.zsh" <<'CONFIG'
typeset -g POWERLEVEL9K_OS_ICON_CONTENT_EXPANSION='🍎'
typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_CONTENT_EXPANSION='▶'
CONFIG
cat >"$THEME_DIR/minimal-p10k.zsh" <<'CONFIG'
typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_CONTENT_EXPANSION='$'
CONFIG
cat >"$THEME_DIR/rainbow-p10k.zsh" <<'CONFIG'
typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_CONTENT_EXPANSION='⚡'
CONFIG
cp "$THEME_DIR/professional-dev-p10k.zsh" "$P10K_CONFIG"
before="$(snapshot)"
check run --dry-run
check test "$before" = "$(snapshot)"
check run --help
check test "$before" = "$(snapshot)"
if run --unknown; then check false; else check test "$before" = "$(snapshot)"; fi
cp "$THEME_DIR/professional-dev-p10k.zsh" "$P10K_CONFIG"
before="$(snapshot)"
check run --fix
check test "$before" != "$(snapshot)" || true
before="$(snapshot)"
check run --fix
check test "$before" = "$(snapshot)"
cp "$THEME_DIR/professional-dev-p10k.zsh" "$P10K_CONFIG"
chmod 640 "$P10K_CONFIG"
mode_before="$(python3 -c "import os, stat; print(stat.S_IMODE(os.stat('$P10K_CONFIG').st_mode))")"
check run --fix
mode_after="$(python3 -c "import os, stat; print(stat.S_IMODE(os.stat('$P10K_CONFIG').st_mode))")"
check test "$mode_before" = "$mode_after"
echo "# User edit" >>"$P10K_CONFIG"
cp "$P10K_CONFIG" "$SANDBOX/prestate"
before="$(snapshot)"
check run --reset
check test "$before" != "$(snapshot)"
before="$(snapshot)"
check run --reset
check test "$before" = "$(snapshot)"
mv "$P10K_CONFIG" "$HOME/p10k-target.zsh"
ln -s "p10k-target.zsh" "$P10K_CONFIG"
check test -L "$P10K_CONFIG"
before="$(snapshot)"
check run --preview
check test "$(readlink "$P10K_CONFIG")" = "p10k-target.zsh"
check test "$before" = "$(snapshot)"
rm -f "$P10K_CONFIG"
before="$(snapshot)"
if run --fix; then check false; else check test "$before" = "$(snapshot)"; fi
ln -s "$SANDBOX/missing-target.zsh" "$P10K_CONFIG"
before="$(snapshot)"
if run --fix; then check false; else check test "$before" = "$(snapshot)"; fi
mkdir -p "$SANDBOX/bin"
REAL_MV="$(command -v mv)"
export REAL_MV VMS_TEST_TARGET="$P10K_CONFIG"
cat >"$SANDBOX/bin/mv" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
"$REAL_MV" "$@"
if [[ "${*: -1}" == "$VMS_TEST_TARGET" ]]; then
    printf 'invalid zsh config\n' > "$VMS_TEST_TARGET"
fi
SH
chmod +x "$SANDBOX/bin/mv"
cp "$THEME_DIR/professional-dev-p10k.zsh" "$P10K_CONFIG"
cp "$P10K_CONFIG" "$SANDBOX/prestate"
if PATH="$SANDBOX/bin:$PATH" run --fix; then check false; fi
check cmp -s "$P10K_CONFIG" "$SANDBOX/prestate"
cat >"$SANDBOX/bin/mv" <<'SH'
#!/usr/bin/env bash
exit 73
SH
cp "$THEME_DIR/professional-dev-p10k.zsh" "$P10K_CONFIG"
cp "$P10K_CONFIG" "$SANDBOX/prestate"
if PATH="$SANDBOX/bin:$PATH" run --fix; then check false; fi
check cmp -s "$P10K_CONFIG" "$SANDBOX/prestate"
printf 'Theme icon mutations: %s failure(s)\n' "$failures"
[[ "$failures" -eq 0 ]]
