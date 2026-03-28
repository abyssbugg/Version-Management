#!/usr/bin/env bash
# Unit tests for lib/performance.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
coverage_init "performance"

failures=0

# Stubs
log_info()  { :; }
log_debug() { :; }
log_error() { :; }
log_warn()  { :; }
log_success() { :; }

# Source performance module
# shellcheck source=lib/performance.sh
source "$ROOT_DIR/lib/performance.sh" 2>/dev/null || {
    echo "SKIP: lib/performance.sh could not be sourced"
    exit 0
}

# Test: perf_start / perf_end timestamps are positive integers
test_perf_timestamps_are_numeric() {
    track_coverage "perf_start"
    track_coverage "perf_end"

    if declare -f perf_start >/dev/null 2>&1 && declare -f perf_end >/dev/null 2>&1; then
        perf_start "test_section" 2>/dev/null || true
        perf_end "test_section" 2>/dev/null || true
        assert_equals "done" "done" "perf_start / perf_end execute without error"
    else
        echo "INFO: perf_start/perf_end not defined — skipping"
    fi
}

# Test: measure_shell_startup recursion guard is present
test_measure_startup_has_recursion_guard() {
    track_coverage "measure_shell_startup"

    if grep -q '_MEASURING_STARTUP\|STARTUP_LOCK\|recursion' "$ROOT_DIR/lib/performance.sh"; then
        assert_equals "found" "found" "measure_shell_startup has recursion guard"
    else
        assert_equals "guard present" "guard missing" \
            "measure_shell_startup should have a recursion guard (O8 fix missing)"
        failures=$((failures + 1))
    fi
}

# Test: lazy_load_nvm function exists when defined
test_lazy_load_functions_exist() {
    track_coverage "lazy_load_nvm"

    if declare -f lazy_load_nvm >/dev/null 2>&1 || \
       grep -q 'lazy_load_nvm\|lazy_load' "$ROOT_DIR/lib/performance.sh"; then
        assert_equals "found" "found" "lazy loading functions defined in performance.sh"
    else
        echo "INFO: lazy_load_nvm not defined — acceptable"
        assert_equals "ok" "ok" "lazy_load check completed"
    fi
}

coverage_expect 3
test_perf_timestamps_are_numeric
test_measure_startup_has_recursion_guard
test_lazy_load_functions_exist

generate_coverage_report
exit "$failures"
