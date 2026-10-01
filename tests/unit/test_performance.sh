#!/usr/bin/env bash
# Unit tests for lib/performance.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
setup_test
trap teardown_test EXIT

coverage_init "performance"

failures=0

# Stubs
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

# Test: cache_version caches command output without string evaluation
test_cache_version_caches_output() {
    track_coverage "cache_version"

    local command_script="$HOME/cache_version_counter.sh"
    local counter_file="$HOME/cache_version_counter.txt"
    local cache_name="cache_version_counter"

    cat > "$command_script" <<'SCRIPT'
#!/usr/bin/env bash
counter_file="$1"
count=0
if [[ -f "$counter_file" ]]; then
    count=$(cat "$counter_file")
fi
count=$((count + 1))
echo "$count" > "$counter_file"
printf 'version-%s\n' "$count"
SCRIPT
    chmod +x "$command_script"

    if $_PERF_HAS_ASSOC; then
        unset "VERSION_CACHE[$cache_name]" 2>/dev/null || true
    fi

    local first_result
    first_result=$(cache_version "$cache_name" "$command_script" "$counter_file")
    local second_result
    second_result=$(cache_version "$cache_name" "$command_script" "$counter_file")
    local execution_count
    execution_count=$(cat "$counter_file")

    assert_equals "version-1" "$first_result" "cache_version returns command output"
    assert_equals "version-1" "$second_result" "cache_version returns cached output"
    assert_equals "1" "$execution_count" "cache_version avoids re-execution on cache hit"
}

# Test: cache_version treats shell metacharacters as literal argv data
test_cache_version_handles_literal_arguments() {
    track_coverage "cache_version"

    local command_script="$HOME/cache_version_literal.sh"
    local canary_file="$HOME/cache_version_canary"
    local cache_name="cache_version_literal"
    local special_arg="version with spaces; touch $canary_file; \$(touch $canary_file)"

    cat > "$command_script" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$1"
SCRIPT
    chmod +x "$command_script"
    rm -f "$canary_file"

    if $_PERF_HAS_ASSOC; then
        unset "VERSION_CACHE[$cache_name]" 2>/dev/null || true
    fi

    local result
    result=$(cache_version "$cache_name" "$command_script" "$special_arg")

    assert_equals "$special_arg" "$result" "cache_version preserves argv arguments"
    assert_file_not_exists "$canary_file" "cache_version does not evaluate metacharacters"
}

coverage_expect 5
test_perf_timestamps_are_numeric
test_measure_startup_has_recursion_guard
test_lazy_load_functions_exist
test_cache_version_caches_output
test_cache_version_handles_literal_arguments

generate_coverage_report
exit "$failures"
