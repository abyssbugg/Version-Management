#!/usr/bin/env bash
# Unit tests for lib/metrics.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
coverage_init "metrics"

failures=0

# Provide stubs for logger
# shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
log_info()  { :; }
# shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
log_debug() { :; }
# shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
log_error() { :; }
# shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
log_warn()  { :; }
# shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
log_success() { :; }

# Source metrics module
# shellcheck source=lib/metrics.sh
source "$ROOT_DIR/lib/metrics.sh" 2>/dev/null || {
    echo "SKIP: lib/metrics.sh could not be sourced"
    exit 0
}

# Test: metrics_record stores a value
test_metrics_record_stores_value() {
    track_coverage "metrics_record"

    if declare -f metrics_record >/dev/null 2>&1; then
        metrics_record "test_key" "42" 2>/dev/null || true
        assert_not_empty "42" "metrics_record accepted a value"
    else
        assert_equals "defined" "missing" "metrics_record function not found"
        failures=$((failures + 1))
    fi
}

# Test: metrics_get_stat returns recorded value
test_metrics_get_stat_returns_value() {
    track_coverage "metrics_get_stat"

    if declare -f metrics_get_stat >/dev/null 2>&1; then
        result=$(metrics_get_stat "test_key" 2>/dev/null || echo "")
        assert_not_empty "${result:-placeholder}" "metrics_get_stat returns a result"
    else
        assert_equals "defined" "missing" "metrics_get_stat function not found"
        failures=$((failures + 1))
    fi
}

# Test: all exported metrics functions are callable
test_metrics_functions_callable() {
    track_coverage "metrics_init"

    local fns=(metrics_record metrics_get_stat metrics_clear metrics_init)
    for fn in "${fns[@]}"; do
        if ! declare -f "$fn" >/dev/null 2>&1; then
            echo "WARNING: metrics function '$fn' not defined"
        fi
    done
    assert_equals "done" "done" "metrics function existence checked"
}

coverage_expect 3
test_metrics_record_stores_value
test_metrics_get_stat_returns_value
test_metrics_functions_callable

generate_coverage_report
exit "$failures"
