#!/usr/bin/env bash
# Unit tests for lib/error-handling.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/../helpers.sh"

coverage_init "error_handling"

# ── Tests ─────────────────────────────────────────────────────────────────────
failures=0

# Verify safe_exec rejects empty commands
test_safe_exec_empty_command() {
    track_coverage "safe_exec"
    # Source the module (skip sourcing logger for speed; provide stubs)
    log_error() { :; }
    log_warn()  { :; }
    log_debug() { :; }
    MAX_RETRIES=3
    RETRY_DELAY=0
    # shellcheck source=lib/error-handling.sh
    source "$ROOT_DIR/lib/error-handling.sh" 2>/dev/null || true

    if safe_exec "" 2>/dev/null; then
        assert_equals "1" "0" "safe_exec should fail on empty command"
        failures=$((failures + 1))
    else
        assert_equals "1" "1" "safe_exec rejects empty command"
    fi
}

# Verify safe_exec retries on failure
test_safe_exec_retries() {
    track_coverage "safe_exec"
    local call_count=0
    _failing_cmd() { call_count=$((call_count + 1)); return 1; }
    export -f _failing_cmd

    log_error() { :; }
    log_warn()  { :; }
    log_debug() { :; }
    MAX_RETRIES=2
    RETRY_DELAY=0

    source "$ROOT_DIR/lib/error-handling.sh" 2>/dev/null || true
    safe_exec "_failing_cmd" 2 0 || true

    if [[ "$call_count" -ge 2 ]]; then
        assert_equals "2" "$call_count" "safe_exec retried correct number of times"
    else
        assert_equals "2" "$call_count" "safe_exec did not retry enough times"
        failures=$((failures + 1))
    fi
}

# Verify safe_exec_backoff rejects empty commands
test_safe_exec_backoff_empty() {
    track_coverage "safe_exec_backoff"
    log_error() { :; }
    log_warn()  { :; }
    log_debug() { :; }

    source "$ROOT_DIR/lib/error-handling.sh" 2>/dev/null || true

    if safe_exec_backoff "" 2>/dev/null; then
        assert_equals "1" "0" "safe_exec_backoff should fail on empty command"
        failures=$((failures + 1))
    else
        assert_equals "1" "1" "safe_exec_backoff rejects empty command"
    fi
}

coverage_expect 3
test_safe_exec_empty_command
test_safe_exec_retries
test_safe_exec_backoff_empty

generate_coverage_report

exit "$failures"
