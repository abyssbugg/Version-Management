#!/usr/bin/env bash
# =============================================================================
# P3-1 integration tests: restore_from_point all-or-nothing mode
# =============================================================================
# Lane-R NO-GO follow-up: restore_from_point restored file-by-file with
# per-file transactions-equivalents, so a mid-restore failure left a partial
# apply. lib/backup.sh now supports RESTORE_ALL_OR_NOTHING=1: ONE
# transaction registers every point file's pre-state BEFORE the first
# restore; any single failure rolls back EVERYTHING byte-identical
# (hash-verified) and the function exits nonzero. Default mode is preserved
# unchanged (partial apply, per-file .pre-restore sidecars).
#
# Root-proof failure injection (never sudo):
#   PRIMARY   — immutable flag: `chflags uchg` (macOS/BSD, owner-settable)
#               or `chattr +i` (Linux, owner-settable when the fs allows).
#               The write into the immutable target fails after registration.
#   FALLBACK  — delete the target and chmod 555 its directory (owner
#               restriction): the create fails after registration. Also used
#               to exercise the NEW-file rollback arm (file registered as
#               "new", so rollback removes nothing rather than restoring).
# Cases where no mechanism can restrict the invoking user (running as root,
# no chflags/chattr) are MARKED SKIPPED — never a false pass.
#
# Accumulation pattern (set +e, per-case counters); exit code = failures.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/../helpers.sh"

# lib/backup.sh computes DEFAULT_BACKUP_DIR from $HOME at source time — the
# test runner already exported a sandboxed HOME for this process.
# shellcheck source=lib/backup.sh
source "$SCRIPT_DIR/../../lib/backup.sh"

set +e

IS_ROOT=0
[[ "$(id -u)" -eq 0 ]] && IS_ROOT=1

sha() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

# Newest transaction metadata for a transaction name prefix (glob + mtime —
# SC2010-clean; dual-stat matches the lib/backup.sh platform pattern).
_newest_txn_metadata() {
    local txn_prefix="$1"
    local candidate newest="" newest_mtime=0 mtime
    for candidate in "$DEFAULT_BACKUP_DIR/transactions/${txn_prefix}."*; do
        [[ -d "$candidate" && -f "$candidate/metadata.json" ]] || continue
        mtime=$(stat -f%m "$candidate" 2>/dev/null || stat -c%Y "$candidate" 2>/dev/null || echo 0)
        if (( mtime >= newest_mtime )); then
            newest_mtime=$mtime
            newest="$candidate/metadata.json"
        fi
    done
    [[ -n "$newest" ]] && printf '%s\n' "$newest"
}

CASE_FAILS=0
CASE_SKIP=0
SKIPPED_CASES=0
TOTAL_FAILS=0

_chk() {
    # helpers.sh signature is (expected, actual, message); this shim keeps
    # the label-first call style used in the case functions below.
    local label="$1"
    shift
    assert_equals "$1" "$2" "$label" || CASE_FAILS=$((CASE_FAILS + 1))
}

_mark_skip() {
    CASE_SKIP=1
    SKIPPED_CASES=$((SKIPPED_CASES + 1))
    echo "    [skip] $1"
}

# run_case <label> <fn> — resets the per-case counters, isolates CWD (cd in
# the CURRENT shell so counter mutations are visible), accumulates into
# TOTAL_FAILS (exit code reflects every failed case).
CASE_DIR=""
run_case() {
    local label="$1" fn="$2"
    local old_dir="$PWD"
    CASE_FAILS=0
    CASE_SKIP=0
    echo "--- $label ---"
    CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vms-rp-case.XXXXXX")"
    cd "$CASE_DIR" || return 1
    "$fn"
    cd "$old_dir" || return 1
    if (( CASE_SKIP )); then
        skip "$label (environment cannot restrict the invoking user)"
    elif (( CASE_FAILS )); then
        fail "$label ($CASE_FAILS assertion(s) failed)"
        TOTAL_FAILS=$((TOTAL_FAILS + CASE_FAILS))
    else
        pass "$label"
    fi
    rm -rf "$CASE_DIR"
    CASE_DIR=""
}

# -----------------------------------------------------------------------------
# (a) all-succeed path: every file restored to the point content, transaction
#     committed.
# -----------------------------------------------------------------------------
test_atomic_all_succeed() {
    local proj="$CASE_DIR/proj"
    mkdir -p "$proj"
    printf 'alpha-v1\n' > "$proj/a.txt"
    printf 'beta-v1\n'  > "$proj/b.txt"

    create_restore_point "c2-ok" "$proj/a.txt" "$proj/b.txt" >/dev/null 2>&1 \
        || { _chk "create_restore_point rc" 0 1; return; }

    printf 'alpha-v2\n' > "$proj/a.txt"
    printf 'beta-v2\n'  > "$proj/b.txt"

    local rc=0
    RESTORE_ALL_OR_NOTHING=1 restore_from_point "c2-ok" >/dev/null 2>&1 || rc=$?
    _chk "all-or-nothing all-succeed exit code" 0 "$rc"

    _chk "a.txt restored to point content" "alpha-v1" "$(cat "$proj/a.txt")"
    _chk "b.txt restored to point content" "beta-v1" "$(cat "$proj/b.txt")"

    local meta
    meta=$(_newest_txn_metadata "restore-c2-ok")
    _chk "transaction metadata exists" 0 "$([[ -n "$meta" ]] && echo 0 || echo 1)"
    if [[ -n "$meta" ]]; then
        _chk "transaction status is committed" \
            "committed" "$(grep -o '"status": *"[^"]*"' "$meta" | cut -d'"' -f4 | head -1)"
    fi
}

# -----------------------------------------------------------------------------
# (b) one-fails path: total rollback, pre-restore state byte-identical.
#     Primary injection: immutable flag. Fallback: 555 dir + deleted target
#     (exercises the NEW-file rollback arm).
# -----------------------------------------------------------------------------
test_atomic_one_fails_rollback() {
    local proj="$CASE_DIR/proj"
    mkdir -p "$proj"
    printf 'alpha-v1\n' > "$proj/a.txt"
    printf 'beta-v1\n'  > "$proj/b.txt"
    printf 'gamma-v1\n' > "$proj/c.txt"

    create_restore_point "c2-fail" "$proj/a.txt" "$proj/b.txt" "$proj/c.txt" >/dev/null 2>&1 \
        || { _chk "create_restore_point rc" 0 1; return; }

    # Post-point mutation: a and b drift; c keeps v1 (or is deleted, fallback).
    printf 'alpha-v2\n' > "$proj/a.txt"
    printf 'beta-v2\n'  > "$proj/b.txt"

    # Pre-RESTORE state (what rollback must return to, byte-identically).
    local h_a h_b h_c
    h_a=$(sha "$proj/a.txt")
    h_b=$(sha "$proj/b.txt")
    h_c=$(sha "$proj/c.txt" 2>/dev/null)

    # Failure injection: prefer the immutable flag (task prescription),
    # fall back to the 555-dir mechanism. A mechanism is valid iff a
    # metadata-touch on the target FAILS afterwards (content never moves).
    local mechanism=""
    if (( ! IS_ROOT )); then
        if command -v chflags >/dev/null 2>&1; then
            chflags uchg "$proj/c.txt" 2>/dev/null
            if ! touch "$proj/c.txt" 2>/dev/null; then
                mechanism="immutable"
            else
                chflags nouchg "$proj/c.txt" 2>/dev/null
            fi
        fi
        if [[ -z "$mechanism" ]] && command -v chattr >/dev/null 2>&1; then
            chattr +i "$proj/c.txt" 2>/dev/null
            if ! touch "$proj/c.txt" 2>/dev/null; then
                mechanism="immutable"
            else
                chattr -i "$proj/c.txt" 2>/dev/null
            fi
        fi
        if [[ -z "$mechanism" ]]; then
            # Fallback: delete c, make the dir non-writable. Registration
            # records c as NEW; the restore create fails (dir write denied).
            rm -f "$proj/c.txt"
            chmod 555 "$proj"
            if ! touch "$proj/c.txt" 2>/dev/null; then
                mechanism="ro-dir"
            else
                chmod 755 "$proj"
            fi
        fi
    fi
    if [[ -z "$mechanism" ]]; then
        _mark_skip "no root-proof write-restriction mechanism available"
        return
    fi

    local rc=0
    RESTORE_ALL_OR_NOTHING=1 restore_from_point "c2-fail" >/dev/null 2>&1 || rc=$?
    _chk "one-fails restore exits nonzero" "nonzero" "$([[ $rc -ne 0 ]] && echo nonzero || echo "zero:$rc")"

    # TOTAL rollback: a and b are byte-identical to their PRE-RESTORE state
    # (drifted content, NOT the point content) — nothing partial remains.
    _chk "a.txt rolled back byte-identical (pre-restore sha)" "$h_a" "$(sha "$proj/a.txt")"
    _chk "b.txt rolled back byte-identical (pre-restore sha)" "$h_b" "$(sha "$proj/b.txt")"

    if [[ "$mechanism" == "immutable" ]]; then
        _chk "immutable c.txt never written (still point content)" "$h_c" "$(sha "$proj/c.txt")"
    else
        _chk "c.txt still absent (NEW-file arm, nothing created)" 0 "$([[ ! -e "$proj/c.txt" ]] && echo 0 || echo 1)"
    fi

    # Rollback is recorded in the transaction metadata. The immutable
    # variant reports with_errors (rollback's own cp into the immutable
    # target fails loudly — the file was never mutated, so the pre-state
    # guarantee still holds); the ro-dir variant rolls back clean.
    local meta status
    meta=$(_newest_txn_metadata "restore-c2-fail")
    _chk "transaction metadata exists" 0 "$([[ -n "$meta" ]] && echo 0 || echo 1)"
    if [[ -n "$meta" ]]; then
        status=$(grep -o '"status": *"[^"]*"' "$meta" | cut -d'"' -f4 | head -1)
        if [[ "$mechanism" == "immutable" ]]; then
            _chk "rollback recorded (rolled_back_with_errors)" "rolled_back_with_errors" "$status"
        else
            _chk "rollback recorded (rolled_back)" "rolled_back" "$status"
        fi
    fi

    # Cleanup: un-restrict regardless of assertion outcomes.
    if [[ "$mechanism" == "immutable" ]]; then
        chflags nouchg "$proj/c.txt" 2>/dev/null || chattr -i "$proj/c.txt" 2>/dev/null || true
    else
        chmod 755 "$proj" 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# (c) default mode unchanged: partial apply on failure + per-file
#     .pre-restore sidecars; all-succeed path intact.
# -----------------------------------------------------------------------------
test_default_mode_unchanged() {
    if (( IS_ROOT )); then
        _mark_skip "running as root: chmod cannot restrict writes"
        return
    fi

    local proj="$CASE_DIR/proj"
    mkdir -p "$proj"
    printf 'alpha-v1\n' > "$proj/a.txt"
    printf 'beta-v1\n'  > "$proj/b.txt"

    create_restore_point "c2-default" "$proj/a.txt" "$proj/b.txt" >/dev/null 2>&1 \
        || { _chk "create_restore_point rc" 0 1; return; }

    printf 'alpha-v2\n' > "$proj/a.txt"
    printf 'beta-v2\n'  > "$proj/b.txt"
    chmod 444 "$proj/b.txt"   # b's restore will fail (owner, non-root)

    local rc=0
    restore_from_point "c2-default" >/dev/null 2>&1 || rc=$?
    _chk "default-mode failing restore exits nonzero" "nonzero" "$([[ $rc -ne 0 ]] && echo nonzero || echo "zero:$rc")"

    _chk "default mode: a.txt restored (partial apply preserved)" "alpha-v1" "$(cat "$proj/a.txt")"
    _chk "default mode: b.txt NOT restored (stays pre-restore)" "beta-v2" "$(cat "$proj/b.txt")"
    _chk "default mode: per-file .pre-restore sidecar for a.txt" "alpha-v2" "$(cat "$proj/a.txt.pre-restore" 2>/dev/null)"
    _chk "default mode: per-file .pre-restore sidecar for b.txt" "beta-v2" "$(cat "$proj/b.txt.pre-restore" 2>/dev/null)"

    chmod 644 "$proj/b.txt"

    # Default-mode all-succeed path: rc 0, content restored.
    local rc2=0
    restore_from_point "c2-default" >/dev/null 2>&1 || rc2=$?
    _chk "default-mode all-succeed exit code" 0 "$rc2"
    _chk "default mode all-succeed: b.txt restored to point" "beta-v1" "$(cat "$proj/b.txt")"
}

# -----------------------------------------------------------------------------
# (d) input validation holds in both modes: bad name and missing point.
# -----------------------------------------------------------------------------
test_atomic_input_validation() {
    local proj="$CASE_DIR/proj"
    mkdir -p "$proj"
    printf 'x\n' > "$proj/f.txt"
    create_restore_point "c2-valid" "$proj/f.txt" >/dev/null 2>&1

    local rc=0
    RESTORE_ALL_OR_NOTHING=1 restore_from_point "../traversal" >/dev/null 2>&1 || rc=$?
    _chk "atomic mode rejects invalid point name" "nonzero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)"
    _chk "atomic mode: traversal target untouched" "x" "$(cat "$proj/f.txt")"

    rc=0
    RESTORE_ALL_OR_NOTHING=1 restore_from_point "c2-does-not-exist" >/dev/null 2>&1 || rc=$?
    _chk "atomic mode rejects missing point" "nonzero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)"

    rc=0
    RESTORE_ALL_OR_NOTHING=1 restore_from_point "c2-valid" >/dev/null 2>&1 || rc=$?
    _chk "atomic mode accepts valid point" 0 "$rc"
}

# -----------------------------------------------------------------------------
# NEGATIVE CONTROL (red→green, directive Rule 5): the same one-fails
# scenario WITHOUT all-or-nothing must leave a PARTIAL apply — proving the
# assertion teeth of case (b) actually distinguish the two modes.
# -----------------------------------------------------------------------------
test_negative_control_partial_apply() {
    if (( IS_ROOT )); then
        _mark_skip "running as root: chmod cannot restrict writes"
        return
    fi

    local proj="$CASE_DIR/proj"
    mkdir -p "$proj"
    printf 'alpha-v1\n' > "$proj/a.txt"
    printf 'gamma-v1\n' > "$proj/c.txt"

    create_restore_point "c2-nc" "$proj/a.txt" "$proj/c.txt" >/dev/null 2>&1 \
        || { _chk "create_restore_point rc" 0 1; return; }

    printf 'alpha-v2\n' > "$proj/a.txt"
    rm -f "$proj/c.txt"
    chmod 555 "$proj"     # c's restore fails; a's already succeeded

    local rc=0
    restore_from_point "c2-nc" >/dev/null 2>&1 || rc=$?   # DEFAULT mode
    _chk "control: default mode exits nonzero on failure" "nonzero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)"
    _chk "control: a.txt STAYS restored (partial apply — the defect)" "alpha-v1" "$(cat "$proj/a.txt")"
    _chk "control: c.txt still absent (no total rollback)" 0 "$([[ ! -e "$proj/c.txt" ]] && echo 0 || echo 1)"

    chmod 755 "$proj"
}

echo "=== restore_from_point all-or-nothing integration tests (P3-1) ==="
run_case "atomic all-succeed commits whole point"      test_atomic_all_succeed
run_case "atomic one-fail rolls back byte-identical"   test_atomic_one_fails_rollback
run_case "default mode unchanged (partial + sidecars)" test_default_mode_unchanged
run_case "atomic input validation"                     test_atomic_input_validation
run_case "NEGATIVE CONTROL default-mode partial apply" test_negative_control_partial_apply

echo ""
echo "====== Restore-Point Summary ======"
echo "cases: 5 (marked-skips: $SKIPPED_CASES, failed assertions: $TOTAL_FAILS)"
echo "==================================="

exit "$TOTAL_FAILS"
