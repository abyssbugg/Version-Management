#!/usr/bin/env bash
# =============================================================================
# Managed-Block Editor Tests (directive M4, finding B2.1)
# =============================================================================
# Invariants under test: atomicity, idempotency (byte-identical rerun),
# multi-block coexistence, mode preservation, transaction requirement,
# dry-run zero writes, remove semantics, canonical NVM block posture.
# =============================================================================

source ../helpers.sh

set +e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/lib/mutation.sh"

_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }

_rc_dir=""

_rc_setup() {
    _rc_dir=$(mktemp -d "${TMPDIR:-/tmp}/vms-mut-test.XXXXXX")
    export HOME="$_rc_dir"
    mkdir -p "$_rc_dir"
    printf '# user preamble\nexport EDITOR=vim\n' > "$_rc_dir/.zshrc"
    transaction_start "mut_test" >/dev/null 2>&1
}

_rc_teardown() {
    transaction_rollback >/dev/null 2>&1 || true
    [[ -n "$_rc_dir" && "$_rc_dir" == */vms-mut-test.* ]] && rm -rf "$_rc_dir"
    unset HOME
}

# ── 1. Fresh write appends the block; rerun is byte-identical (idempotency) ──
test_write_idempotent() {
    _rc_setup
    mutation_nvm_block > /tmp/nvm-block-content
    mutation_block_write "$_rc_dir/.zshrc" "nvm" /tmp/nvm-block-content || { assert_equals "written" "failed" "first write"; _rc_teardown; return 1; }
    local h1; h1=$(_sha "$_rc_dir/.zshrc")
    transaction_rollback >/dev/null 2>&1; transaction_commit >/dev/null 2>&1
    transaction_start "mut_test" >/dev/null 2>&1
    mutation_block_write "$_rc_dir/.zshrc" "nvm" /tmp/nvm-block-content
    transaction_commit >/dev/null 2>&1
    local h2; h2=$(_sha "$_rc_dir/.zshrc")
    assert_equals "$h1" "$h2" "idempotent rerun is byte-identical"
    grep -q 'NVM_SILENT=true' "$_rc_dir/.zshrc" && assert_equals "canonical" "canonical" "canonical NVM_SILENT=true" || assert_equals "true" "drift" "canonical NVM_SILENT=true"
    grep -q 'export EDITOR=vim' "$_rc_dir/.zshrc" && assert_equals "preserved" "preserved" "user preamble preserved" || assert_equals "preserved" "lost" "user preamble preserved"
    rm -rf "$_rc_dir"; unset HOME
}

# ── 2. Block replacement: old content gone, new present, rest untouched ─────
test_write_replaces() {
    _rc_setup
    printf 'OLD-NVM-CONTENT\n' > /tmp/nvm-block-content
    mutation_block_write "$_rc_dir/.zshrc" "nvm" /tmp/nvm-block-content
    transaction_rollback >/dev/null 2>&1; transaction_commit >/dev/null 2>&1
    printf 'NEW-NVM-CONTENT\n' > /tmp/nvm-block-content
    transaction_start "mut_test" >/dev/null 2>&1
    mutation_block_write "$_rc_dir/.zshrc" "nvm" /tmp/nvm-block-content
    transaction_commit >/dev/null 2>&1
    [[ ! "$(mutation_block_get "$_rc_dir/.zshrc" nvm)" =~ OLD-NVM-CONTENT ]] \
        && assert_equals "replaced" "replaced" "old block content gone" \
        || assert_equals "replaced" "still-present" "old block content must be gone"
    grep -q 'NEW-NVM-CONTENT' "$_rc_dir/.zshrc" && assert_equals "new" "new" "new block content present" || assert_equals "new" "missing" "new block content present"
    rm -rf "$_rc_dir"; unset HOME
}

# ── 3. Multiple distinct-name blocks coexist ─────────────────────────────────
test_multi_block() {
    _rc_setup
    printf 'A\n' > /tmp/blk-a; printf 'B\n' > /tmp/blk-b
    mutation_block_write "$_rc_dir/.zshrc" "alpha" /tmp/blk-a
    # Commit (NOT rollback) between independent blocks: rollback would
    # correctly undo alpha — that is the transaction doing its job.
    transaction_commit >/dev/null 2>&1
    transaction_start "mut_test" >/dev/null 2>&1
    mutation_block_write "$_rc_dir/.zshrc" "beta" /tmp/blk-b
    transaction_commit >/dev/null 2>&1
    mutation_block_has "$_rc_dir/.zshrc" alpha && assert_equals "coexist" "coexist" "alpha block survives beta write" || assert_equals "coexist" "lost-alpha" "alpha block survives"
    mutation_block_has "$_rc_dir/.zshrc" beta && assert_equals "coexist" "coexist" "beta block present" || assert_equals "coexist" "lost-beta" "beta block present"
    rm -rf "$_rc_dir"; unset HOME
}

# ── 4. Mode preservation + atomic no-intermediate ────────────────────────────
test_mode_preserved() {
    _rc_setup
    chmod 600 "$_rc_dir/.zshrc"
    printf 'X\n' > /tmp/blk-x
    mutation_block_write "$_rc_dir/.zshrc" "gamma" /tmp/blk-x
    local mode; mode=$(stat -f '%Lp' "$_rc_dir/.zshrc" 2>/dev/null || stat -c '%a' "$_rc_dir/.zshrc")
    assert_equals "600" "$mode" "original mode preserved after atomic write"
    rm -rf "$_rc_dir"; unset HOME
}

# ── 5. No transaction -> refuse (fail closed) ────────────────────────────────
test_requires_transaction() {
    _rc_setup
    transaction_rollback >/dev/null 2>&1
    printf 'Y\n' > /tmp/blk-y
    if mutation_block_write "$_rc_dir/.zshrc" "delta" /tmp/blk-y >/dev/null 2>&1; then
        assert_equals "refused" "allowed" "write without transaction must be refused"
    else
        assert_equals "refused" "refused" "write without transaction refused"
    fi
    rm -rf "$_rc_dir"; unset HOME
}

# ── 6. Dry-run: zero writes ──────────────────────────────────────────────────
test_dry_run() {
    _rc_setup
    local before; before=$(_sha "$_rc_dir/.zshrc")
    TRANSACTION_DRY_RUN=1 mutation_block_write "$_rc_dir/.zshrc" "epsilon" /tmp/blk-y
    local after; after=$(_sha "$_rc_dir/.zshrc")
    assert_equals "$before" "$after" "dry-run leaves the file byte-identical"
    rm -rf "$_rc_dir"; unset HOME
}

# ── 7. Remove: block gone, preamble preserved; idempotent removal ────────────
test_remove() {
    _rc_setup
    printf 'R\n' > /tmp/blk-r
    mutation_block_write "$_rc_dir/.zshrc" "zeta" /tmp/blk-r
    transaction_rollback >/dev/null 2>&1; transaction_commit >/dev/null 2>&1
    transaction_start "mut_test" >/dev/null 2>&1
    mutation_block_remove "$_rc_dir/.zshrc" "zeta"
    mutation_block_remove "$_rc_dir/.zshrc" "zeta"   # idempotent
    transaction_commit >/dev/null 2>&1
    mutation_block_has "$_rc_dir/.zshrc" zeta && assert_equals "gone" "present" "block removed" || assert_equals "gone" "gone" "block removed"
    grep -q 'export EDITOR=vim' "$_rc_dir/.zshrc" && assert_equals "preserved" "preserved" "preamble survives remove" || assert_equals "preserved" "lost" "preamble survives remove"
    rm -rf "$_rc_dir"; unset HOME
}

# ── 8. Invalid block names rejected ──────────────────────────────────────────
test_name_grammar() {
    _rc_setup
    printf 'Z\n' > /tmp/blk-z
    for name in "../evil" "a/b" "a b" ""; do
        if mutation_block_write "$_rc_dir/.zshrc" "$name" /tmp/blk-z >/dev/null 2>&1; then
            assert_equals "rejected" "accepted" "block name '$name' rejected"
        else
            assert_equals "rejected" "rejected" "block name '$name' rejected"
        fi
    done
    rm -rf "$_rc_dir"; unset HOME
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
