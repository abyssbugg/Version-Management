#!/usr/bin/env bash
# =============================================================================
# setup-versions.sh Managed-Block Adoption Tests (directive M4, B2.1/P1-3)
# =============================================================================
# Per-adopter GO criteria (directive M4): first run creates the CANONICAL
# managed NVM block (NVM_SILENT=true — the '=1' vs '=true' drift was P1-3);
# rerun byte-identical; legacy drift from pre-adoption runs converges without
# duplication; injected failure exits nonzero with byte-identical pre-state;
# dry-run (TRANSACTION_DRY_RUN=1) performs zero writes; user content preserved.
#
# Failure accounting: every assertion is wrapped by chk() so a failed
# assertion reaches the suite exit code (the runner judges by exit code).
# Never touches the real $HOME: every case sandboxes HOME via mktemp (P0-3).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# CWD-independent: resolves regardless of where the suite is invoked from.
source "$SCRIPT_DIR/../helpers.sh"

set +e

CASE_FAILED=0
chk() { "$@" || CASE_FAILED=1; }

sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }

_setup() {
    SBX=$(mktemp -d "${TMPDIR:-/tmp}/vms-setup-versions.XXXXXX")
    export HOME="$SBX"
    printf '# user preamble\nexport EDITOR=vim\n' > "$SBX/.zshrc"
    # check_nvm_installed() must pass: detect_nvm finds $HOME/.nvm/nvm.sh.
    mkdir -p "$SBX/.nvm"
    printf '# nvm stub (sandbox)\n' > "$SBX/.nvm/nvm.sh"
}

_teardown() {
    [[ -n "${SBX:-}" && "$SBX" == */vms-setup-versions.* ]] && rm -rf "$SBX"
    unset HOME
}

_run() {
    bash "$ROOT_DIR/setup-versions.sh" configure-nvm
}

# ── a. First run creates the canonical managed block ─────────────────────────
test_first_run_creates_block() {
    CASE_FAILED=0
    _setup
    _run >/dev/null 2>&1
    local rc=$?
    chk assert_equals "0" "$rc" "configure-nvm exits zero on first run"
    grep -q 'BEGIN version-management-setup:nvm' "$SBX/.zshrc" \
        && chk assert_equals "managed" "managed" "canonical managed block created" \
        || chk assert_equals "managed" "absent" "canonical managed block must be created"
    # Exact bare canonical line (mutation_nvm_block emits 'NVM_SILENT=true'
    # WITHOUT export; the legacy append wrote 'export NVM_SILENT=true').
    grep -q '^NVM_SILENT=true$' "$SBX/.zshrc" \
        && chk assert_equals "canonical" "canonical" "NVM_SILENT=true canonical bare-line posture" \
        || chk assert_equals "canonical" "missing" "NVM_SILENT=true canonical bare line must be present"
    grep -q 'export NVM_DIR' "$SBX/.zshrc" \
        && chk assert_equals "nvm-dir" "nvm-dir" "NVM_DIR export present in canonical block" \
        || chk assert_equals "nvm-dir" "missing" "NVM_DIR export must be present"
    ! grep -q 'Professional terminal setup - silence nvm output' "$SBX/.zshrc" \
        && chk assert_equals "no-drift" "no-drift" "no legacy unmanaged drift comment" \
        || chk assert_equals "no-drift" "drift" "legacy drift comment must not be written"
    grep -q 'export EDITOR=vim' "$SBX/.zshrc" \
        && chk assert_equals "preserved" "preserved" "user preamble preserved" \
        || chk assert_equals "preserved" "lost" "user preamble preserved"
    _teardown
    return "$CASE_FAILED"
}

# ── b. Rerun byte-identical (idempotency) ────────────────────────────────────
test_rerun_byte_identical() {
    CASE_FAILED=0
    _setup
    _run >/dev/null 2>&1
    local h1; h1=$(sha "$SBX/.zshrc")
    _run >/dev/null 2>&1
    local rc=$?
    local h2; h2=$(sha "$SBX/.zshrc")
    chk assert_equals "0" "$rc" "rerun exits zero"
    chk assert_equals "$h1" "$h2" "rerun is byte-identical"
    _teardown
    return "$CASE_FAILED"
}

# ── b2. Converged sibling state: no duplicate drift appended ─────────────────
# The canonical block (lib/mutation.sh:mutation_nvm_block) carries the BARE
# line 'NVM_SILENT=true'. When that line already exists (converged sibling
# adopter), the pre-rewrite guard `grep -q "export NVM_SILENT"` misses and the
# script appends a second, conflicting fragment — the exact multi-fragment
# drift B2.1 exists to kill.
test_converged_sibling_no_duplicates() {
    CASE_FAILED=0
    _setup
    # Simulate a file already converged onto the canonical bare-line form.
    printf 'NVM_SILENT=true\n' >> "$SBX/.zshrc"
    _run >/dev/null 2>&1
    local rc=$?
    chk assert_equals "0" "$rc" "run against converged sibling state exits zero"
    ! grep -q 'Professional terminal setup - silence nvm output' "$SBX/.zshrc" \
        && chk assert_equals "no-drift" "no-drift" "no drift fragment appended over converged state" \
        || chk assert_equals "no-drift" "appended" "no drift fragment must be appended over converged state"
    ! grep -q 'export NVM_SILENT=true' "$SBX/.zshrc" \
        && chk assert_equals "no-conflict" "no-conflict" "no conflicting exported NVM_SILENT line" \
        || chk assert_equals "no-conflict" "conflicting" "no conflicting exported NVM_SILENT line may be appended"
    local h1; h1=$(sha "$SBX/.zshrc")
    _run >/dev/null 2>&1
    chk assert_equals "$h1" "$(sha "$SBX/.zshrc")" "rerun after convergence byte-identical"
    _teardown
    return "$CASE_FAILED"
}

# ── c. Legacy drift converges; rerun byte-identical ──────────────────────────
test_legacy_drift_converges() {
    CASE_FAILED=0
    _setup
    # Plant the historical artifacts of pre-adoption runs (exact lines the
    # old unmanaged appenders wrote).
    printf 'export NVM_SILENT=1\n' >> "$SBX/.zshrc"
    printf '# Professional terminal setup - silence nvm output\n' >> "$SBX/.zshrc"
    printf 'export NVM_SILENT=true\n' >> "$SBX/.zshrc"
    printf '# Silence NVM verbose messages\n' >> "$SBX/.zshrc"
    printf '# NVM Permanent Silence Configuration\n' >> "$SBX/.zshrc"
    _run >/dev/null 2>&1
    local rc=$?
    chk assert_equals "0" "$rc" "convergence run exits zero"
    ! grep -q 'NVM_SILENT=1' "$SBX/.zshrc" \
        && chk assert_equals "converged" "converged" "legacy NVM_SILENT=1 drift removed" \
        || chk assert_equals "converged" "still-present" "legacy NVM_SILENT=1 drift must be removed"
    ! grep -q 'Professional terminal setup - silence nvm output' "$SBX/.zshrc" \
        && chk assert_equals "converged-2" "converged-2" "legacy drift comment removed" \
        || chk assert_equals "converged-2" "still-present" "legacy drift comment must be removed"
    ! grep -q 'export NVM_SILENT=true' "$SBX/.zshrc" \
        && chk assert_equals "converged-3" "converged-3" "legacy exported NVM_SILENT=true removed (canonical bare form in block only)" \
        || chk assert_equals "converged-3" "still-present" "legacy exported NVM_SILENT=true must be removed"
    ! grep -q 'Silence NVM verbose messages' "$SBX/.zshrc" \
        && chk assert_equals "converged-4" "converged-4" "sibling-script drift comment removed" \
        || chk assert_equals "converged-4" "still-present" "sibling-script drift comment must be removed"
    grep -q 'BEGIN version-management-setup:nvm' "$SBX/.zshrc" \
        && chk assert_equals "managed" "managed" "canonical block present after convergence" \
        || chk assert_equals "managed" "absent" "canonical block must be present after convergence"
    local h1; h1=$(sha "$SBX/.zshrc")
    _run >/dev/null 2>&1
    chk assert_equals "$h1" "$(sha "$SBX/.zshrc")" "convergence rerun byte-identical"
    _teardown
    return "$CASE_FAILED"
}

# ── d. Injected failure: nonzero exit + pre-state restored byte-identically ──
test_injected_failure_rolls_back() {
    CASE_FAILED=0
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
        _run >/dev/null 2>&1
        local rc=$?
        [[ $rc -ne 0 ]] \
            && chk assert_equals "loud" "loud" "injected failure exits nonzero" \
            || chk assert_equals "loud" "silent-success" "injected failure MUST exit nonzero"
        chk assert_equals "$pre" "$(sha "$SBX/.zshrc")" "pre-state byte-identical after failed run"
    else
        chk assert_equals "skip-capability" "skip-capability" "immutable-flag injection unsupported on this FS (reported, not silently passed)"
    fi
    if command -v chflags >/dev/null 2>&1; then chflags nouchg "$SBX/.zshrc" 2>/dev/null; fi
    if command -v chattr >/dev/null 2>&1; then chattr -i "$SBX/.zshrc" 2>/dev/null; fi
    _teardown
    return "$CASE_FAILED"
}

# ── e. Dry-run: zero writes (pristine AND drift-present states) ──────────────
test_dry_run_zero_writes() {
    CASE_FAILED=0
    # e1. Pristine state: TRANSACTION_DRY_RUN=1 must plan, not write. (The
    # pre-rewrite script ignores the variable and appends its drift lines.)
    _setup
    local pre; pre=$(sha "$SBX/.zshrc")
    TRANSACTION_DRY_RUN=1 _run >/dev/null 2>&1
    local rc=$?
    chk assert_equals "0" "$rc" "dry-run exits zero"
    chk assert_equals "$pre" "$(sha "$SBX/.zshrc")" "dry-run on pristine state performs zero writes"
    _teardown
    # e2. Drift-present state: the plan must not mutate even where a legacy
    # strip would otherwise apply.
    _setup
    printf 'export NVM_SILENT=1\n# Professional terminal setup - silence nvm output\n' >> "$SBX/.zshrc"
    pre=$(sha "$SBX/.zshrc")
    TRANSACTION_DRY_RUN=1 _run >/dev/null 2>&1
    rc=$?
    chk assert_equals "0" "$rc" "dry-run (drift present) exits zero"
    chk assert_equals "$pre" "$(sha "$SBX/.zshrc")" "dry-run on drift state performs zero writes (no strip)"
    _teardown
    return "$CASE_FAILED"
}

# ── f. Unrelated user content preserved ──────────────────────────────────────
test_unrelated_content_preserved() {
    CASE_FAILED=0
    _setup
    printf 'alias gs="git status"\n\nexport PATH="$HOME/bin:$PATH"\n' >> "$SBX/.zshrc"
    _run >/dev/null 2>&1
    grep -q 'alias gs="git status"' "$SBX/.zshrc" \
        && chk assert_equals "preserved" "preserved" "user alias preserved" \
        || chk assert_equals "preserved" "lost" "user alias preserved"
    grep -q 'export PATH="$HOME/bin:$PATH"' "$SBX/.zshrc" \
        && chk assert_equals "preserved-2" "preserved-2" "user PATH line preserved" \
        || chk assert_equals "preserved-2" "lost" "user PATH line preserved"
    grep -q 'export EDITOR=vim' "$SBX/.zshrc" \
        && chk assert_equals "preserved-3" "preserved-3" "user EDITOR line preserved" \
        || chk assert_equals "preserved-3" "lost" "user EDITOR line preserved"
    _teardown
    return "$CASE_FAILED"
}

failures=0
test_first_run_creates_block || failures=$((failures + 1))
test_rerun_byte_identical || failures=$((failures + 1))
test_converged_sibling_no_duplicates || failures=$((failures + 1))
test_legacy_drift_converges || failures=$((failures + 1))
test_injected_failure_rolls_back || failures=$((failures + 1))
test_dry_run_zero_writes || failures=$((failures + 1))
test_unrelated_content_preserved || failures=$((failures + 1))

if [[ "$failures" -gt 0 ]]; then
    echo "test_setup_versions_managed.sh: $failures case(s) failed"
    exit 1
fi
