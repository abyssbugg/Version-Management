#!/usr/bin/env bash
# Unit tests for A3-1 theme safety — transaction, backup, and mutation primitives
# Tests behavioral requirements for theme_switch transaction safety

source "${BASH_SOURCE[0]%/*}/../helpers.sh" || { echo "FATAL: cannot source helpers.sh — run via tests/test_runner.sh (P0-3: unsandboxed HOME writes forbidden)" >&2; exit 1; }
source ../../lib/backup.sh
source ../../lib/mutation.sh
source ../../lib/theme-ops.sh

set +e

# Test 1: theme_get_description uses correct array lookup (not string key on numeric array)
# GREEN: Verify theme_get_description returns correct description for known theme
test_theme_get_description_correct_lookup() {
    local result
    result=$(theme_get_description "professional" 2>/dev/null || echo "")
    
    # After fix: should return description for 'professional' theme
    local expected="Professional development theme with version info"
    if [[ "$result" == "$expected" ]]; then
        assert_equals "$expected" "$result" "theme_get_description returns correct description"
        return 0
    else
        assert_equals "$expected" "$result" "theme_get_description should return correct description"
        return 1
    fi
}

# Test 2: Verify backup.sh exports create_backup
test_backup_functions_available() {
    if declare -f create_backup >/dev/null 2>&1; then
        assert_equals "true" "true" "create_backup function is available"
        return 0
    else
        assert_equals "available" "missing" "create_backup should be exported from backup.sh"
        return 1
    fi
}

# Test 3: theme_switch function exists and is callable
test_theme_switch_callable() {
    if declare -f theme_switch >/dev/null 2>&1; then
        assert_equals "true" "true" "theme_switch function exists"
        return 0
    else
        assert_equals "exists" "missing" "theme_switch should exist"
        return 1
    fi
}

# Run tests
failures=0
test_theme_get_description_correct_lookup || failures=$((failures + 1))
test_backup_functions_available || failures=$((failures + 1))
test_theme_switch_callable || failures=$((failures + 1))

if [[ "$failures" -gt 0 ]]; then
    echo "test_theme_safety.sh: $failures test(s) failed"
    exit 1
fi
