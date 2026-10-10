#!/usr/bin/env bash
# =============================================================================
# P3-2: per-operation metadata in the audit journal
# =============================================================================
# Every record the shared primitives write to the audit journal carries the
# operation's metadata, so any mutation can be traced after the fact:
#
#   <ts> TAB <event> TAB <transaction> TAB <backup-dir> TAB <detail>
#   detail always contains: script=<entry point> pid=<pid> mode=apply
#                           result=<outcome> exit_code=<n>
#                           and target=<path> (per-file events) or
#                           files=<n> (transaction-level events)
#
# Dry-run stays console-only (test_transaction_preview.sh), so every journal
# record is an applied operation. Every primitive event type is exercised:
# start, register (existing + new), commit, rollback (ok + with errors),
# mutation_write, mutation_remove, mutation_publish, install_dir_stage,
# install_dir_remove_partial, install_dir_restore. A static check pins that
# every _txn_journal call site in shipped code states result= and exit_code=.
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/vms-journal-schema.XXXXXX")"
trap 'rm -rf -- "$SANDBOX"' EXIT
export HOME="$SANDBOX/home" TMPDIR="$SANDBOX/tmp"
export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME" "$TMPDIR"
unset LOG_FILE TRANSACTION_DRY_RUN BACKUP_DIR
export TXN_AUDIT_LOG="$SANDBOX/audit.log"

# shellcheck source=lib/mutation.sh
source "$ROOT/lib/mutation.sh" >/dev/null 2>&1

failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }

# ── exercise every primitive event ──────────────────────────────────────────
rc_file="$HOME/.zshrc"
printf '# user canary\n' > "$rc_file"
body="$SANDBOX/body"
printf 'export DEMO=1\n' > "$body"

transaction_start "journal_commit" >/dev/null 2>&1
transaction_add_file "$HOME/new-file" >/dev/null 2>&1
mutation_block_write "$rc_file" "demo" "$body" >/dev/null 2>&1
printf 'published\n' > "$SANDBOX/published"
mutation_file_publish "$HOME/published.txt" "$SANDBOX/published" >/dev/null 2>&1
transaction_commit >/dev/null 2>&1

transaction_start "journal_remove" >/dev/null 2>&1
mutation_block_remove "$rc_file" "demo" >/dev/null 2>&1
transaction_commit >/dev/null 2>&1

transaction_start "journal_rollback" >/dev/null 2>&1
transaction_add_file "$rc_file" >/dev/null 2>&1
printf 'clobbered\n' > "$rc_file"
transaction_rollback >/dev/null 2>&1

# Rollback with errors: tamper the backup payload so the restore is refused.
transaction_start "journal_rollback_err" >/dev/null 2>&1
transaction_add_file "$rc_file" >/dev/null 2>&1
printf 'tampered\n' > "$_TRANSACTION_DIR/files/0000/data"
transaction_rollback >/dev/null 2>&1

mkdir -p "$HOME/.tool"
install_dir_stage "$HOME/.tool" "$HOME/.tool.bak" >/dev/null 2>&1
mkdir -p "$HOME/.tool"
install_dir_restore "$HOME/.tool" "$HOME/.tool.bak" >/dev/null 2>&1

# ── schema assertions ───────────────────────────────────────────────────────
if [[ ! -s "$TXN_AUDIT_LOG" ]]; then
    fail "journal written"
else
    pass "journal written ($(wc -l < "$TXN_AUDIT_LOG" | tr -d ' ') records)"
fi

expected_events=(start register commit rollback mutation_write mutation_remove
    mutation_publish install_dir_stage install_dir_remove_partial install_dir_restore)
for ev in "${expected_events[@]}"; do
    if awk -F'\t' -v e="$ev" '$2 == e { found = 1 } END { exit !found }' "$TXN_AUDIT_LOG" 2>/dev/null; then
        pass "event recorded: $ev"
    else
        fail "event recorded: $ev"
    fi
done

bad=0
while IFS= read -r rec; do
    # Split on single tabs (read with IFS=$'\t' would merge the empty
    # transaction columns of install_dir_* records — tab is IFS whitespace).
    ncols=$(awk -F'\t' '{ print NF }' <<< "$rec")
    rest="$rec"
    ts="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    ev="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    txn="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    bdir="${rest%%$'\t'*}"; detail="${rest#*$'\t'}"
    problems=()
    [[ -n "$ts" && -n "$ev" ]] || problems+=("timestamp/event")
    [[ "$ncols" -eq 5 ]] || problems+=("$ncols columns, expected 5")
    for key in script pid mode result exit_code; do
        [[ " $detail " =~ \ $key=[^\ ]+ ]] || problems+=("$key=")
    done
    [[ " $detail " == *" mode=apply "* ]] || problems+=("mode=apply")
    [[ " $detail " =~ \ exit_code=[0-9]+\  ]] || problems+=("numeric exit_code")
    [[ " $detail " =~ \ (target|files)=[^\ ]+ ]] || problems+=("target=/files=")
    # The backup id: the transaction directory, or backup= for operations
    # outside a transaction (install_dir_*: the staged copy is the backup).
    case "$ev" in
        install_dir_remove_partial) : ;;
        install_dir_*) [[ " $detail " =~ \ backup=[^\ ]+ ]] || problems+=("backup=") ;;
        *) [[ -n "$txn" && -n "$bdir" ]] || problems+=("transaction/backup columns") ;;
    esac
    if [[ ${#problems[@]} -gt 0 ]]; then
        bad=$((bad + 1))
        printf '  record missing [%s]: %s\n' "${problems[*]}" "$rec"
    fi
done < "$TXN_AUDIT_LOG"
if [[ "$bad" -eq 0 ]]; then
    pass "every record carries script/pid/mode/backup/result/exit_code/target"
else
    fail "$bad record(s) lack per-operation metadata"
fi

# Outcomes are the real ones, not a constant.
grep -q $'\tcommit\tjournal_commit\t.*result=committed exit_code=0' "$TXN_AUDIT_LOG" \
    && pass "commit result=committed" || fail "commit result=committed"
grep -q $'\trollback\tjournal_rollback\t.*result=rolled_back exit_code=0' "$TXN_AUDIT_LOG" \
    && pass "rollback result=rolled_back" || fail "rollback result=rolled_back"
grep -q $'\trollback\tjournal_rollback_err\t.*result=rolled_back_with_errors exit_code=[1-9]' "$TXN_AUDIT_LOG" \
    && pass "failed rollback result=rolled_back_with_errors, non-zero exit_code" \
    || fail "failed rollback result=rolled_back_with_errors, non-zero exit_code"
grep -q $'\tregister\tjournal_commit\t.*target='"$HOME"'/new-file .*result=tracked_new' "$TXN_AUDIT_LOG" \
    && pass "new-file registration journaled with its target" \
    || fail "new-file registration journaled with its target"
grep -q $'\tregister\tjournal_rollback\t.*target='"$rc_file"' .*result=backed_up' "$TXN_AUDIT_LOG" \
    && pass "existing-file registration journaled with its target" \
    || fail "existing-file registration journaled with its target"
grep -q 'script=test_audit_journal_schema.sh ' "$TXN_AUDIT_LOG" \
    && pass "script= names the entry point" || fail "script= names the entry point"

# ── static: every shipped call site states its outcome ──────────────────────
missing=$(cd "$ROOT" && git ls-files '*.sh' | grep -vE '^(tests|FontPatcher)/' |
    xargs grep -nE '(^|[^A-Za-z0-9_])_(txn|install_dir)_journal[[:space:]]+[^()]' 2>/dev/null |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|export -f )' |
    grep -vE 'declare -F _txn_journal|_txn_journal "\$1" "\$2"' |
    grep -vE '(target|files)=[^ ]+.*result=[^ ]+.*exit_code=|result=[^ ]+.*exit_code=.*(target|files)=' || true)
if [[ -z "$missing" ]]; then
    pass "every journal call site states target=/files=, result= and exit_code="
else
    fail "journal call sites without target=/files=, result= or exit_code=:"
    printf '%s\n' "$missing" | sed 's/^/    /'
fi

printf 'Audit journal schema (P3-2): %s failure(s)\n' "$failures"
[[ "$failures" -eq 0 ]]
