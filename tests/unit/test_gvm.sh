#!/usr/bin/env bash
# Unit tests for lib/gvm.sh - Go Version Manager

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
source "$ROOT_DIR/lib/gvm.sh"

# Own strict-mode posture (remediation directive M0 step 3): lib/env.sh and
# lib/logger.sh set `set -euo pipefail` at source time and that posture leaks
# into this test shell. These tests branch on return codes themselves and must
# not abort on the first non-zero (e.g. gvm_detect returning 1 when goenv is
# absent), so the own posture is deliberately non-aborting:
set +e +u +o pipefail

failures=0

# Test gvm_detect function exists and is callable
test_gvm_detect_function_exists() {
    if declare -f gvm_detect >/dev/null 2>&1; then
        assert_equals "true" "true" "gvm_detect function exists" || failures=$((failures + 1))
    else
        assert_equals "function_exists" "function_missing" "gvm_detect function should exist" || failures=$((failures + 1))
    fi
}

# Test gvm_detect returns the correct value for the actual environment
test_gvm_detect_returns_value() {
    # M0 step 3 (environment-independent semantics): goenv presence is a
    # property of the host, so branch on it and assert the correct outcome for
    # each world instead of relying on the macOS host having goenv installed.
    if command -v goenv >/dev/null 2>&1; then
        gvm_detect >/dev/null 2>&1
        assert_exit_code 0 "$?" "goenv present: gvm_detect returns 0" || failures=$((failures + 1))
    else
        gvm_detect >/dev/null 2>&1
        assert_exit_code 1 "$?" "goenv absent: gvm_detect returns 1 (graceful not-installed)" || failures=$((failures + 1))
    fi
}

# Test _gvm_validate_version with valid version format
test_gvm_validate_version_format_valid() {
    # Test valid version formats
    if _gvm_validate_version "1.21.5" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 1.21.5 accepted" || failures=$((failures + 1))
    else
        assert_equals "valid" "invalid" "1.21.5 should be valid format" || failures=$((failures + 1))
    fi

    if _gvm_validate_version "1.23.4" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 1.23.4 accepted" || failures=$((failures + 1))
    else
        assert_equals "valid" "invalid" "1.23.4 should be valid format" || failures=$((failures + 1))
    fi
}

# Test _gvm_validate_version with invalid version format
test_gvm_validate_version_format_invalid() {
    # Test invalid version formats
    if ! _gvm_validate_version "invalid" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version 'invalid' rejected" || failures=$((failures + 1))
    else
        assert_equals "rejected" "accepted" "'invalid' should be rejected" || failures=$((failures + 1))
    fi

    if ! _gvm_validate_version "1.21" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version '1.21' (no patch) rejected" || failures=$((failures + 1))
    else
        assert_equals "rejected" "accepted" "'1.21' should be rejected" || failures=$((failures + 1))
    fi

    if ! _gvm_validate_version "go1.21.5" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version 'go1.21.5' (with prefix) rejected" || failures=$((failures + 1))
    else
        assert_equals "rejected" "accepted" "'go1.21.5' should be rejected" || failures=$((failures + 1))
    fi
}

# Test gvm_is_go_project detection
test_gvm_is_go_project_with_go_mod() {
    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    # Create go.mod file
    echo "module test" > go.mod

    if gvm_is_go_project; then
        assert_equals "true" "true" "Detected Go project with go.mod" || failures=$((failures + 1))
    else
        assert_equals "detected" "not_detected" "Should detect go.mod as Go project" || failures=$((failures + 1))
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test gvm_is_go_project with .go-version file
test_gvm_is_go_project_with_go_version() {
    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    # Create .go-version file
    echo "1.23.4" > .go-version

    if gvm_is_go_project; then
        assert_equals "true" "true" "Detected Go project with .go-version" || failures=$((failures + 1))
    else
        assert_equals "detected" "not_detected" "Should detect .go-version as Go project" || failures=$((failures + 1))
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test gvm_is_go_project with no Go files
test_gvm_is_go_project_not_go() {
    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    # Create a non-Go file
    echo "test" > test.txt

    if ! gvm_is_go_project; then
        assert_equals "true" "true" "Correctly identified non-Go project" || failures=$((failures + 1))
    else
        assert_equals "not_detected" "detected" "Should not detect as Go project" || failures=$((failures + 1))
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test gvm_get_current function exists
test_gvm_get_current_function_exists() {
    if declare -f gvm_get_current >/dev/null 2>&1; then
        assert_equals "true" "true" "gvm_get_current function exists" || failures=$((failures + 1))
    else
        assert_equals "function_exists" "function_missing" "gvm_get_current function should exist" || failures=$((failures + 1))
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
            missing=$((missing + 1))
        fi
    done

    if [[ $missing -eq 0 ]]; then
        assert_equals "true" "true" "All 10 exported functions exist" || failures=$((failures + 1))
    else
        assert_equals "0" "$missing" "$missing functions are missing" || failures=$((failures + 1))
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

# M0 step 3: explicit failure accumulation — exit with the failure count, not
# merely the status of the last test case.
exit "$failures"
