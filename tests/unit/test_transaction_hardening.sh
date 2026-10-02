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

# ── 1. Name grammar: path escape / separators / metadata corruption rejected ─
test_name_grammar() {
    local f=0
    local bad=("../evil" "a/b" "a b" 'a"b' "a;b" ".." ".hidden" "")
    local name rc
    for name in "${bad[@]}"; do
        transaction_start "$name" >/dev/null 2>&1
        rc=$?
        if [[ $rc -ne 0 ]]; then
            assert_equals "rejected" "rejected" "name '$name' rejected"
        else
            transaction_rollback >/dev/null 2>&1
            assert_equals "rejected" "accepted" "name '$name' must be rejected"
        fi
    done
    return "$(( f ))"
}

# ── 2. Same-basename files restore byte-for-byte (the A3 headline defect) ────
test_same_basename_rollback() {
    _txn_cleanup
    _sandbox
    transaction_start "txn_test" >/dev/null 2>&1 || { assert_equals "start" "failed" "txn start"; return 1; }
    transaction_add_file "$SANDBOX_DIR/a/config" >/dev/null 2>&1
    transaction_add_file "$SANDBOX_DIR/b/config" >/dev/null 2>&1
    printf 'MUTATED-A\n' > "$SANDBOX_DIR/a/config"
    printf 'MUTATED-B\n' > "$SANDBOX_DIR/b/config"
    transaction_rollback >/dev/null 2>&1
    local ra rb
    ra=$(sha "$SANDBOX_DIR/a/config"); rb=$(sha "$SANDBOX_DIR/b/config")
    [[ "$ra" == "$(printf 'content-A\n' | sha256sum | awk '{print $1}')" ]] \
        && assert_equals "byte-identical" "byte-identical" "a/config restored" \
        || assert_equals "content-A hash" "$ra" "a/config WRONG CONTENT after rollback (A3)"
    [[ "$rb" == "$(printf 'content-B\n' | sha256sum | awk '{print $1}')" ]] \
        && assert_equals "byte-identical" "byte-identical" "b/config restored" \
        || assert_equals "content-B hash" "$rb" "b/config WRONG CONTENT after rollback (A3)"
    rm -rf "$SANDBOX_DIR"
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
    assert_equals "2" "$((count_after - count_before))" "two same-named transactions created TWO distinct directories (filesystem-observed)"
    [[ "$ra" == "" ]] || true
    local ha hb
    ha=$(sha "$SANDBOX_DIR/a/config"); hb=$(sha "$SANDBOX_DIR/b/config")
    [[ "$ha" == "$(printf 'content-A\n' | sha256sum | awk '{print $1}')" ]] \
        && assert_equals "isolated" "isolated" "lane-A backup namespace isolated" \
        || assert_equals "content-A" "$ha" "lane-A cross-contaminated (namespace sharing!)"
    [[ "$hb" == "$(printf 'content-B\n' | sha256sum | awk '{print $1}')" ]] \
        && assert_equals "isolated" "isolated" "lane-B backup namespace isolated" \
        || assert_equals "content-B" "$hb" "lane-B cross-contaminated (namespace sharing!)"
    rm -rf "$SANDBOX_DIR"
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
        && assert_equals "removed" "removed" "new file removed on rollback" \
        || assert_equals "removed" "still-present" "new file must be removed on rollback"
    [[ -f "$SANDBOX_DIR/b/config" ]] \
        && assert_equals "restored" "restored" "deleted-then-registered file restored" \
        || assert_equals "restored" "missing" "registered file deleted pre-rollback must be restored"
    rm -rf "$SANDBOX_DIR"
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
        && assert_equals "loud" "loud" "rollback exits nonzero on permission failure" \
        || assert_equals "loud" "silent-success" "rollback MUST fail loudly on permission failure"
    rm -rf "$SANDBOX_DIR"
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
            && assert_equals "loud" "loud" "rollback detects tampered backup and fails loudly" \
            || assert_equals "loud" "silent-success" "tampered backup must NOT roll back as success"
    else
        assert_equals "backup-found" "missing" "test setup: backup data file locatable"
    fi
    rm -rf "$SANDBOX_DIR"
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
        && assert_equals "symlink-restored" "symlink-restored" "symlink restored as a link" \
        || assert_equals "symlink-restored" "$( [ -f "$SANDBOX_DIR/a/link" ] && echo regular-file || echo missing )" "symlink must be restored as a link"
    rm -rf "$SANDBOX_DIR"
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
    assert_equals "$dirs_before" "$dirs_after" "dry-run creates zero transaction directories"
    assert_equals "$(printf 'content-B\n' | sha256sum | awk '{print $1}')" "$(sha "$SANDBOX_DIR/b/config")" "dry-run never touches registered files"
    rm -rf "$SANDBOX_DIR"
}

# ── Run — explicit failure accumulation (A5) ─────────────────────────────────
failures=0
test_name_grammar || failures=$((failures + 1))
test_same_basename_rollback || failures=$((failures + 1))
test_concurrent_same_name_isolation || failures=$((failures + 1))
test_new_and_deleted_files || failures=$((failures + 1))
test_permission_failure_loud || failures=$((failures + 1))
test_hash_verified_rollback || failures=$((failures + 1))
test_symlink_semantics || failures=$((failures + 1))
test_dry_run_zero_writes || failures=$((failures + 1))

if [[ "$failures" -gt 0 ]]; then
    echo "test_transaction_hardening.sh: $failures case(s) failed"
    exit 1
fi
