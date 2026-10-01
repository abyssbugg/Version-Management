#!/usr/bin/env bash
# Unit tests for lib/fnm.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
coverage_init "fnm"

failures=0

# Test: fnm_detect returns false when fnm is not in PATH
test_fnm_not_installed() {
    track_coverage "fnm_detect"

    # Provide logger stubs
    # shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/fnm.sh
    log_info()  { :; }
    # shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/fnm.sh
    log_debug() { :; }
    # shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/fnm.sh
    log_error() { :; }
    # shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/fnm.sh
    log_warn()  { :; }

    # Save original PATH and remove any fnm
    local saved_path="$PATH"
    export PATH="/usr/bin:/bin"

    # Source with guards reset
    unset _FNM_SH_LOADED 2>/dev/null || true
    # shellcheck source=lib/fnm.sh
    source "$ROOT_DIR/lib/fnm.sh" 2>/dev/null || true

    if declare -f fnm_detect >/dev/null 2>&1; then
        fnm_detect && result=0 || result=1
        assert_equals "1" "$result" "fnm_detect returns false when fnm not in PATH"
    else
        assert_equals "defined" "missing" "fnm_detect function is not defined"
        failures=$((failures + 1))
    fi

    # Restore
    export PATH="$saved_path"
}

# Test: fnm module exports expected functions
test_fnm_exports_functions() {
    track_coverage "fnm_functions"

    # shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/fnm.sh
    log_info()  { :; }
    # shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/fnm.sh
    log_debug() { :; }
    # shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/fnm.sh
    log_error() { :; }
    # shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/fnm.sh
    log_warn()  { :; }

    unset _FNM_SH_LOADED 2>/dev/null || true
    source "$ROOT_DIR/lib/fnm.sh" 2>/dev/null || true

    local missing=0
    for fn in fnm_detect fnm_install fnm_list_versions fnm_install_version \
              fnm_set_global fnm_set_local fnm_get_current fnm_validate_version; do
        if ! declare -f "$fn" >/dev/null 2>&1; then
            echo "MISSING function: $fn"
            missing=$((missing + 1))
        fi
    done

    assert_equals "0" "$missing" "All fnm public functions should be defined"
}

coverage_expect 2
test_fnm_not_installed
test_fnm_exports_functions

generate_coverage_report
exit "$failures"
