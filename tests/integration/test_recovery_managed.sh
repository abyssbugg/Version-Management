#!/usr/bin/env bash
# =============================================================================
# emergency-recovery Transaction Adoption Tests (directive M4, finding P3-1)
# =============================================================================
# Per-adopter GO criteria (directive M4): restore_file and reset_to_defaults
# run under backup transactions (lib/backup.sh) — audit-journal record per
# operation; injected failure rolls back the pre-restore state byte-identically
# and exits nonzero; --dry-run plans with zero writes; the .emergency-<ts>
# backup convention is preserved; the typed-RESET confirm is preserved.
#
# The script is menu-driven, so per the lane brief these tests SOURCE it and
# invoke the underlying functions directly for determinism; stdin is fed only
# where a confirm gate is genuinely under test (reset_to_defaults).
#
# Sandbox contract: ONE sandbox HOME is created BEFORE the script is sourced
# (lib/backup.sh freezes DEFAULT_BACKUP_DIR readonly from $HOME at source
# time); each case gets its own subdirectory and its own TXN_AUDIT_LOG.
# Never touches the real $HOME.
# =============================================================================

source "${BASH_SOURCE[0]%/*}/../helpers.sh" || { echo "FATAL: cannot source helpers.sh — run via tests/test_runner.sh (P0-3: unsandboxed HOME writes forbidden)" >&2; exit 1; }

set +e

_SCRIPT_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$_SCRIPT_TEST_DIR/../.." && pwd)"

sha() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    fi
}

# ── Sandbox: created BEFORE the source (see header) ──────────────────────────
SBX="$(mktemp -d "${TMPDIR:-/tmp}/vms-recovery.XXXXXX")"
export HOME="$SBX"

source "$ROOT_DIR/scripts/emergency-recovery.sh"

# The pre-rewrite script sets `set -euo pipefail` unconditionally on source
# and therefore leaks strict mode into this shell; relax it so per-case
# assertions (which rely on return codes) behave uniformly in the red and
# green postures.
set +e
set +u
set +o pipefail

FAILURES=0
# chk: per-assertion failure accounting that survives _teardown masking
# (a case ending with cleanup otherwise exits 0 even when its assertions
# failed, and the runner judges by exit code).
chk() { "$@" || FAILURES=$((FAILURES + 1)); }

# Fresh per-case working directory; the caller exports TXN_AUDIT_LOG in the
# parent shell (an export inside this function would die with the
# command-substitution subshell and never reach the functions under test).
_newcase() {
    local c="$SBX/case-$1"
    rm -rf "$c"
    mkdir -p "$c"
    echo "$c"
}

_journal_has() { grep -q "$1" "$TXN_AUDIT_LOG" 2>/dev/null; }
_txn_dir_exists() {
    local name="$1"
    local found=""
    found=$(find "$HOME/.config-backups/transactions" -maxdepth 1 -type d -name "${name}.*" 2>/dev/null | head -n 1)
    [[ -n "$found" ]]
}

# check: run a silent predicate and report its verdict through assert_equals
# so every red/green assertion is visible in the evidence log.
_check() {
    local desc="$1"; shift
    if "$@"; then
        chk assert_equals "present" "present" "$desc"
    else
        chk assert_equals "present" "absent" "$desc"
    fi
}

# Run one case with case-level failure accounting derived from the assertion
# counter (a case function's own return is only its last command's status).
_run_case() {
    local before=$FAILURES
    "$@"
    [[ $FAILURES -gt $before ]] && return 1
    return 0
}

# ── a. restore_file applies; rerun (same backup) byte-identical ──────────────
test_restore_file_applies_and_rerun_identical() {
    local c; c="$(_newcase a)"; export TXN_AUDIT_LOG="$c/audit.log"
    printf 'CURRENT-ZSHRC\n' > "$c/.zshrc"
    printf 'GOOD-ZSHRC\n'    > "$c/zshrc.backup"

    local rc=0
    restore_file "$c/zshrc.backup" "$c/.zshrc" || rc=$?
    chk assert_equals "0" "$rc" "restore_file exits zero"
    chk assert_equals "$(sha "$c/zshrc.backup")" "$(sha "$c/.zshrc")" \
        "target carries the backup bytes after restore"

    rc=0
    restore_file "$c/zshrc.backup" "$c/.zshrc" || rc=$?
    chk assert_equals "0" "$rc" "rerun exits zero"
    chk assert_equals "$(sha "$c/zshrc.backup")" "$(sha "$c/.zshrc")" \
        "rerun with the same backup is byte-identical (mtime may churn)"
}

# ── b/e. restore_file leaves a transaction + audit-journal record ────────────
test_restore_file_records_transaction_and_journal() {
    local c; c="$(_newcase b)"; export TXN_AUDIT_LOG="$c/audit.log"
    printf 'CURRENT\n' > "$c/.zshrc"
    printf 'GOOD\n'    > "$c/zshrc.backup"

    local rc=0
    restore_file "$c/zshrc.backup" "$c/.zshrc" || rc=$?
    chk assert_equals "0" "$rc" "restore_file exits zero"

    _check "audit journal records emergency_restore start" \
        _journal_has $'\tstart\temergency_restore'
    _check "audit journal records emergency_restore commit" \
        _journal_has $'\tcommit\temergency_restore'
    _check "transaction directory created for emergency_restore" \
        _txn_dir_exists "emergency_restore"
}

# ── c. Injected failure: loud nonzero + pre-state byte-identical ─────────────
test_injected_failure_rolls_back() {
    local c; c="$(_newcase c)"; export TXN_AUDIT_LOG="$c/audit.log"
    printf 'PRE-STATE\n'   > "$c/.p10k.zsh"
    printf 'RESTORED\n'    > "$c/p10k.backup"

    # Root-proof injection: make the target immutable so the final rename
    # fails. macOS: chflags uchg; Linux: chattr +i. Capability-detected, and
    # an unsupported FS is reported as its own assertion, never a silent pass.
    local injected=0
    if command -v chflags >/dev/null 2>&1; then
        chflags uchg "$c/.p10k.zsh" 2>/dev/null && injected=1
    elif command -v chattr >/dev/null 2>&1; then
        chattr +i "$c/.p10k.zsh" 2>/dev/null && injected=1
    fi

    if [[ $injected -eq 1 ]]; then
        local pre; pre="$(sha "$c/.p10k.zsh")"
        local rc=0
        restore_file "$c/p10k.backup" "$c/.p10k.zsh" || rc=$?
        if [[ $rc -ne 0 ]]; then
            chk assert_equals "loud" "loud" \
                "injected mid-restore failure exits nonzero (loud, never silent success)"
        else
            chk assert_equals "loud" "silent-success" \
                "injected mid-restore failure exits nonzero (loud, never silent success)"
        fi
        chk assert_equals "$pre" "$(sha "$c/.p10k.zsh")" \
            "pre-restore state byte-identical after the failed restore"
        _check "audit journal records the emergency_restore rollback" \
            _journal_has $'\trollback\temergency_restore'
        if command -v chflags >/dev/null 2>&1; then chflags nouchg "$c/.p10k.zsh" 2>/dev/null; fi
        if command -v chattr >/dev/null 2>&1; then chattr -i "$c/.p10k.zsh" 2>/dev/null; fi
    else
        chk assert_equals "skip-capability" "skip-capability" \
            "immutable-flag injection unsupported on this FS (reported, not silently passed)"
    fi
}

# ── d. --dry-run: zero writes ────────────────────────────────────────────────
test_dry_run_zero_writes() {
    local c; c="$(_newcase d)"; export TXN_AUDIT_LOG="$c/audit.log"
    printf 'ORIGINAL\n' > "$c/.zshrc"
    printf 'NEW\n'      > "$c/zshrc.backup"

    local pre; pre="$(sha "$c/.zshrc")"
    local rc=0
    TRANSACTION_DRY_RUN=1 restore_file "$c/zshrc.backup" "$c/.zshrc" || rc=$?
    chk assert_equals "0" "$rc" "dry-run exits zero"
    chk assert_equals "$pre" "$(sha "$c/.zshrc")" \
        "dry-run leaves the target byte-identical (no restore performed)"
    local emergency_count
    emergency_count=$(find "$c" -name '.zshrc.emergency-*' 2>/dev/null | wc -l | tr -d ' ')
    chk assert_equals "0" "$emergency_count" \
        "dry-run creates no .emergency-<ts> side-effect file"
}

# ── e. reset_to_defaults: typed confirm + transaction + apply ────────────────
test_reset_confirm_transaction_and_apply() {
    local c; c="$(_newcase e)"; export TXN_AUDIT_LOG="$c/audit.log"
    printf 'USER-P10K\n' > "$SBX/.p10k.zsh"
    printf 'USER-ZSHRC\n' > "$SBX/.zshrc"

    local rc=0
    printf 'RESET\n' | reset_to_defaults || rc=$?
    chk assert_equals "0" "$rc" "reset_to_defaults with typed RESET exits zero"

    local factory="$ROOT_DIR/config/professional-dev-p10k.zsh"
    chk assert_equals "$(sha "$factory")" "$(sha "$SBX/.p10k.zsh")" \
        "reset installs the factory theme byte-identically"

    local emergency_count
    emergency_count=$(find "$SBX/.config/version-manager/backups/emergency" -type f 2>/dev/null | wc -l | tr -d ' ')
    chk assert_equals "2" "$emergency_count" \
        ".emergency backup convention preserved (p10k + zshrc saved)"

    _check "audit journal records emergency_reset start" \
        _journal_has $'\tstart\temergency_reset'
    _check "audit journal records emergency_reset commit" \
        _journal_has $'\tcommit\temergency_reset'
    _check "transaction directory created for emergency_reset" \
        _txn_dir_exists "emergency_reset"
}

# ── f. reset_to_defaults: injected failure rolls back the pre-reset state ────
test_reset_injected_failure_rolls_back() {
    local c; c="$(_newcase f)"; export TXN_AUDIT_LOG="$c/audit.log"
    printf 'USER-P10K\n' > "$SBX/.p10k.zsh"

    local injected=0
    if command -v chflags >/dev/null 2>&1; then
        chflags uchg "$SBX/.p10k.zsh" 2>/dev/null && injected=1
    elif command -v chattr >/dev/null 2>&1; then
        chattr +i "$SBX/.p10k.zsh" 2>/dev/null && injected=1
    fi

    if [[ $injected -eq 1 ]]; then
        local pre; pre="$(sha "$SBX/.p10k.zsh")"
        local rc=0
        printf 'RESET\n' | reset_to_defaults || rc=$?
        if [[ $rc -ne 0 ]]; then
            chk assert_equals "loud" "loud" \
                "failed reset exits nonzero (factory copy must not claim success)"
        else
            chk assert_equals "loud" "silent-success" \
                "failed reset exits nonzero (factory copy must not claim success)"
        fi
        chk assert_equals "$pre" "$(sha "$SBX/.p10k.zsh")" \
            "pre-reset state byte-identical after the failed reset"
        _check "audit journal records the emergency_reset rollback" \
            _journal_has $'\trollback\temergency_reset'
        if command -v chflags >/dev/null 2>&1; then chflags nouchg "$SBX/.p10k.zsh" 2>/dev/null; fi
        if command -v chattr >/dev/null 2>&1; then chattr -i "$SBX/.p10k.zsh" 2>/dev/null; fi
    else
        chk assert_equals "skip-capability" "skip-capability" \
            "immutable-flag injection unsupported on this FS (reported, not silently passed)"
    fi
}

failures=0
_run_case test_restore_file_applies_and_rerun_identical          || failures=$((failures + 1))
_run_case test_restore_file_records_transaction_and_journal      || failures=$((failures + 1))
_run_case test_injected_failure_rolls_back                       || failures=$((failures + 1))
_run_case test_dry_run_zero_writes                               || failures=$((failures + 1))
_run_case test_reset_confirm_transaction_and_apply               || failures=$((failures + 1))
_run_case test_reset_injected_failure_rolls_back                 || failures=$((failures + 1))

# Cleanup the single sandbox at file scope (each case cleaned its own dir
# state only via _newcase's rm -rf on reuse).
if [[ -n "${SBX:-}" && "$SBX" == */vms-recovery.* ]]; then
    rm -rf "$SBX"
fi
unset HOME TXN_AUDIT_LOG

if [[ "$failures" -gt 0 || "$FAILURES" -gt 0 ]]; then
    echo "test_recovery_managed.sh: $failures case(s) failed, $FAILURES assertion(s) failed"
    exit 1
fi
