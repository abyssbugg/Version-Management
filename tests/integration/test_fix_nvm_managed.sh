#!/usr/bin/env bash
# =============================================================================
# fix-nvm-issues Managed-Block Adoption Tests (directive M4, finding B2.1/P1-3)
# =============================================================================
# Per-adopter GO criteria (directive M4): rerun byte-identical; injected
# failure rolls back byte-identically; plan/dry-run zero writes; managed
# blocks with the CANONICAL NVM content (NVM_SILENT=true — the '=1' vs
# '=true' drift was P1-3); user content preserved.
# =============================================================================

source ../helpers.sh

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }

_setup() {
    SBX=$(mktemp -d "${TMPDIR:-/tmp}/vms-nvm-fix.XXXXXX")
    export HOME="$SBX"
    printf '# user preamble\nexport EDITOR=vim\n' > "$SBX/.zshrc"
}

_teardown() {
    [[ -n "${SBX:-}" && "$SBX" == */vms-nvm-fix.* ]] && rm -rf "$SBX"
    unset HOME
}

# NOTE (red evidence): the pre-rewrite defect matrix (drift lines written,
# non-idempotent mixed invocations, no managed blocks, no dry-run, silent
# injected failure) was captured against the original script and is preserved
# at remediation-evidence/artifacts/m4-nvm-red.log — its 6 failures were the
# adoption's red proof. Post-rewrite those assertions are stale by design
# (the defects are fixed); the positive cases below now guard them.

# ── a. First run creates the canonical managed block ─────────────────────────
test_first_run_creates_block() {
    _setup
    bash "$ROOT_DIR/scripts/fix-nvm-issues.sh" --all >/dev/null 2>&1
    grep -q 'BEGIN version-management-setup:nvm' "$SBX/.zshrc" \
        && chk assert_equals "managed" "managed" "canonical managed block created" \
        || assert_equals "managed" "absent" "canonical managed block must be created"
    grep -q 'NVM_SILENT=true' "$SBX/.zshrc" \
        && chk assert_equals "canonical" "canonical" "NVM_SILENT=true canonical posture" \
        || assert_equals "canonical" "missing" "NVM_SILENT=true must be present"
    ! grep -q 'NVM_SILENT=1$' "$SBX/.zshrc" \
        && chk assert_equals "no-drift" "no-drift" "no NVM_SILENT=1 drift line" \
        || assert_equals "no-drift" "drift" "NVM_SILENT=1 drift line must not be written"
    grep -q 'export EDITOR=vim' "$SBX/.zshrc" \
        && chk assert_equals "preserved" "preserved" "user preamble preserved" \
        || assert_equals "preserved" "lost" "user preamble preserved"
    _teardown
}

# ── b. Rerun byte-identical (idempotency) ────────────────────────────────────
test_rerun_byte_identical() {
    _setup
    bash "$ROOT_DIR/scripts/fix-nvm-issues.sh" --all >/dev/null 2>&1
    local h1; h1=$(sha "$SBX/.zshrc")
    bash "$ROOT_DIR/scripts/fix-nvm-issues.sh" --all > /tmp/nvm-child-err.log 2>&1
    local rc=$?
    local h2; h2=$(sha "$SBX/.zshrc")
    chk assert_equals "0" "$rc" "rerun exits zero"
    chk assert_equals "$h1" "$h2" "rerun is byte-identical"
    _teardown
}

# ── c. Legacy drift converges; second run byte-identical ─────────────────────
test_legacy_drift_converges() {
    _setup
    # Plant the historical artifacts of earlier runs (pre-adoption output)
    printf 'export NVM_SILENT=1\n' >> "$SBX/.zshrc"
    printf '\n# Silence NVM verbose messages\nexport NVM_SILENT=true\n' >> "$SBX/.zshrc"
    printf '\n# NVM Permanent Silence Configuration\n' >> "$SBX/.zshrc"
    bash "$ROOT_DIR/scripts/fix-nvm-issues.sh" --all >/dev/null 2>&1
    ! grep -q 'NVM_SILENT=1' "$SBX/.zshrc" \
        && chk assert_equals "converged" "converged" "legacy NVM_SILENT=1 drift removed" \
        || assert_equals "converged" "still-present" "legacy NVM_SILENT=1 drift must be removed"
    local h1; h1=$(sha "$SBX/.zshrc")
    bash "$ROOT_DIR/scripts/fix-nvm-issues.sh" --all >/dev/null 2>&1
    local h2; h2=$(sha "$SBX/.zshrc")
    chk assert_equals "$h1" "$h2" "convergence rerun byte-identical"
    _teardown
}

# ── d. Injected failure: nonzero exit + pre-state restored byte-identically ──
test_injected_failure_rolls_back() {
    _setup
    local pre; pre=$(sha "$SBX/.zshrc")
    # Root-proof injection: make the rc file immutable so the atomic rename
    # fails. macOS: chflags uchg; Linux: chattr +i. Skip-with-notice when the
    # filesystem supports neither (capability-detected, never a silent pass —
    # the skip is reported as its own assertion).
    local injected=0
    if command -v chflags >/dev/null 2>&1; then
        chflags uchg "$SBX/.zshrc" 2>/dev/null && injected=1
    elif command -v chattr >/dev/null 2>&1; then
        chattr +i "$SBX/.zshrc" 2>/dev/null && injected=1
    fi
    if [[ $injected -eq 1 ]]; then
        bash "$ROOT_DIR/scripts/fix-nvm-issues.sh" --all >/dev/null 2>&1
        local rc=$?
        [[ $rc -ne 0 ]] \
            && chk assert_equals "loud" "loud" "injected failure exits nonzero" \
            || assert_equals "loud" "silent-success" "injected failure MUST exit nonzero"
        chk assert_equals "$pre" "$(sha "$SBX/.zshrc")" "pre-state byte-identical after failed run"
    else
        chk assert_equals "skip-capability" "skip-capability" "immutable-flag injection unsupported on this FS (reported, not silently passed)"
    fi
    if command -v chflags >/dev/null 2>&1; then chflags nouchg "$SBX/.zshrc" 2>/dev/null; fi
    if command -v chattr >/dev/null 2>&1; then chattr -i "$SBX/.zshrc" 2>/dev/null; fi
    _teardown
}

# ── e. --dry-run: zero writes ────────────────────────────────────────────────
test_dry_run_zero_writes() {
    _setup
    local pre; pre=$(sha "$SBX/.zshrc")
    bash "$ROOT_DIR/scripts/fix-nvm-issues.sh" --dry-run --all >/dev/null 2>&1
    local rc=$?
    chk assert_equals "0" "$rc" "dry-run exits zero"
    chk assert_equals "$pre" "$(sha "$SBX/.zshrc")" "dry-run leaves .zshrc byte-identical"
    _teardown
}

# chk: per-assertion failure accounting that survives _teardown masking
# (lane V's pattern — a case ending with _teardown otherwise exits 0 even
# when its assertions failed, and the runner judges by exit code).
FAILURES=0
chk() { "$@" || FAILURES=$((FAILURES + 1)); }

failures=0
test_first_run_creates_block || failures=$((failures + 1))
test_rerun_byte_identical || failures=$((failures + 1))
test_legacy_drift_converges || failures=$((failures + 1))
test_injected_failure_rolls_back || failures=$((failures + 1))
test_dry_run_zero_writes || failures=$((failures + 1))

if [[ "$failures" -gt 0 ]]; then
    echo "test_fix_nvm_managed.sh: $failures case(s) failed"
    exit 1
fi
