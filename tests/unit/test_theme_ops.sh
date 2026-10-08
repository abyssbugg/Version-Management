#!/usr/bin/env bash
# Unit tests for lib/theme-ops.sh - Theme Operations

source "${BASH_SOURCE[0]%/*}/../helpers.sh" || { echo "FATAL: cannot source helpers.sh — run via tests/test_runner.sh (P0-3: unsandboxed HOME writes forbidden)" >&2; exit 1; }
source ../../lib/theme-ops.sh

# Own strict-mode posture (M0 step 3): sourced libraries may enable global
# strict mode (A2 — lib/logger.sh via theme-ops), which would abort this file
# on the first returned assertion instead of accumulating failures. M1 removes
# the leak; after that this line is a no-op.
set +e

# Test theme_validate function exists
test_theme_validate_function_exists() {
    if declare -f theme_validate >/dev/null 2>&1; then
        assert_equals "true" "true" "theme_validate function exists"
    else
        assert_equals "function_exists" "function_missing" "theme_validate function should exist"
    fi
}

# Test theme_validate with empty theme name
test_theme_validate_empty_name() {
    if ! theme_validate "" 2>/dev/null; then
        assert_equals "true" "true" "theme_validate rejects empty theme name"
    else
        assert_equals "rejected" "accepted" "Empty theme name should be rejected"
    fi
}

# Test theme_validate with known theme
test_theme_validate_professional_theme() {
    # Test that 'professional' theme can be validated (may or may not exist)
    theme_validate "professional" >/dev/null 2>&1 && local result=0 || local result=$?
    # Result should be 0 (found) or 1 (not found), but shouldn't error
    if [[ $result -eq 0 ]] || [[ $result -eq 1 ]]; then
        assert_equals "true" "true" "theme_validate handles 'professional' theme"
    else
        assert_equals "0_or_1" "$result" "theme_validate should return 0 or 1"
    fi
}

# Test theme_detect_current function exists
test_theme_detect_current_function_exists() {
    if declare -f theme_detect_current >/dev/null 2>&1; then
        assert_equals "true" "true" "theme_detect_current function exists"
    else
        assert_equals "function_exists" "function_missing" "theme_detect_current function should exist"
    fi
}

# Test theme_detect_current returns a value
test_theme_detect_current_returns_value() {
    local result
    result=$(theme_detect_current 2>/dev/null || true)
    # The logger currently writes timestamped WARN diagnostics to stdout
    # (B2.4, contract fix lands in M1), which contaminates command
    # substitution. Filter those lines here; after M1 the filter is a no-op.
    result="$(printf '%s\n' "$result" | grep -v '^\[[0-9][0-9][0-9][0-9]-' || true)"
    # Should return one of: professional, apple, clean, vscode, unknown, none
    case "$result" in
        professional|apple|clean|vscode|unknown|none)
            assert_equals "true" "true" "theme_detect_current returns valid value: $result"
            ;;
        *)
            # If empty, the function might have failed but didn't error fatally
            if [[ -z "$result" ]]; then
                assert_equals "true" "true" "theme_detect_current returned empty (no config)"
            else
                assert_equals "known_value" "$result" "theme_detect_current returned unexpected value"
            fi
            ;;
    esac
}

# Test theme_switch function exists
test_theme_switch_function_exists() {
    if declare -f theme_switch >/dev/null 2>&1; then
        assert_equals "true" "true" "theme_switch function exists"
    else
        assert_equals "function_exists" "function_missing" "theme_switch function should exist"
    fi
}

# Test theme_switch rejects empty theme name
test_theme_switch_empty_name() {
    if ! theme_switch "" 2>/dev/null; then
        assert_equals "true" "true" "theme_switch rejects empty theme name"
    else
        assert_equals "rejected" "accepted" "Empty theme name should be rejected"
    fi
}

# Test theme_list_available function exists
test_theme_list_available_function_exists() {
    if declare -f theme_list_available >/dev/null 2>&1; then
        assert_equals "true" "true" "theme_list_available function exists"
    else
        assert_equals "function_exists" "function_missing" "theme_list_available function should exist"
    fi
}

# Test theme_list_available produces output
test_theme_list_available_produces_output() {
    local output=$(theme_list_available 2>/dev/null || true)
    if [[ -n "$output" ]]; then
        assert_contains "Available Themes" "$output" "theme_list_available shows header"
    else
        assert_equals "has_output" "no_output" "theme_list_available should produce output"
    fi
}

# Test theme_get_description function exists
test_theme_get_description_function_exists() {
    if declare -f theme_get_description >/dev/null 2>&1; then
        assert_equals "true" "true" "theme_get_description function exists"
    else
        assert_equals "function_exists" "function_missing" "theme_get_description function should exist"
    fi
}

# Test theme_requires_nerd_font function exists
test_theme_requires_nerd_font_function_exists() {
    if declare -f theme_requires_nerd_font >/dev/null 2>&1; then
        assert_equals "true" "true" "theme_requires_nerd_font function exists"
    else
        assert_equals "function_exists" "function_missing" "theme_requires_nerd_font function should exist"
    fi
}

# Test theme_get_current_info function exists
test_theme_get_current_info_function_exists() {
    if declare -f theme_get_current_info >/dev/null 2>&1; then
        assert_equals "true" "true" "theme_get_current_info function exists"
    else
        assert_equals "function_exists" "function_missing" "theme_get_current_info function should exist"
    fi
}

# Test theme_reset function exists
test_theme_reset_function_exists() {
    if declare -f theme_reset >/dev/null 2>&1; then
        assert_equals "true" "true" "theme_reset function exists"
    else
        assert_equals "function_exists" "function_missing" "theme_reset function should exist"
    fi
}

# Test all exported/public functions exist
test_all_public_functions_exist() {
    local functions=("theme_validate" "theme_detect_current" "theme_switch" "theme_preview"
                     "theme_list_available" "theme_get_file_path" "theme_get_description"
                     "theme_requires_nerd_font" "theme_get_current_info" "theme_reset")
    local missing=0

    for func in "${functions[@]}"; do
        if ! declare -f "$func" >/dev/null 2>&1; then
            echo "Missing function: $func"
            missing=$((missing + 1))
        fi
    done

    if [[ $missing -eq 0 ]]; then
        assert_equals "true" "true" "All 10 public functions exist"
    else
        assert_equals "0" "$missing" "$missing functions are missing"
    fi
}

# Run tests — explicit failure accumulation (A5: no last-command-status exits,
# no reliance on inherited strict-mode aborts to propagate failures)
failures=0
test_theme_validate_function_exists || failures=$((failures + 1))
test_theme_validate_empty_name || failures=$((failures + 1))
test_theme_validate_professional_theme || failures=$((failures + 1))
test_theme_detect_current_function_exists || failures=$((failures + 1))
test_theme_detect_current_returns_value || failures=$((failures + 1))
test_theme_switch_function_exists || failures=$((failures + 1))
test_theme_switch_empty_name || failures=$((failures + 1))
test_theme_list_available_function_exists || failures=$((failures + 1))
test_theme_list_available_produces_output || failures=$((failures + 1))
test_theme_get_description_function_exists || failures=$((failures + 1))
test_theme_requires_nerd_font_function_exists || failures=$((failures + 1))
test_theme_get_current_info_function_exists || failures=$((failures + 1))
test_theme_reset_function_exists || failures=$((failures + 1))
test_all_public_functions_exist || failures=$((failures + 1))

if [[ "$failures" -gt 0 ]]; then
    echo "test_theme_ops.sh: $failures test(s) failed"
    exit 1
fi
