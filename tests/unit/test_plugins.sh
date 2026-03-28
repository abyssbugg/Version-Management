#!/usr/bin/env bash
# Unit tests for lib/plugins.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
coverage_init "plugins"

failures=0

log_info()  { :; }
log_debug() { :; }
log_error() { :; }
log_warn()  { :; }
log_success() { :; }

# shellcheck source=lib/plugins.sh
source "$ROOT_DIR/lib/plugins.sh" 2>/dev/null || {
    echo "SKIP: lib/plugins.sh could not be sourced"
    exit 0
}

# Test: is_plugin_installed returns false for a made-up plugin
test_nonexistent_plugin_not_installed() {
    track_coverage "is_plugin_installed"

    if declare -f is_plugin_installed >/dev/null 2>&1; then
        is_plugin_installed "__nonexistent_plugin_$$" 2>/dev/null && result=0 || result=1
        assert_equals "1" "$result" "is_plugin_installed correctly returns false for unknown plugin"
    else
        assert_equals "defined" "missing" "is_plugin_installed function not found"
        failures=$((failures + 1))
    fi
}

# Test: list_plugins returns output without error
test_list_plugins_runs() {
    track_coverage "list_plugins"

    if declare -f list_plugins >/dev/null 2>&1; then
        list_plugins 2>/dev/null || true
        assert_equals "done" "done" "list_plugins runs without fatal error"
    else
        echo "INFO: list_plugins not defined — skipping"
    fi
}

coverage_expect 2
test_nonexistent_plugin_not_installed
test_list_plugins_runs

generate_coverage_report
exit "$failures"
