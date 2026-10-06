#!/usr/bin/env bash
# B2.1/P0-3-runtime-home: behavior tests must contain every write in a sandbox.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB=$(mktemp -d "${TMPDIR:-/tmp}/tmp_rovodev_mutation.XXXXXX")
export HOME="$SB/source-home" TMPDIR="$SB/tmp"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME" "$TMPDIR"
unset LOG_FILE TXN_AUDIT_LOG TRANSACTION_DRY_RUN
source "$ROOT/lib/mutation.sh"
_cleanup() {
    local rc=$?
    trap - EXIT
    if transaction_is_active; then transaction_rollback || rc=1; fi
    rm -rf -- "$SB"
    exit "$rc"
}
trap _cleanup EXIT
failures=0
check() { if "$@"; then printf 'PASS: %s\n' "$1"; else
    printf 'FAIL: %s\n' "$*"
    failures=$((failures + 1))
fi; }
start_case() {
    if transaction_is_active; then transaction_rollback; fi
    export HOME="$SB/$1"
    export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
    export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
    mkdir -p "$HOME"
    file="$HOME/.zshrc"
    content="$HOME/content"
    printf '# user preamble\nexport EDITOR=vim\n' >"$file"
    transaction_start mut_test
    check test "$(dirname "$_TRANSACTION_DIR")" = "$HOME/.config-backups/transactions"
}
start_case idempotent
mutation_nvm_block >"$content"
check mutation_block_write "$file" nvm "$content"
transaction_commit
before=$(_txn_sha256 "$file")
transaction_start mut_test
check mutation_block_write "$file" nvm "$content"
transaction_commit
check test "$before" = "$(_txn_sha256 "$file")"
check grep -q NVM_SILENT=true "$file"
check grep -q 'export EDITOR=vim' "$file"

start_case replacement
printf 'OLD-NVM-CONTENT\n' >"$content"
check mutation_block_write "$file" nvm "$content"
transaction_commit
printf 'NEW-NVM-CONTENT\n' >"$content"
transaction_start mut_test
check mutation_block_write "$file" nvm "$content"
transaction_commit
check test "$(mutation_block_get "$file" nvm)" = NEW-NVM-CONTENT

start_case coexistence
printf 'A\n' >"$content"
check mutation_block_write "$file" alpha "$content"
transaction_commit
printf 'B\n' >"$content"
transaction_start mut_test
check mutation_block_write "$file" beta "$content"
transaction_commit
check mutation_block_has "$file" alpha
check mutation_block_has "$file" beta

start_case mode
chmod 600 "$file"
printf 'X\n' >"$content"
check mutation_block_write "$file" gamma "$content"
mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file")
check test "$mode" = 600

start_case required_transaction
transaction_rollback
printf 'Y\n' >"$content"
if mutation_block_write "$file" delta "$content"; then check false; fi

start_case dry_run
printf 'Y\n' >"$content"
before=$(_txn_sha256 "$file")
TRANSACTION_DRY_RUN=1 mutation_block_write "$file" epsilon "$content"
check test "$before" = "$(_txn_sha256 "$file")"

start_case remove
printf 'R\n' >"$content"
check mutation_block_write "$file" zeta "$content"
transaction_commit
transaction_start mut_test
check mutation_block_remove "$file" zeta
check mutation_block_remove "$file" zeta
transaction_commit
if mutation_block_has "$file" zeta; then check false; fi
check grep -q 'export EDITOR=vim' "$file"

start_case grammar
printf 'Z\n' >"$content"
for name in '../evil' 'a/b' 'a b' ''; do
    if mutation_block_write "$file" "$name" "$content"; then check false; fi
done
transaction_rollback
check test ! -d "$SB/source-home/.config-backups"
printf 'Mutation editor: %s failure(s)\n' "$failures"
[[ "$failures" == 0 ]]
