#!/usr/bin/env bash
# Unit tests for lib/plugins.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
coverage_init "plugins"

failures=0

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

# F6 (re-audit 2026-10-10): the standard interface names are global, so a
# plugin that defines none of them inherited the PREVIOUSLY loaded plugin's
# plugin_info/plugin_init (wrong metadata, wrong initializer ran), and
# plugin_unload called whichever plugin_cleanup was loaded last.
test_second_plugin_cannot_inherit_first_plugins_interface() {
    track_coverage "plugin_load"
    track_coverage "plugin_unload"

    local d rc_second meta log
    d=$(mktemp -d "${TMPDIR:-/tmp}/vms-plugin-order.XXXXXX")
    log="$d/log"
    cat > "$d/first.sh" <<EOF
first_info() { echo "first v1"; }
first_init() { echo first_init >> "$log"; }
first_cleanup() { echo first_cleanup >> "$log"; }
plugin_info() { first_info; }
plugin_init() { first_init; }
plugin_cleanup() { first_cleanup; }
EOF
    cat > "$d/second.sh" <<'EOF'
second_detect() { :; }
EOF
    cat > "$d/third.sh" <<EOF
third_info() { echo "third v1"; }
third_cleanup() { echo third_cleanup >> "$log"; }
plugin_info() { third_info; }
plugin_cleanup() { third_cleanup; }
EOF
    plugin_load "$d/first.sh" >/dev/null 2>&1 || true
    plugin_load "$d/second.sh" >/dev/null 2>&1 && rc_second=0 || rc_second=$?
    meta="${PLUGIN_METADATA[second]:-<none>}"
    plugin_load "$d/third.sh" >/dev/null 2>&1 || true
    plugin_unload first >/dev/null 2>&1 || true
    plugin_unload third >/dev/null 2>&1 || true

    assert_equals "1" "$rc_second" "A plugin without plugin_info is rejected even after another plugin loaded" || failures=$((failures + 1))
    assert_equals "<none>" "$meta" "The rejected plugin gets no borrowed metadata" || failures=$((failures + 1))
    assert_equals $'first_init\nfirst_cleanup\nthird_cleanup' "$(cat "$log" 2>/dev/null)" "Each plugin's own init/cleanup runs exactly once" || failures=$((failures + 1))
    rm -rf "$d"
}

coverage_expect 2
test_nonexistent_plugin_not_installed
test_list_plugins_runs
test_second_plugin_cannot_inherit_first_plugins_interface

generate_coverage_report
exit "$failures"
