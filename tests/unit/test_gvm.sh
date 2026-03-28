#!/usr/bin/env bash
# Unit tests for lib/gvm.sh - Go Version Manager

source ../helpers.sh
source ../../lib/gvm.sh

# Test gvm_detect function exists and is callable
test_gvm_detect_function_exists() {
    if declare -f gvm_detect >/dev/null 2>&1; then
        assert_equals "true" "true" "gvm_detect function exists"
    else
        assert_equals "function_exists" "function_missing" "gvm_detect function should exist"
    fi
}

# Test gvm_detect returns appropriate value
test_gvm_detect_returns_value() {
    # This test checks that gvm_detect runs without error
    # It may return 0 (goenv found) or 1 (not found)
    gvm_detect >/dev/null 2>&1
    local exit_code=$?
    if [[ $exit_code -eq 0 ]] || [[ $exit_code -eq 1 ]]; then
        assert_equals "true" "true" "gvm_detect returns valid exit code ($exit_code)"
    else
        assert_equals "0_or_1" "$exit_code" "gvm_detect should return 0 or 1"
    fi
}

# Test _gvm_validate_version with valid version format
test_gvm_validate_version_format_valid() {
    # Test valid version formats
    if _gvm_validate_version "1.21.5" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 1.21.5 accepted"
    else
        assert_equals "valid" "invalid" "1.21.5 should be valid format"
    fi
    
    if _gvm_validate_version "1.23.4" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 1.23.4 accepted"
    else
        assert_equals "valid" "invalid" "1.23.4 should be valid format"
    fi
}

# Test _gvm_validate_version with invalid version format
test_gvm_validate_version_format_invalid() {
    # Test invalid version formats
    if ! _gvm_validate_version "invalid" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version 'invalid' rejected"
    else
        assert_equals "rejected" "accepted" "'invalid' should be rejected"
    fi
    
    if ! _gvm_validate_version "1.21" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version '1.21' (no patch) rejected"
    else
        assert_equals "rejected" "accepted" "'1.21' should be rejected"
    fi
    
    if ! _gvm_validate_version "go1.21.5" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version 'go1.21.5' (with prefix) rejected"
    else
        assert_equals "rejected" "accepted" "'go1.21.5' should be rejected"
    fi
}

# Test gvm_is_go_project detection
test_gvm_is_go_project_with_go_mod() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    
    # Create go.mod file
    echo "module test" > go.mod
    
    if gvm_is_go_project; then
        assert_equals "true" "true" "Detected Go project with go.mod"
    else
        assert_equals "detected" "not_detected" "Should detect go.mod as Go project"
    fi
    
    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test gvm_is_go_project with .go-version file
test_gvm_is_go_project_with_go_version() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    
    # Create .go-version file
    echo "1.23.4" > .go-version
    
    if gvm_is_go_project; then
        assert_equals "true" "true" "Detected Go project with .go-version"
    else
        assert_equals "detected" "not_detected" "Should detect .go-version as Go project"
    fi
    
    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test gvm_is_go_project with no Go files
test_gvm_is_go_project_not_go() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    
    # Create a non-Go file
    echo "test" > test.txt
    
    if ! gvm_is_go_project; then
        assert_equals "true" "true" "Correctly identified non-Go project"
    else
        assert_equals "not_detected" "detected" "Should not detect as Go project"
    fi
    
    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test gvm_get_current function exists
test_gvm_get_current_function_exists() {
    if declare -f gvm_get_current >/dev/null 2>&1; then
        assert_equals "true" "true" "gvm_get_current function exists"
    else
        assert_equals "function_exists" "function_missing" "gvm_get_current function should exist"
    fi
}

# Test all exported functions exist
test_all_exported_functions_exist() {
    local functions=("gvm_detect" "gvm_install" "gvm_list_versions" "gvm_install_version"
                     "gvm_set_global" "gvm_set_local" "gvm_get_current" "gvm_validate_version"
                     "gvm_get_prompt_version" "gvm_is_go_project")
    local missing=0
    
    for func in "${functions[@]}"; do
        if ! declare -f "$func" >/dev/null 2>&1; then
            echo "Missing function: $func"
            ((missing++))
        fi
    done
    
    if [[ $missing -eq 0 ]]; then
        assert_equals "true" "true" "All 10 exported functions exist"
    else
        assert_equals "0" "$missing" "$missing functions are missing"
    fi
}

# Run tests
echo "=== Go Version Manager (gvm) Tests ==="
test_gvm_detect_function_exists
test_gvm_detect_returns_value
test_gvm_validate_version_format_valid
test_gvm_validate_version_format_invalid
test_gvm_is_go_project_with_go_mod
test_gvm_is_go_project_with_go_version
test_gvm_is_go_project_not_go
test_gvm_get_current_function_exists
test_all_exported_functions_exist

exit $?
