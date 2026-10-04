#!/usr/bin/env bash
# =============================================================================
# Transaction Primitive Hardening Tests (remediation directive M2 / finding A3)
# =============================================================================
# Binding invariants (directive):
#   - Rollback restores every pre-existing target byte-for-byte (hash-verified)
#     or exits nonzero without claiming success.
#   - No two transactions — including concurrent same-named ones — ever share
#     a transaction directory or backup namespace (asserted from the
#     filesystem: distinct paths/inodes observed, not inferred from exit codes).
#   - Dry-run produces zero writes.
#   - Transaction names follow a restrictive grammar (no path escape, no
#     metadata corruption).
# =============================================================================

source ../helpers.sh

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# The primitive runs as the caller: sandbox HOME so $HOME/.config/... is safe
source "$ROOT_DIR/lib/backup.sh"

_sandbox() {
    SANDBOX_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vms-txn-test.XXXXXX")"
    mkdir -p "$SANDBOX_DIR/a" "$SANDBOX_DIR/b"
    printf 'content-A\n' > "$SANDBOX_DIR/a/config"
    printf 'content-B\n' > "$SANDBOX_DIR/b/config"
}

# Each case starts from a clean transaction namespace (cases share the
# sandbox HOME, so leftovers would corrupt newest-file targeting).
_txn_cleanup() {
    rm -rf "$DEFAULT_BACKUP_DIR"/transactions/txn_test.* 2>/dev/null
}

sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }

# A5 failure accumulation (M5 lane Y fix): assert_equals only PRINTS a
# failure — case functions used to end with `rm -rf` (status 0), so failed
# assertions never reached the file's exit status and the runner (which
# gates on that exit code) could report PASS over red output. `chk` counts
# every failed assertion and every case returns the count.
_T_CASE_FAILS=0
chk() { assert_equals "$@" || _T_CASE_FAILS=$((_T_CASE_FAILS + 1)); }

# ── 1. Name grammar: path escape / separators / metadata corruption rejected ─
test_name_grammar() {

    local bad=("../evil" "a/b" "a b" 'a"b' "a;b" ".." ".hidden" "")
    local name rc
    for name in "${bad[@]}"; do
        transaction_start "$name" >/dev/null 2>&1
        rc=$?
        if [[ $rc -ne 0 ]]; then
            chk "rejected" "rejected" "name '$name' rejected"
        else
            transaction_rollback >/dev/null 2>&1
            chk "rejected" "accepted" "name '$name' must be rejected"
        fi
    done
    return "$_T_CASE_FAILS"
}

# ── 2. Same-basename files restore byte-for-byte (the A3 headline defect) ────
test_same_basename_rollback() {
    _txn_cleanup
    _sandbox
    transaction_start "txn_test" >/dev/null 2>&1 || { chk "start" "failed" "txn start"; return 1; }
    transaction_add_file "$SANDBOX_DIR/a/config" >/dev/null 2>&1
    transaction_add_file "$SANDBOX_DIR/b/config" >/dev/null 2>&1
    printf 'MUTATED-A\n' > "$SANDBOX_DIR/a/config"
    printf 'MUTATED-B\n' > "$SANDBOX_DIR/b/config"
    transaction_rollback >/dev/null 2>&1
    local ra rb
    ra=$(sha "$SANDBOX_DIR/a/config"); rb=$(sha "$SANDBOX_DIR/b/config")
    [[ "$ra" == "$(printf 'content-A\n' | sha256sum | awk '{print $1}')" ]] \
        && chk "byte-identical" "byte-identical" "a/config restored" \
        || chk "content-A hash" "$ra" "a/config WRONG CONTENT after rollback (A3)"
    [[ "$rb" == "$(printf 'content-B\n' | sha256sum | awk '{print $1}')" ]] \
        && chk "byte-identical" "byte-identical" "b/config restored" \
        || chk "content-B hash" "$rb" "b/config WRONG CONTENT after rollback (A3)"
    rm -rf "$SANDBOX_DIR"
    return "$_T_CASE_FAILS"
}

# ── 3. Concurrent same-named transactions: distinct dirs + isolated backups ──
test_concurrent_same_name_isolation() {
    _txn_cleanup
    _sandbox
    local count_before
    count_before=$(ls -d "$DEFAULT_BACKUP_DIR/transactions/txn_test".* 2>/dev/null | wc -l | tr -d ' ')
    (
        transaction_start "txn_test" >/dev/null 2>&1
        transaction_add_file "$SANDBOX_DIR/a/config" >/dev/null 2>&1
        sleep 0.2
        transaction_rollback >/dev/null 2>&1
    ) &
    (
        transaction_start "txn_test" >/dev/null 2>&1
        transaction_add_file "$SANDBOX_DIR/b/config" >/dev/null 2>&1
        sleep 0.2
        transaction_rollback >/dev/null 2>&1
    ) &
    wait
    local count_after
    count_after=$(ls -d "$DEFAULT_BACKUP_DIR/transactions/txn_test".* 2>/dev/null | wc -l | tr -d ' ')
    chk "2" "$((count_after - count_before))" "two same-named transactions created TWO distinct directories (filesystem-observed)"
    [[ "$ra" == "" ]] || true
    local ha hb
    ha=$(sha "$SANDBOX_DIR/a/config"); hb=$(sha "$SANDBOX_DIR/b/config")
    [[ "$ha" == "$(printf 'content-A\n' | sha256sum | awk '{print $1}')" ]] \
        && chk "isolated" "isolated" "lane-A backup namespace isolated" \
        || chk "content-A" "$ha" "lane-A cross-contaminated (namespace sharing!)"
    [[ "$hb" == "$(printf 'content-B\n' | sha256sum | awk '{print $1}')" ]] \
        && chk "isolated" "isolated" "lane-B backup namespace isolated" \
        || chk "content-B" "$hb" "lane-B cross-contaminated (namespace sharing!)"
    rm -rf "$SANDBOX_DIR"
    return "$_T_CASE_FAILS"
}

# ── 4. New files removed on rollback; registered-then-deleted restored ──────
test_new_and_deleted_files() {
    _txn_cleanup
    _sandbox
    transaction_start "txn_test" >/dev/null 2>&1
    transaction_add_file "$SANDBOX_DIR/a/created_later" >/dev/null 2>&1   # new file
    transaction_add_file "$SANDBOX_DIR/b/config" >/dev/null 2>&1          # existing
    printf 'created\n' > "$SANDBOX_DIR/a/created_later"
    rm -f "$SANDBOX_DIR/b/config"                                          # deleted pre-rollback
    transaction_rollback >/dev/null 2>&1
    [[ ! -e "$SANDBOX_DIR/a/created_later" ]] \
        && chk "removed" "removed" "new file removed on rollback" \
        || chk "removed" "still-present" "new file must be removed on rollback"
    [[ -f "$SANDBOX_DIR/b/config" ]] \
        && chk "restored" "restored" "deleted-then-registered file restored" \
        || chk "restored" "missing" "registered file deleted pre-rollback must be restored"
    rm -rf "$SANDBOX_DIR"
    return "$_T_CASE_FAILS"
}

# ── 5. Permission failure: rollback exits nonzero, never claims success ─────
test_permission_failure_loud() {
    _sandbox
    transaction_start "txn_test" >/dev/null 2>&1
    transaction_add_file "$SANDBOX_DIR/b/config" >/dev/null 2>&1
    printf 'MUTATED\n' > "$SANDBOX_DIR/b/config"
    # Root-proof failure simulation: remove the parent DIRECTORY so the
    # restore target cannot be recreated by anyone (chmod 555 does not stop
    # root on the hosted CI agents).
    rm -rf "$SANDBOX_DIR/b"
    local rc
    transaction_rollback >/dev/null 2>&1
    rc=$?
    [[ $rc -ne 0 ]] \
        && chk "loud" "loud" "rollback exits nonzero on permission failure" \
        || chk "loud" "silent-success" "rollback MUST fail loudly on permission failure"
    rm -rf "$SANDBOX_DIR"
    return "$_T_CASE_FAILS"
}

# ── 6. Hash verification: corrupt backup is never restored as success ───────
test_hash_verified_rollback() {
    _sandbox
    _txn_cleanup
    transaction_start "txn_test" >/dev/null 2>&1
    transaction_add_file "$SANDBOX_DIR/b/config" >/dev/null 2>&1
    # Corrupt the CURRENT transaction's stored backup (newest dir, index 0001)
    local backup_file
    backup_file=$(ls -td "$DEFAULT_BACKUP_DIR"/transactions/txn_test.*/files/*/data 2>/dev/null | head -1)
    if [[ -n "$backup_file" ]]; then
        printf 'TAMPERED\n' > "$backup_file"
        printf 'MUTATED\n' > "$SANDBOX_DIR/b/config"
        local rc
        transaction_rollback >/dev/null 2>&1
        rc=$?
        [[ $rc -ne 0 ]] \
            && chk "loud" "loud" "rollback detects tampered backup and fails loudly" \
            || chk "loud" "silent-success" "tampered backup must NOT roll back as success"
    else
        chk "backup-found" "missing" "test setup: backup data file locatable"
    fi
    rm -rf "$SANDBOX_DIR"
    return "$_T_CASE_FAILS"
}

# ── 7. Symlink semantics: the link is restored, not the target's content ────
test_symlink_semantics() {
    _txn_cleanup
    _sandbox
    printf 'real-target\n' > "$SANDBOX_DIR/target_file"
    ln -s "$SANDBOX_DIR/target_file" "$SANDBOX_DIR/a/link"
    transaction_start "txn_test" >/dev/null 2>&1
    transaction_add_file "$SANDBOX_DIR/a/link" >/dev/null 2>&1
    rm -f "$SANDBOX_DIR/a/link"
    printf 'replaced-with-regular-file\n' > "$SANDBOX_DIR/a/link"
    transaction_rollback >/dev/null 2>&1
    [[ -L "$SANDBOX_DIR/a/link" ]] \
        && chk "symlink-restored" "symlink-restored" "symlink restored as a link" \
        || chk "symlink-restored" "$( [ -f "$SANDBOX_DIR/a/link" ] && echo regular-file || echo missing )" "symlink must be restored as a link"
    rm -rf "$SANDBOX_DIR"
    return "$_T_CASE_FAILS"
}

# ── 8. Dry-run: zero writes anywhere ─────────────────────────────────────────
test_dry_run_zero_writes() {
    _txn_cleanup
    _sandbox
    local dirs_before
    dirs_before=$(ls -d "$DEFAULT_BACKUP_DIR/transactions/"* 2>/dev/null | wc -l | tr -d ' ')
    TRANSACTION_DRY_RUN=1 transaction_start "txn_test" >/dev/null 2>&1
    TRANSACTION_DRY_RUN=1 transaction_add_file "$SANDBOX_DIR/b/config" >/dev/null 2>&1
    TRANSACTION_DRY_RUN=1 transaction_commit >/dev/null 2>&1
    local dirs_after
    dirs_after=$(ls -d "$DEFAULT_BACKUP_DIR/transactions/"* 2>/dev/null | wc -l | tr -d ' ')
    chk "$dirs_before" "$dirs_after" "dry-run creates zero transaction directories"
    chk "$(printf 'content-B\n' | sha256sum | awk '{print $1}')" "$(sha "$SANDBOX_DIR/b/config")" "dry-run never touches registered files"
    rm -rf "$SANDBOX_DIR"
    return "$_T_CASE_FAILS"
}

# ── 9. Hostile unlink during symlink rollback (B1.11-new): the partial
#    restore must be RECORDED and surfaced — never a silent mid-rollback
#    abort that loses the journal/metadata record under an adopter's set -e ──
# The strict caller runs as a CHILD bash -c (a subshell inside `|| rc=$?`
# would ignore errexit for the whole compound — bash's documented behavior —
# and a child process also defeats the parent's command hash, so the stub rm
# is genuinely resolved via PATH).
test_symlink_rollback_hostile_unlink() {
    _txn_cleanup
    _sandbox
    printf 'real-target\n' > "$SANDBOX_DIR/target_file"
    ln -s "$SANDBOX_DIR/target_file" "$SANDBOX_DIR/a/link"
    # Hostile unlink: a stub rm refuses THIS path (uid-independent — works
    # on root CI agents where chmod cannot restrict anything).
    local stubbin="$SANDBOX_DIR/stubbin"
    mkdir -p "$stubbin"
    {
        printf '#!/bin/sh\n'
        printf 'for a in "$@"; do\n'
        printf '  [ "$a" = "%s" ] && { echo "stub-rm: simulated EACCES on $a" >&2; exit 1; }\n' "$SANDBOX_DIR/a/link"
        printf 'done\n'
        printf 'exec /bin/rm "$@"\n'
    } > "$stubbin/rm"
    chmod +x "$stubbin/rm"
    local journal
    journal="$HOME/.config/version-manager/audit.log"
    mkdir -p "$(dirname "$journal")"
    : > "$journal"   # isolate this case's journal assertions from earlier cases
    # The ADOPTER's run, in one strict child process: register the symlink
    # pre-state, mutate (link -> regular file), then roll back under a
    # hostile unlink. A child bash -c is used because a subshell inside
    # `|| rc=$?` ignores errexit for the whole compound (bash documented
    # behavior), which would silently disable the adopter's set -e posture.
    local rc=0
    VMS_C9_ROOT="$ROOT_DIR" VMS_C9_TARGET="$SANDBOX_DIR/a/link" VMS_C9_STUB="$stubbin" \
        bash -c '
        set -euo pipefail
        source "$VMS_C9_ROOT/lib/backup.sh"
        transaction_start "txn_test" >/dev/null 2>&1
        transaction_add_file "$VMS_C9_TARGET" >/dev/null 2>&1
        rm -f "$VMS_C9_TARGET"                       # adopter mutation: link destroyed
        printf "replaced-regular\n" > "$VMS_C9_TARGET"
        PATH="$VMS_C9_STUB:$PATH"                    # hostile unlink from here on
        transaction_rollback
    ' || rc=$?
    local txn_dir
    txn_dir=$(ls -d "$DEFAULT_BACKUP_DIR/transactions/txn_test."* 2>/dev/null | tail -1)
    [[ -n "$txn_dir" && -f "$txn_dir/metadata.json" ]] || txn_dir=""
    [[ $rc -ne 0 ]] \
        && chk "surfaced" "surfaced" "hostile unlink surfaces a nonzero rollback (rc=$rc)" \
        || chk "surfaced" "silent-success" "rollback with a hostile unlink MUST NOT succeed silently (rc=0!)"
    local jrec="absent"
    [[ -n "$txn_dir" && -f "$journal" ]] \
        && grep -q "$(printf '\trollback\ttxn_test\t').*status=with_errors" "$journal" 2>/dev/null && jrec="present"
    [[ "$jrec" == "present" ]] \
        && chk "present" "present" "rollback record (status=with_errors) present in the audit journal despite the failed restore (B1.11-new)" \
        || chk "present" "absent" "rollback record MUST be journaled even when a restore step fails (set -e abort loses it)"
    local meta_status
    meta_status=$(grep -o '"status": "[^"]*"' "$txn_dir/metadata.json" 2>/dev/null || echo "none")
    chk '"status": "rolled_back_with_errors"' "$meta_status" "metadata records the partial restore (rolled_back_with_errors, not stuck at active)"
    local meta_errors
    meta_errors=$(grep -o '"errors": [0-9]*' "$txn_dir/metadata.json" 2>/dev/null | grep -o '[0-9]*$' || echo "0")
    [[ "${meta_errors:-0}" -ge 1 ]] \
        && chk "counted" "counted" "the failed restore step is counted in the rollback metadata" \
        || chk "counted" "uncounted" "failed restore step must be counted (errors >= 1)"
    rm -rf "$SANDBOX_DIR"
    return "$_T_CASE_FAILS"
}

# ── Run — explicit failure accumulation (A5) ─────────────────────────────────
failures=0
run_tcase() { _T_CASE_FAILS=0; "$@" || failures=$((failures + 1)); }
run_tcase test_name_grammar
run_tcase test_same_basename_rollback
run_tcase test_concurrent_same_name_isolation
run_tcase test_new_and_deleted_files
run_tcase test_permission_failure_loud
run_tcase test_hash_verified_rollback
run_tcase test_symlink_semantics
run_tcase test_dry_run_zero_writes
run_tcase test_symlink_rollback_hostile_unlink

if [[ "$failures" -gt 0 ]]; then
    echo "test_transaction_hardening.sh: $failures case(s) failed"
    exit 1
fi
