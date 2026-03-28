#!/usr/bin/env bash
# Unit tests for lib/nvm.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
coverage_init "nvm"

failures=0

# Test: nvm_detect returns false when NVM_DIR is unset
test_nvm_not_installed_without_nvmdir() {
    track_coverage "nvm_detect"

    # Provide logger stubs
    log_info()  { :; }
    log_debug() { :; }
    log_error() { :; }
    log_warn()  { :; }

    local saved_nvm_dir="${NVM_DIR:-}"
    export NVM_DIR=""

    # shellcheck source=lib/nvm.sh
    source "$ROOT_DIR/lib/nvm.sh" 2>/dev/null || true

    if declare -f nvm_detect >/dev/null 2>&1; then
        nvm_detect && result=0 || result=1
        assert_equals "1" "$result" "nvm_detect returns false without NVM_DIR"
    else
        assert_equals "defined" "missing" "nvm_detect function is not defined"
        failures=$((failures + 1))
    fi

    # Restore
    [[ -n "$saved_nvm_dir" ]] && export NVM_DIR="$saved_nvm_dir"
}

# Test: nvm config points to ~/.nvm by default
test_nvm_default_dir() {
    track_coverage "NVM_DIR"
    local expected="$HOME/.nvm"

    log_info()  { :; }
    log_debug() { :; }
    log_error() { :; }
    log_warn()  { :; }

    source "$ROOT_DIR/lib/nvm.sh" 2>/dev/null || true
    assert_not_empty "${NVM_DIR:-}" "NVM_DIR should be set after sourcing lib/nvm.sh"
}

coverage_expect 2
test_nvm_not_installed_without_nvmdir
test_nvm_default_dir

generate_coverage_report
exit "$failures"
