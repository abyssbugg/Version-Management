#!/usr/bin/env bash
# P3-1: a registration preserves the FIRST pre-state, including file mode/links.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB=$(mktemp -d "${TMPDIR:-/tmp}/tmp_rovodev_registration.XXXXXX")
trap 'rm -rf -- "$SB"' EXIT
export HOME="$SB/home"
mkdir -p "$HOME"
unset LOG_FILE TRANSACTION_DRY_RUN
source "$ROOT/lib/backup.sh"
failures=0
check() { if "$@"; then echo "PASS: $1"; else
    echo "FAIL: $*"
    failures=$((failures + 1))
fi; }
file="$HOME/value"
printf 'original\n' >"$file"
chmod 640 "$file"
transaction_start registration
transaction_add_file "$file"
printf 'intermediate\n' >"$file"
transaction_add_file "$file"
printf 'final\n' >"$file"
chmod 600 "$file"
transaction_rollback
check test "$(cat "$file")" = original
check python3 - "$file" <<'PY'
import os, stat, sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o640
PY
ln -s missing "$HOME/link"
transaction_start dangling
transaction_add_file "$HOME/link"
rm "$HOME/link"
printf 'replacement\n' >"$HOME/link"
transaction_rollback
check test -L "$HOME/link"
check test "$(readlink "$HOME/link")" = missing
# The older local-font entry point shares the workstation mutation lock.
# Its own fixture contains fonts so bypassing the lock is observably unsafe.
mkdir -p "$SB/repo"
cp "$ROOT/setup-fonts-enhanced.sh" "$SB/repo/"
ln -s "$ROOT/lib" "$SB/repo/lib"
printf 'font bytes\n' >"$SB/repo/MesloLGS NF Regular.ttf"
if bash -c '
    source "$1"
    source "$_VMS_FONTS_SCRIPT_DIR/lib/lock.sh"
    lock_acquire() { return 73; }
    install_local_fonts
' bash "$SB/repo/setup-fonts-enhanced.sh" >"$SB/fonts.log" 2>&1; then check false; fi
check test ! -d "$HOME/Library/Fonts"
check test ! -d "$HOME/.local/share/fonts"
printf 'Transaction registration: %s failure(s)\n' "$failures"
[[ "$failures" == 0 ]]
