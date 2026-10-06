#!/usr/bin/env bash
# P3-1: transaction previews must not create audit, log or backup files.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tmp_rovodev_txn_preview.XXXXXX")"
trap 'rm -rf -- "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME"
export TXN_AUDIT_LOG="$HOME/audit/events.log" LOG_FILE="$HOME/log/events.log"
if [[ "${VMS_TEST_BASELINE:-0}" == 1 ]]; then
    mkdir -p "$SANDBOX/lib"
    git -C "$ROOT" show HEAD:lib/backup.sh >"$SANDBOX/lib/backup.sh"
    ln -s "$ROOT/lib/logger.sh" "$SANDBOX/lib/logger.sh"
    # shellcheck source=lib/backup.sh
    source "$SANDBOX/lib/backup.sh"
else
    # shellcheck source=lib/backup.sh
    source "$ROOT/lib/backup.sh"
fi
failures=0
for finish in transaction_commit transaction_rollback; do
    TRANSACTION_DRY_RUN=1 transaction_start preview >/dev/null
    transaction_add_file "$HOME/not-created" >/dev/null
    "$finish" >/dev/null
    if [[ -n "$(find "$HOME" -mindepth 1 -print)" ]]; then
        printf 'FAIL: preview %s wrote files under HOME\n' "$finish"
        failures=$((failures + 1))
    else
        printf 'PASS: preview %s made zero writes\n' "$finish"
    fi
    [[ -z "$_TRANSACTION_ACTIVE" ]] || failures=$((failures + 1))
done
# A pre-existing journal/log must also retain its bytes in preview mode.
mkdir -p "$(dirname "$TXN_AUDIT_LOG")" "$(dirname "$LOG_FILE")"
printf 'audit prestate\n' >"$TXN_AUDIT_LOG"
printf 'log prestate\n' >"$LOG_FILE"
TRANSACTION_DRY_RUN=1 transaction_start preview >/dev/null
transaction_add_file "$HOME/not-created" >/dev/null
transaction_commit >/dev/null
if [[ "$(cat "$TXN_AUDIT_LOG")" != 'audit prestate' || "$(cat "$LOG_FILE")" != 'log prestate' ]]; then
    printf 'FAIL: preview appended to existing journal/log\n'
    failures=$((failures + 1))
else
    printf 'PASS: existing journal/log unchanged\n'
fi
printf 'Transaction preview regressions: %s failure(s)\n' "$failures"
[[ "$failures" -eq 0 ]]
