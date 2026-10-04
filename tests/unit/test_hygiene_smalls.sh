#!/usr/bin/env bash
# =============================================================================
# M5 Lane H — Hygiene Smalls regression guards
# =============================================================================
# One assertion group per fix in the lane's scope:
#   1. B2.2  scoped `make clean` (project temp root + test-results/ only)
#   2. P2-3  dead `sync` stub removed from version-advanced.sh
#   3. P2-2  setup.sh sources lib/error-handling.sh and registers setup_error_trap
#   4. P2-5  logger age-based rotation (VMS_LOG_RETENTION_DAYS, default 14)
#   5. P2-6  single env-overridable NVM pin owned by lib/nvm.sh
#   6. B1.8  no pipe-to-shell guidance in tools/system-diagnostics.sh
#   7. B1.8  no floating @vN tags in version-advanced.sh generated workflows
#   8. P2-11 no shellcheck devDependency in package.json (CI installs via apt)
#   9. P2-12 tests/unit/test_restore.txt removed and gitignored
#
# Environment notes:
#   - Every sourcing subprocess gets a sandboxed HOME (AGENTS.md: never touch
#     the real $HOME from tests) — lib/nvm.sh transitively sources cache.sh,
#     which initializes $HOME/.cache paths at source time.
#   - The make-clean probe uses ${TMPDIR:-/tmp} plus a fixed-name probe under
#     /tmp to prove the old global `rm -rf /tmp/test_*` wildcard is gone; the
#     probe is removed again in the test's own cleanup.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
HOME_SANDBOX="$TMP_BASE/vms-hygiene-home.$$"
mkdir -p "$HOME_SANDBOX"

source "$SCRIPT_DIR/../helpers.sh"

failures=0
record() {
    "$@" || failures=$((failures + 1))
}

# grep -E match count against a file; "0" when nothing matches (grep -c
# exits 1 with no matches — expected, suppressed), "" only if the file is
# missing (all call sites pass files that exist).
count_matches() {
    grep -cE "$1" "$2" 2>/dev/null || true
}

# Local assertion: path is not tracked by git.
assert_file_untracked() {
    local path="$1"
    local message="$2"
    if git -C "$ROOT_DIR" ls-files --error-unmatch "$path" >/dev/null 2>&1; then
        echo "✗ $message (failed) — $path is still tracked"
        return 1
    fi
    echo "✓ $message (passed)"
    return 0
}

# Local assertion: path matches a .gitignore rule.
assert_path_gitignored() {
    local path="$1"
    local message="$2"
    if git -C "$ROOT_DIR" check-ignore -q "$path" 2>/dev/null; then
        echo "✓ $message (passed)"
        return 0
    fi
    echo "✗ $message (failed) — $path is not covered by .gitignore"
    return 1
}

# Source a lib in a fresh, sandboxed bash and run a printf body.
lib_subshell() {  # $1 = lib path, $2 = printf body, [rest] = env via caller
    HOME="$HOME_SANDBOX" bash -c "set +e; source '$1' >/dev/null 2>&1 || true; $2"
}

# ── 1. B2.2: make clean is scoped ────────────────────────────────────────────
test_make_clean_scoped() {
    local proj_tmp="$TMP_BASE/version-management-setup"
    local probe="/tmp/test_unrelated_probe"
    local results_dir="$ROOT_DIR/test-results"

    # Snapshot the emitter's in-flight artifacts: `make clean` legitimately
    # wipes test-results/, but during a full-suite run emit-manifest.sh is
    # still appending manifest.tsv.tmp there — save it and put it back below.
    local snap="$TMP_BASE/hygiene-results-snap.$$"
    if [[ -d "$results_dir" ]]; then
        mkdir -p "$snap"
        find "$results_dir" -maxdepth 1 -type f -exec mv {} "$snap"/ \; 2>/dev/null || true
    fi

    mkdir -p "$proj_tmp" "$results_dir"
    echo "scoped-clean probe" > "$proj_tmp/testfile"
    echo "unrelated probe — must survive make clean" > "$probe"
    echo "manifest junk" > "$results_dir/junk.file"

    local out rc=0
    out="$(make -C "$ROOT_DIR" clean 2>&1)" || rc=$?
    record assert_exit_code 0 "$rc" "make clean exits 0 (B2.2)"
    record assert_file_not_exists "$proj_tmp/testfile" \
        "make clean removes the project-owned temp root (B2.2)"
    record assert_file_not_exists "$results_dir/junk.file" \
        "make clean removes repo-local test-results/ (B2.2)"
    record assert_file_exists "$probe" \
        "make clean leaves UNRELATED /tmp/test_* files alone (B2.2)"
    record assert_equals "0" \
        "$(count_matches 'rm -rf /tmp/test_' "$ROOT_DIR/Makefile")" \
        "Makefile no longer uses a global /tmp/test_* wildcard (B2.2)"

    # Cleanup: restore the emitter's files (without the junk asserted gone),
    # drop the probe and any project-temp residue.
    if [[ -d "$snap" ]]; then
        mkdir -p "$results_dir"
        mv "$snap"/* "$results_dir"/ 2>/dev/null || true
        rmdir "$snap" 2>/dev/null || true
    fi
    rm -f "$probe"
    rm -rf "$proj_tmp"
}

# ── 2. P2-3: dead sync stub removed ──────────────────────────────────────────
test_sync_stub_removed() {
    local f="$ROOT_DIR/version-advanced.sh"
    record assert_equals "0" \
        "$(count_matches 'Implementation would go here' "$f")" \
        "dead sync stub text removed (P2-3)"
    record assert_equals "0" \
        "$(count_matches '^[[:space:]]*sync\)' "$f")" \
        "sync CLI dispatch case removed (P2-3)"
    record assert_equals "0" \
        "$(count_matches 'Aligns global defaults' "$f")" \
        "help no longer advertises the removed sync command (P2-3)"
}

# ── 3. P2-2: setup.sh wires the standard ERR trap ────────────────────────────
test_setup_error_trap_wired() {
    local f="$ROOT_DIR/setup.sh"
    record assert_contains "lib/error-handling.sh" "$(cat "$f")" \
        "setup.sh sources lib/error-handling.sh (P2-2)"
    record assert_contains "setup_error_trap" "$(cat "$f")" \
        "setup.sh registers setup_error_trap (P2-2)"

    # Behavioral: sourcing setup.sh (which defines main but does not run it)
    # must leave an ERR trap registered in the sourcing shell.
    local traps
    traps="$(HOME="$HOME_SANDBOX" bash -c \
        "set +e; cd '$ROOT_DIR' && source ./setup.sh >/dev/null 2>&1; trap -p ERR")"
    record assert_contains "handle_error" "$traps" \
        "sourcing setup.sh installs the ERR trap (P2-2, behavioral)"
}

# ── 4. P2-5: logger age-based rotation ───────────────────────────────────────
test_logger_rotation() {
    local dir="$TMP_BASE/logger-rotation.$$.test"
    mkdir -p "$dir"

    # (a) rotation helper exists
    record assert_not_empty \
        "$(lib_subshell "$ROOT_DIR/lib/logger.sh" 'declare -F _logger_prune_old_logs')" \
        "logger defines the rotation helper (P2-5)"

    # (b) a file older than the default window is pruned by init_logger
    local stale="$dir/stale.log"
    echo "OLD CONTENT" > "$stale"
    touch -t 202001010000 "$stale"
    lib_subshell "$ROOT_DIR/lib/logger.sh" "init_logger '$stale' false" >/dev/null 2>&1
    record assert_equals "0" \
        "$(grep -c "OLD CONTENT" "$stale" 2>/dev/null | tr -d ' ')" \
        "init_logger prunes a LOG_FILE older than the retention window (P2-5)"

    # (c) a file within the window survives (marker content preserved)
    local fresh="$dir/fresh.log"
    echo "FRESH CONTENT" > "$fresh"
    lib_subshell "$ROOT_DIR/lib/logger.sh" "init_logger '$fresh' false" >/dev/null 2>&1
    record assert_contains "FRESH CONTENT" "$(cat "$fresh" 2>/dev/null)" \
        "init_logger keeps a LOG_FILE within the retention window (P2-5)"

    # (d) VMS_LOG_RETENTION_DAYS=0 disables pruning entirely
    local keep="$dir/keep.log"
    echo "OLD CONTENT" > "$keep"
    touch -t 202001010000 "$keep"
    VMS_LOG_RETENTION_DAYS=0 lib_subshell "$ROOT_DIR/lib/logger.sh" \
        "init_logger '$keep' false" >/dev/null 2>&1
    record assert_contains "OLD CONTENT" "$(cat "$keep" 2>/dev/null)" \
        "VMS_LOG_RETENTION_DAYS=0 disables rotation (P2-5)"

    # (e) the env override widens the window (2020 file survives at 9999 days)
    local wide="$dir/wide.log"
    echo "OLD CONTENT" > "$wide"
    touch -t 202001010000 "$wide"
    VMS_LOG_RETENTION_DAYS=9999 lib_subshell "$ROOT_DIR/lib/logger.sh" \
        "init_logger '$wide' false" >/dev/null 2>&1
    record assert_contains "OLD CONTENT" "$(cat "$wide" 2>/dev/null)" \
        "VMS_LOG_RETENTION_DAYS override is honored (P2-5)"

    rm -rf "$dir"
}

# ── 5. P2-6: single env-overridable NVM pin ──────────────────────────────────
test_nvm_pin_single_source() {
    local pin_default pin_override
    pin_default="$(lib_subshell "$ROOT_DIR/lib/nvm.sh" 'printf %s "${NVM_VERSION:-}"')"
    pin_override="$(NVM_VERSION=v0.39.0 lib_subshell "$ROOT_DIR/lib/nvm.sh" \
        'printf %s "${NVM_VERSION:-}"')"
    record assert_equals "v0.39.7" "$pin_default" \
        "lib/nvm.sh defaults the NVM pin to v0.39.7 (P2-6)"
    record assert_equals "v0.39.0" "$pin_override" \
        "NVM_VERSION env overrides the pin (P2-6)"
    record assert_equals "1" \
        "$(count_matches 'v0\.39\.7' "$ROOT_DIR/lib/nvm.sh")" \
        "lib/nvm.sh contains exactly one hardcoded v0.39.7 (the default) (P2-6)"
    record assert_contains 'local version="$NVM_VERSION"' "$(cat "$ROOT_DIR/lib/nvm.sh")" \
        "nvm_install consumes the NVM_VERSION variable (P2-6)"
}

# ── 6. B1.8: no pipe-to-shell guidance in system-diagnostics.sh ──────────────
test_diagnostics_no_pipe_to_shell() {
    local f="$ROOT_DIR/tools/system-diagnostics.sh"
    record assert_equals "0" \
        "$(count_matches 'curl.*\|[[:space:]]*(ba)?sh' "$f")" \
        "no 'curl | bash' guidance (B1.8, ENGINEERING_RULES §2)"
    record assert_contains "checksum" "$(cat "$f")" \
        "install guidance names the download->checksum-verify policy (B1.8)"
}

# ── 7. B1.8: generated workflows are SHA-pinned ──────────────────────────────
test_generated_workflows_sha_pinned() {
    local f="$ROOT_DIR/version-advanced.sh"
    record assert_equals "0" \
        "$(count_matches 'uses:.*@v[0-9]+([[:space:]]|$)' "$f")" \
        "no floating @vN action tags in generated workflows (B1.8)"
    record assert_equals "2" \
        "$(count_matches 'actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683' "$f")" \
        "checkout pinned to the repo-standard SHA in both templates (B1.8)"
    record assert_equals "1" \
        "$(count_matches 'actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065' "$f")" \
        "setup-python pinned to the repo-standard SHA (B1.8)"
}

# ── 8. P2-11: lockfile decision — no shellcheck devDependency ────────────────
test_package_json_no_shellcheck() {
    record assert_equals "0" \
        "$(count_matches '"shellcheck"' "$ROOT_DIR/package.json")" \
        "package.json has no shellcheck devDependency (P2-11: CI installs via apt)"
}

# ── 9. P2-12: tracked byproduct removed + gitignored ─────────────────────────
test_restore_byproduct_gone() {
    # P2-12: the 0-byte byproduct must not be TRACKED, and .gitignore must
    # cover the pattern. The file itself is REGENERATED at runtime by
    # tests/unit/test_backup.sh (which writes cwd-relative), so "file does
    # not exist" is the wrong invariant — "untracked and ignored" is right,
    # and stays stable regardless of suite ordering.
    record assert_file_untracked "$ROOT_DIR/tests/unit/test_restore.txt" \
        "tests/unit/test_restore.txt no longer tracked in git (P2-12)"
    record assert_path_gitignored "tests/unit/test_restore.txt" \
        "test_restore.txt byproduct covered by .gitignore (P2-12)"
    record assert_contains "test_restore.txt" "$(cat "$ROOT_DIR/.gitignore")" \
        ".gitignore names the test_restore.txt pattern explicitly (P2-12)"
}

# ── Run ──────────────────────────────────────────────────────────────────────
test_make_clean_scoped
test_sync_stub_removed
test_setup_error_trap_wired
test_logger_rotation
test_nvm_pin_single_source
test_diagnostics_no_pipe_to_shell
test_generated_workflows_sha_pinned
test_package_json_no_shellcheck
test_restore_byproduct_gone

rm -rf "$HOME_SANDBOX"

if [[ "$failures" -gt 0 ]]; then
    echo "test_hygiene_smalls.sh: $failures guard(s) violated"
    exit 1
fi
exit 0
