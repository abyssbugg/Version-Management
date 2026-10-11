#!/usr/bin/env bash
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../helpers.sh"
ROOT="$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)"
source "$ROOT/lib/auto-activate.sh"
failures=0
check() { if ! "$@"; then printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); fi; }
export NVM_DIR="$HOME/.nvm"
mkdir -p "$NVM_DIR/versions/node/v22.1.0/bin"
for cmd in node npm npx; do printf 'sandbox\n' > "$NVM_DIR/versions/node/v22.1.0/bin/$cmd"; done
nvm() { printf v22.1.0; }
auto_is_trusted() { return "$trust_rc"; }
ln() { printf 'RAW_WRITE\n' >> "$HOME/calls"; return 1; }
sudo() { printf 'RAW_SUDO\n' >> "$HOME/calls"; return 1; }
bash() { printf '%s\n' "$*" >> "$HOME/calls"; return "$updater_rc"; }
trust_rc=0; updater_rc=0
export DEV_AUTO_SYNC_NODE_SYMLINKS=true
: > "$HOME/calls"
TRANSACTION_DRY_RUN=1 _nvm_sync_symlinks "$HOME" || failures=$((failures + 1))
check test ! -s "$HOME/calls"
: > "$HOME/calls"
trust_rc=1
_nvm_sync_symlinks "$HOME" || failures=$((failures + 1))
check test ! -s "$HOME/calls"
trust_rc=0; updater_rc=19
if _nvm_sync_symlinks "$HOME"; then failures=$((failures + 1)); fi
check grep -q -- '--non-interactive' "$HOME/calls"
check grep -q -- "--node-bin $NVM_DIR/versions/node/v22.1.0/bin" "$HOME/calls"
check grep -q -- '--confirm' "$HOME/calls"
if grep -q RAW "$HOME/calls"; then failures=$((failures + 1)); fi
printf 'Node hook safety failures: %s\n' "$failures"
exit "$failures"
