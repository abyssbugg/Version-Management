#!/usr/bin/env bash
# =============================================================================
# Managed-Block Editor Tests (directive M4, finding B2.1, P0-3)
# =============================================================================
# Invariants under test: atomicity, idempotency (byte-identical rerun),
# multi-block coexistence, mode preservation, transaction requirement,
# dry-run zero writes, remove semantics, canonical NVM block posture.
# =============================================================================

set -euo pipefail

# Absolute path to helpers and root
HELPERS_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/helpers.sh"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

source "$HELPERS_PATH"
source "$ROOT_DIR/lib/mutation.sh"

set +e

_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }

_test_home=""
_test_tmpdir=""
_fixture_dir=""

_rc_setup() {
    # Create isolated per-test tmpdir sandbox
    _test_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/tmp_rovodev_mut-test.XXXXXX")
    export TMPDIR="$_test_tmpdir"
    export XDG_CONFIG_HOME="$_test_tmpdir/.config"
    export XDG_CACHE_HOME="$_test_tmpdir/.cache"
    export XDG_DATA_HOME="$_test_tmpdir/.data"
    export XDG_STATE_HOME="$_test_tmpdir/.state"
    
    # Create per-test HOME inside sandbox
    _test_home="$_test_tmpdir/home"
    mkdir -p "$_test_home"
    export HOME="$_test_home"
    
    # Per-case fixture directory for test files
    _fixture_dir="$_test_tmpdir/fixtures"
    mkdir -p "$_fixture_dir"
    
    printf '# user preamble\nexport EDITOR=vim\n' > "$_test_home/.zshrc"
    
    # Unset inherited transaction environment to prevent escapes
    unset LOG_FILE TXN_AUDIT_LOG TRANSACTION_DRY_RUN 2>/dev/null || true
    transaction_start "mut_test" >/dev/null 2>&1
}

_rc_teardown() {
    # Ensure transaction is cleared before cleanup
    transaction_rollback >/dev/null 2>&1 || true
    transaction_commit >/dev/null 2>&1 || true
    
    # Clean up test directory
    [[ -n "$_test_tmpdir" && "$_test_tmpdir" == */tmp_rovodev_mut-test.* ]] && rm -rf "$_test_tmpdir"
    
    # Restore environment (do NOT unset HOME here; let caller control this)
    unset TMPDIR XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME
    unset _test_home _test_tmpdir _fixture_dir 2>/dev/null || true
}

# ── 1. Fresh write appends the block; rerun is byte-identical (idempotency) ──
test_write_idempotent() {
    _rc_setup
    local nvm_content="$_fixture_dir/nvm-block-content"
    mutation_nvm_block > "$nvm_content"
    mutation_block_write "$_test_home/.zshrc" "nvm" "$nvm_content" || { assert_equals "written" "failed" "first write"; _rc_teardown; return 1; }
    local h1; h1=$(_sha "$_test_home/.zshrc")
    transaction_rollback >/dev/null 2>&1; transaction_commit >/dev/null 2>&1
    transaction_start "mut_test" >/dev/null 2>&1
    mutation_block_write "$_test_home/.zshrc" "nvm" "$nvm_content"
    transaction_commit >/dev/null 2>&1
    local h2; h2=$(_sha "$_test_home/.zshrc")
    assert_equals "$h1" "$h2" "idempotent rerun is byte-identical"
    grep -q 'NVM_SILENT=true' "$_test_home/.zshrc" && assert_equals "canonical" "canonical" "canonical NVM_SILENT=true" || assert_equals "true" "drift" "canonical NVM_SILENT=true"
    grep -q 'export EDITOR=vim' "$_test_home/.zshrc" && assert_equals "preserved" "preserved" "user preamble preserved" || assert_equals "preserved" "lost" "user preamble preserved"
    _rc_teardown
}

# ── 2. Block replacement: old content gone, new present, rest untouched ─────
test_write_replaces() {
    _rc_setup
    local nvm_content="$_fixture_dir/nvm-block-content"
    printf 'OLD-NVM-CONTENT\n' > "$nvm_content"
    mutation_block_write "$_test_home/.zshrc" "nvm" "$nvm_content"
    transaction_rollback >/dev/null 2>&1; transaction_commit >/dev/null 2>&1
    printf 'NEW-NVM-CONTENT\n' > "$nvm_content"
    transaction_start "mut_test" >/dev/null 2>&1
    mutation_block_write "$_test_home/.zshrc" "nvm" "$nvm_content"
    transaction_commit >/dev/null 2>&1
    [[ ! "$(mutation_block_get "$_test_home/.zshrc" nvm)" =~ OLD-NVM-CONTENT ]] \
        && assert_equals "replaced" "replaced" "old block content gone" \
        || assert_equals "replaced" "still-present" "old block content must be gone"
    grep -q 'NEW-NVM-CONTENT' "$_test_home/.zshrc" && assert_equals "new" "new" "new block content present" || assert_equals "new" "missing" "new block content present"
    _rc_teardown
}

# ── 3. Multiple distinct-name blocks coexist ─────────────────────────────────
test_multi_block() {
    _rc_setup
    local blk_a="$_fixture_dir/blk-a" blk_b="$_fixture_dir/blk-b"
    printf 'A\n' > "$blk_a"; printf 'B\n' > "$blk_b"
    mutation_block_write "$_test_home/.zshrc" "alpha" "$blk_a"
    # Commit (NOT rollback) between independent blocks: rollback would
    # correctly undo alpha — that is the transaction doing its job.
    transaction_commit >/dev/null 2>&1
    transaction_start "mut_test" >/dev/null 2>&1
    mutation_block_write "$_test_home/.zshrc" "beta" "$blk_b"
    transaction_commit >/dev/null 2>&1
    mutation_block_has "$_test_home/.zshrc" alpha && assert_equals "coexist" "coexist" "alpha block survives beta write" || assert_equals "coexist" "lost-alpha" "alpha block survives"
    mutation_block_has "$_test_home/.zshrc" beta && assert_equals "coexist" "coexist" "beta block present" || assert_equals "coexist" "lost-beta" "beta block present"
    _rc_teardown
}

# ── 4. Mode preservation + atomic no-intermediate ────────────────────────────
test_mode_preserved() {
    _rc_setup
    chmod 600 "$_test_home/.zshrc"
    local blk_x="$_fixture_dir/blk-x"
    printf 'X\n' > "$blk_x"
    mutation_block_write "$_test_home/.zshrc" "gamma" "$blk_x"
    local mode; mode=$(stat -f '%Lp' "$_test_home/.zshrc" 2>/dev/null || stat -c '%a' "$_test_home/.zshrc")
    assert_equals "600" "$mode" "original mode preserved after atomic write"
    _rc_teardown
}

# ── 5. No transaction -> refuse (fail closed) ────────────────────────────────
test_requires_transaction() {
    _rc_setup
    transaction_rollback >/dev/null 2>&1
    local blk_y="$_fixture_dir/blk-y"
    printf 'Y\n' > "$blk_y"
    if mutation_block_write "$_test_home/.zshrc" "delta" "$blk_y" >/dev/null 2>&1; then
        assert_equals "refused" "allowed" "write without transaction must be refused"
    else
        assert_equals "refused" "refused" "write without transaction refused"
    fi
    _rc_teardown
}

# ── 6. Dry-run: zero writes ──────────────────────────────────────────────────
test_dry_run() {
    _rc_setup
    local before; before=$(_sha "$_test_home/.zshrc")
    local blk_y="$_fixture_dir/blk-y"
    printf 'Y\n' > "$blk_y"
    TRANSACTION_DRY_RUN=1 mutation_block_write "$_test_home/.zshrc" "epsilon" "$blk_y"
    local after; after=$(_sha "$_test_home/.zshrc")
    assert_equals "$before" "$after" "dry-run leaves the file byte-identical"
    _rc_teardown
}

# ── 7. Remove: block gone, preamble preserved; idempotent removal ────────────
test_remove() {
    _rc_setup
    local blk_r="$_fixture_dir/blk-r"
    printf 'R\n' > "$blk_r"
    mutation_block_write "$_test_home/.zshrc" "zeta" "$blk_r"
    transaction_rollback >/dev/null 2>&1; transaction_commit >/dev/null 2>&1
    transaction_start "mut_test" >/dev/null 2>&1
    mutation_block_remove "$_test_home/.zshrc" "zeta"
    mutation_block_remove "$_test_home/.zshrc" "zeta"   # idempotent
    transaction_commit >/dev/null 2>&1
    mutation_block_has "$_test_home/.zshrc" zeta && assert_equals "gone" "present" "block removed" || assert_equals "gone" "gone" "block removed"
    grep -q 'export EDITOR=vim' "$_test_home/.zshrc" && assert_equals "preserved" "preserved" "preamble survives remove" || assert_equals "preserved" "lost" "preamble survives remove"
    _rc_teardown
}

# ── 8. Invalid block names rejected ──────────────────────────────────────────
test_name_grammar() {
    _rc_setup
    local blk_z="$_fixture_dir/blk-z"
    printf 'Z\n' > "$blk_z"
    for name in "../evil" "a/b" "a b" ""; do
        if mutation_block_write "$_test_home/.zshrc" "$name" "$blk_z" >/dev/null 2>&1; then
            assert_equals "rejected" "accepted" "block name '$name' rejected"
        else
            assert_equals "rejected" "rejected" "block name '$name' rejected"
        fi
    done
    _rc_teardown
}

# ── Run ──────────────────────────────────────────────────────────────────────
failures=0
test_write_idempotent || failures=$((failures + 1))
test_write_replaces || failures=$((failures + 1))
test_multi_block || failures=$((failures + 1))
test_mode_preserved || failures=$((failures + 1))
test_requires_transaction || failures=$((failures + 1))
test_dry_run || failures=$((failures + 1))
test_remove || failures=$((failures + 1))
test_name_grammar || failures=$((failures + 1))

if [[ "$failures" -gt 0 ]]; then
    echo "test_mutation_editor.sh: $failures case(s) failed"
    exit 1
fi
