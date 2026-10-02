#!/usr/bin/env bash
# =============================================================================
# Plugin Trust-Boundary Security Tests (remediation directive B1.1)
# =============================================================================
# Binding invariants (directive):
#   - Plugin names obey the shared strict identifier grammar
#     (lib/validation.sh validate_identifier): traversal ('..'), separators
#     and hidden names are rejected and write NOTHING anywhere.
#   - Every install/remove target is canonically contained inside the plugin
#     directory ($HOME/.config/version-manager/plugins) — sibling-proof.
#   - Symlink escapes fail closed: installing over, or removing through, a
#     symlink that leaves the plugin directory must not create, modify or
#     delete anything outside it.
#   - install/remove are routed through the transaction primitive
#     (lib/backup.sh): a mid-way failure leaves no half-installed state and
#     invokes rollback.
#   - Happy-path install/remove/template behavior is preserved.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../helpers.sh
source "$SCRIPT_DIR/../helpers.sh"

# bash >= 4 contract (same as tests/test_runner.sh: associative arrays)
if ((BASH_VERSINFO[0] < 4)); then
    echo "SKIP: bash >= 4.0 required (found ${BASH_VERSION})"
    exit 0
fi

set +e

coverage_init "plugin_security"

# ── Sandbox HOME FIRST: plugins.sh and backup.sh resolve their state
# directories from $HOME at source time, so every file these tests touch
# (plugin dir, transaction dirs, canaries) must live under the sandbox.
setup_test

# shellcheck source=lib/validation.sh
source "$ROOT_DIR/lib/validation.sh"
# shellcheck source=lib/backup.sh
source "$ROOT_DIR/lib/backup.sh"
# shellcheck source=lib/plugins.sh
source "$ROOT_DIR/lib/plugins.sh"

# Silence log noise (defined AFTER sourcing the libs so the stubs win)
# shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
log_info()  { :; }
# shellcheck disable=SC2317
log_debug() { :; }
# shellcheck disable=SC2317
log_error() { :; }
# shellcheck disable=SC2317
log_warn()  { :; }
# shellcheck disable=SC2317
log_success() { :; }

PLUGIN_ENABLED_DIR="${PLUGIN_ENABLED_DIR:-$HOME/.config/version-manager/plugins}"
TXN_DIR_BASE="$HOME/.config-backups/transactions"

# Source fixture and an OUTSIDE zone (inside the sandbox HOME, but outside
# the plugin directory) for canaries and symlink targets.
SANDBOX_WORK="$(mktemp -d "${TMPDIR:-/tmp}/vms-plugin-sec.XXXXXX")"
SRC_GOOD="$SANDBOX_WORK/good_plugin.sh"
SRC_HIDDEN="$SANDBOX_WORK/.hidden.sh"
OUTSIDE_ZONE="$HOME/outside_zone"
mkdir -p "$OUTSIDE_ZONE"

_write_fixture() {
    mkdir -p "$PLUGIN_ENABLED_DIR" "$SANDBOX_WORK" "$OUTSIDE_ZONE"
    cat > "$SRC_GOOD" << 'EOF'
#!/usr/bin/env bash
plugin_info() { echo "good v1"; }
EOF
    cat > "$SRC_HIDDEN" << 'EOF'
#!/usr/bin/env bash
plugin_info() { echo "hidden v1"; }
EOF
    chmod +x "$SRC_GOOD" "$SRC_HIDDEN"
}

_cleanup_state() {
    chmod 755 "$PLUGIN_ENABLED_DIR" 2>/dev/null
    # Wipe ALL plugin/transaction/audit state under the sandbox HOME.
    rm -rf "$HOME/.config/version-manager" "$HOME/.config-backups" "$PLUGIN_ENABLED_DIR"
    rm -f "$HOME/escaped" "$HOME/escaped.sh" "$OUTSIDE_ZONE"/*.sh 2>/dev/null
    mkdir -p "$PLUGIN_ENABLED_DIR"
}

# Files under the sandbox HOME, excluding transaction/audit bookkeeping
# (the transaction primitive writes its own state under .config-backups and
# the audit journal at .config/version-manager/audit.log — those are not
# plugin artifacts).
_home_files() {
    ( cd "$HOME" && find . -type f 2>/dev/null \
        | grep -v -e '^\./\.config-backups/' \
                  -e '^\./\.config/version-manager/audit\.log$' \
        | sort )
}

_rc_ne0() { [[ "$1" -ne 0 ]]; }

# _chk <expected> <actual> <message> — assert + explicit failure accumulation.
# Propagates the assert's status so the caller's `|| failures++` fires.
_CASE_FAILURES=0
_chk() {
    if assert_equals "$1" "$2" "$3"; then
        return 0
    fi
    _CASE_FAILURES=$((_CASE_FAILURES + 1))
    return 1
}

# ── a. GRAMMAR: bad names return nonzero and write NOTHING anywhere ──────────
test_grammar_rejects_bad_names() {
    _CASE_FAILURES=0
    _cleanup_state; _write_fixture
    local before after name rc

    before=$(_home_files)

    for name in "../escaped" "a/b" ".hidden" ".." "." "a b" "/tmp/abs_escape"; do
        plugin_install_from_file "$SRC_GOOD" "$name" >/dev/null 2>&1
        rc=$?
        _rc_ne0 "$rc" \
            && _chk "nonzero" "nonzero" "install rejects grammar-violating name '$name'" \
            || _chk "nonzero" "$rc" "install ACCEPTED grammar-violating name '$name' (rc=$rc)"
    done

    # Derived (basename) names must obey the grammar too
    plugin_install_from_file "$SRC_HIDDEN" >/dev/null 2>&1
    rc=$?
    _rc_ne0 "$rc" \
        && _chk "nonzero" "nonzero" "install rejects hidden basename '.hidden.sh'" \
        || _chk "nonzero" "$rc" "install ACCEPTED hidden basename '.hidden.sh' (rc=$rc)"

    for name in "../escaped" "../../escaped" "a/b" ".hidden" "/tmp/abs_escape"; do
        plugin_remove "$name" >/dev/null 2>&1
        rc=$?
        _rc_ne0 "$rc" \
            && _chk "nonzero" "nonzero" "remove rejects grammar-violating name '$name'" \
            || _chk "nonzero" "$rc" "remove ACCEPTED grammar-violating name '$name' (rc=$rc)"
    done

    plugin_create_template "../tmpl_escape" >/dev/null 2>&1
    rc=$?
    _rc_ne0 "$rc" \
        && _chk "nonzero" "nonzero" "template rejects grammar-violating name" \
        || _chk "nonzero" "$rc" "template ACCEPTED grammar-violating name '../tmpl_escape' (rc=$rc)"

    after=$(_home_files)
    _chk "0" "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >/dev/null 2>&1; echo $?)" \
        "grammar-violating names write NOTHING anywhere under \$HOME"
    return "$_CASE_FAILURES"
}

# ── b. TRAVERSAL REPRO: the audited ../escape must not create/delete canaries ─
# Paths (PLUGIN_ENABLED_DIR = $HOME/.config/version-manager/plugins):
#   install "../escaped"    -> $HOME/.config/version-manager/escaped   (no .sh)
#   install "../../escaped" -> $HOME/.config/escaped
#   remove  "../escaped"    -> $HOME/.config/version-manager/escaped.sh
#   remove  "../../escaped" -> $HOME/.config/escaped.sh
test_traversal_canaries() {
    _CASE_FAILURES=0
    _cleanup_state; _write_fixture
    local rc content

    plugin_install_from_file "$SRC_GOOD" "../escaped" >/dev/null 2>&1
    rc=$?
    _rc_ne0 "$rc" \
        && _chk "nonzero" "nonzero" "install '../escaped' fails closed" \
        || _chk "nonzero" "$rc" "install '../escaped' returned success (rc=$rc)"
    [[ ! -e "$HOME/.config/version-manager/escaped" ]] \
        && _chk "absent" "absent" "install '../escaped' created no file outside the plugin dir" \
        || _chk "absent" "PRESENT" "install '../escaped' ESCAPED the plugin dir"

    plugin_install_from_file "$SRC_GOOD" "../../escaped" >/dev/null 2>&1
    rc=$?
    _rc_ne0 "$rc" \
        && _chk "nonzero" "nonzero" "install '../../escaped' fails closed" \
        || _chk "nonzero" "$rc" "install '../../escaped' returned success (rc=$rc)"
    [[ ! -e "$HOME/.config/escaped" ]] \
        && _chk "absent" "absent" "install '../../escaped' created no file outside the plugin dir" \
        || _chk "absent" "PRESENT" "install '../../escaped' ESCAPED two levels"

    # Remove side: pre-plant canaries exactly where the audited repro deleted.
    printf 'canary-one\n' > "$HOME/.config/version-manager/escaped.sh"
    printf 'canary-two\n' > "$HOME/.config/escaped.sh"
    plugin_remove "../escaped" >/dev/null 2>&1
    rc=$?
    _rc_ne0 "$rc" \
        && _chk "nonzero" "nonzero" "remove '../escaped' fails closed" \
        || _chk "nonzero" "$rc" "remove '../escaped' returned success (rc=$rc)"
    content=$(cat "$HOME/.config/version-manager/escaped.sh" 2>/dev/null)
    _chk "canary-one" "$content" "remove '../escaped' did not delete canary outside plugin dir"
    plugin_remove "../../escaped" >/dev/null 2>&1
    rc=$?
    _rc_ne0 "$rc" \
        && _chk "nonzero" "nonzero" "remove '../../escaped' fails closed" \
        || _chk "nonzero" "$rc" "remove '../../escaped' returned success (rc=$rc)"
    content=$(cat "$HOME/.config/escaped.sh" 2>/dev/null)
    _chk "canary-two" "$content" "remove '../../escaped' did not delete canary outside plugin dir"
    return "$_CASE_FAILURES"
}

# ── c. CONTAINMENT: installer writes nothing outside the plugin dir ──────────
test_containment_of_installer_writes() {
    _CASE_FAILURES=0
    _cleanup_state; _write_fixture
    local before after new_files bad_lines rc

    # 1. A failing (traversal) install must leave the whole HOME untouched.
    before=$(_home_files)
    plugin_install_from_file "$SRC_GOOD" "../escaped" >/dev/null 2>&1
    rc=$?
    _rc_ne0 "$rc" \
        && _chk "nonzero" "nonzero" "traversal install fails closed (containment case)" \
        || _chk "nonzero" "$rc" "traversal install returned success (rc=$rc)"
    after=$(_home_files)
    _chk "0" "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >/dev/null 2>&1; echo $?)" \
        "failed install leaves zero new files anywhere under \$HOME"

    # 2. A succeeding install may only add files inside the plugin directory.
    before=$(_home_files)
    plugin_install_from_file "$SRC_GOOD" "good_plugin.sh" >/dev/null 2>&1
    rc=$?
    _chk "0" "$rc" "happy-path install succeeds (containment setup)"
    after=$(_home_files)
    new_files="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed '/^$/d')"
    bad_lines="$(printf '%s\n' "$new_files" | grep -v '^\./\.config/version-manager/plugins/' | grep -v '^$' || true)"
    _chk "0" "$( [[ -z "$bad_lines" ]] && echo 0 || echo 1 )" \
        "every installer-written file is inside the plugin dir (strays: ${bad_lines:-none})"
    return "$_CASE_FAILURES"
}

# ── d. SYMLINK ESCAPE: links leaving the plugin dir fail closed ──────────────
test_symlink_escape_rejection() {
    _CASE_FAILURES=0
    _cleanup_state; _write_fixture
    local link outside content rc

    outside="$OUTSIDE_ZONE/outside_canary.sh"
    printf 'OUTSIDE-CANARY\n' > "$outside"
    link="$PLUGIN_ENABLED_DIR/evil.sh"
    ln -s "$outside" "$link"

    # Remove through the escaping symlink: must fail closed — outside target
    # survives (per directive, either the link survives or only the link is
    # removed; this implementation refuses outright and keeps the link).
    plugin_remove "evil" >/dev/null 2>&1
    rc=$?
    _rc_ne0 "$rc" \
        && _chk "nonzero" "nonzero" "remove through escaping symlink fails closed" \
        || _chk "nonzero" "$rc" "remove through escaping symlink returned success (rc=$rc)"
    content=$(cat "$outside" 2>/dev/null)
    _chk "OUTSIDE-CANARY" "$content" "outside target survived remove-through-symlink"
    [[ -L "$link" ]] \
        && _chk "intact" "intact" "escaping link itself was not silently consumed" \
        || _chk "intact" "$( [[ -e "$link" ]] && echo regular || echo missing )" \
            "escaping link state after remove"

    # Install OVER the escaping symlink: cp would follow it and overwrite the
    # outside file — must fail closed without touching the target.
    plugin_install_from_file "$SRC_GOOD" "evil.sh" >/dev/null 2>&1
    rc=$?
    _rc_ne0 "$rc" \
        && _chk "nonzero" "nonzero" "install over escaping symlink fails closed" \
        || _chk "nonzero" "$rc" "install over escaping symlink returned success (rc=$rc)"
    content=$(cat "$outside" 2>/dev/null)
    _chk "OUTSIDE-CANARY" "$content" "outside target survived install-over-symlink"
    return "$_CASE_FAILURES"
}

# ── e. TRANSACTION: mid-way failure leaves no half-installed state ───────────
test_transaction_atomicity() {
    _CASE_FAILURES=0
    _cleanup_state; _write_fixture
    local rc txn_meta

    # Root-proof mid-way failure: make the plugin directory read-only so cp
    # fails AFTER the transaction started. (chmod 555 does not stop root, so
    # under root this sub-case is skipped by design.)
    if [[ "$(id -u)" -ne 0 ]]; then
        chmod 555 "$PLUGIN_ENABLED_DIR"
        plugin_install_from_file "$SRC_GOOD" "halfway" >/dev/null 2>&1
        rc=$?
        chmod 755 "$PLUGIN_ENABLED_DIR"
        _rc_ne0 "$rc" \
            && _chk "nonzero" "nonzero" "mid-way install failure returns nonzero" \
            || _chk "nonzero" "$rc" "mid-way install failure reported SUCCESS (rc=$rc)"
        [[ ! -e "$PLUGIN_ENABLED_DIR/halfway" ]] \
            && _chk "absent" "absent" "no half-installed plugin file after failure" \
            || _chk "absent" "PRESENT" "half-installed plugin file left behind"
        txn_meta="$(ls -dt "$TXN_DIR_BASE"/plugin_install_halfway.*/metadata.json 2>/dev/null | head -1)"
        if [[ -n "$txn_meta" ]]; then
            grep -q 'rolled_back' "$txn_meta" \
                && _chk "rolled_back" "rolled_back" "transaction rollback invoked on mid-way failure" \
                || _chk "rolled_back" "$(grep -o '"status": "[^"]*"' "$txn_meta" | head -1)" \
                    "transaction did NOT roll back on mid-way failure"
        else
            _chk "transaction-dir" "missing" "install was not transactional (no transaction dir)"
        fi
    else
        _chk "skipped-root" "skipped-root" "mid-way failure case skipped under root (chmod 555 ineffective)"
    fi

    # Root-proof fallback: nonexistent source fails before any state change.
    plugin_install_from_file "$SANDBOX_WORK/does_not_exist.sh" "ghost" >/dev/null 2>&1
    rc=$?
    _rc_ne0 "$rc" \
        && _chk "nonzero" "nonzero" "nonexistent-source install returns nonzero" \
        || _chk "nonzero" "$rc" "nonexistent-source install returned success (rc=$rc)"
    [[ ! -e "$PLUGIN_ENABLED_DIR/ghost" ]] \
        && _chk "absent" "absent" "nonexistent-source install leaves no target state" \
        || _chk "absent" "PRESENT" "nonexistent-source install left target state"
    return "$_CASE_FAILURES"
}

# ── f. REGRESSION: happy path still works ─────────────────────────────────────
test_happy_path_regression() {
    _CASE_FAILURES=0
    _cleanup_state; _write_fixture
    local rc

    # is_plugin_installed() probes for '<name>.sh' in the plugin dirs, so the
    # happy path installs under a grammar-valid '.sh'-suffixed name.
    plugin_install_from_file "$SRC_GOOD" "good_plugin.sh" >/dev/null 2>&1
    rc=$?
    _chk "0" "$rc" "happy-path install succeeds"
    [[ -f "$PLUGIN_ENABLED_DIR/good_plugin.sh" ]] \
        && _chk "present" "present" "installed plugin file in place" \
        || _chk "present" "missing" "installed plugin file missing"
    is_plugin_installed "good_plugin" >/dev/null 2>&1
    rc=$?
    _chk "0" "$rc" "is_plugin_installed sees installed plugin"

    # Default target name (basename of the source, extension kept)
    plugin_install_from_file "$SRC_GOOD" >/dev/null 2>&1
    rc=$?
    _chk "0" "$rc" "install with derived name succeeds"
    [[ -f "$PLUGIN_ENABLED_DIR/good_plugin.sh" ]] \
        && _chk "present" "present" "derived-name install in place" \
        || _chk "present" "missing" "derived-name install missing"

    plugin_remove "good_plugin" >/dev/null 2>&1
    rc=$?
    _chk "0" "$rc" "happy-path remove succeeds"
    [[ ! -e "$PLUGIN_ENABLED_DIR/good_plugin.sh" ]] \
        && _chk "gone" "gone" "removed plugin file gone" \
        || _chk "gone" "PRESENT" "removed plugin file still present"

    plugin_create_template "tmpl_ok" >/dev/null 2>&1
    rc=$?
    _chk "0" "$rc" "template creation succeeds"
    [[ -f "$PLUGIN_ENABLED_DIR/tmpl_ok.sh" && -x "$PLUGIN_ENABLED_DIR/tmpl_ok.sh" ]] \
        && _chk "present+exec" "present+exec" "template file created and executable" \
        || _chk "present+exec" "$( [[ -f "$PLUGIN_ENABLED_DIR/tmpl_ok.sh" ]] && echo present || echo missing )" \
            "template file state"
    grep -q "tmpl_ok_info" "$PLUGIN_ENABLED_DIR/tmpl_ok.sh" 2>/dev/null \
        && _chk "templated" "templated" "template name substitution applied" \
        || _chk "templated" "unsubstituted" "template name substitution missing"
    return "$_CASE_FAILURES"
}

track_coverage "plugin_install_from_file"
track_coverage "plugin_remove"
track_coverage "plugin_create_template"
track_coverage "is_plugin_installed"
coverage_expect 4

# ── Run — explicit failure accumulation ──────────────────────────────────────
failures=0
test_grammar_rejects_bad_names    || failures=$((failures + 1))
test_traversal_canaries           || failures=$((failures + 1))
test_containment_of_installer_writes || failures=$((failures + 1))
test_symlink_escape_rejection     || failures=$((failures + 1))
test_transaction_atomicity        || failures=$((failures + 1))
test_happy_path_regression        || failures=$((failures + 1))

teardown_test
rm -rf "$SANDBOX_WORK"

generate_coverage_report

if [[ "$failures" -gt 0 ]]; then
    echo "test_plugin_security.sh: $failures case(s) failed"
    exit 1
fi
exit 0
