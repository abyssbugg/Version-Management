#!/usr/bin/env bash
# Unit tests for lib/phpenv.sh - PHP Version Manager

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"

# Provide logger stubs needed by phpenv.sh
log_info()  { :; }
log_debug() { :; }
log_error() { :; }
log_warn()  { :; }
export -f log_info log_debug log_error log_warn

source "$ROOT_DIR/lib/phpenv.sh"

# Test phpenv_detect function exists and is callable
test_phpenv_detect_function_exists() {
    if declare -f phpenv_detect >/dev/null 2>&1; then
        assert_equals "true" "true" "phpenv_detect function exists"
    else
        assert_equals "function_exists" "function_missing" "phpenv_detect function should exist"
    fi
}

# Test phpenv_detect returns appropriate value
test_phpenv_detect_returns_value() {
    phpenv_detect >/dev/null 2>&1
    local exit_code=$?
    if [[ $exit_code -eq 0 ]] || [[ $exit_code -eq 1 ]]; then
        assert_equals "true" "true" "phpenv_detect returns valid exit code ($exit_code)"
    else
        assert_equals "0_or_1" "$exit_code" "phpenv_detect should return 0 or 1"
    fi
}

# Test _phpenv_validate_version with valid version format
test_phpenv_validate_version_format_valid() {
    if _phpenv_validate_version "8.3.12" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 8.3.12 accepted"
    else
        assert_equals "valid" "invalid" "8.3.12 should be valid format"
    fi

    if _phpenv_validate_version "8.2.0" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 8.2.0 accepted"
    else
        assert_equals "valid" "invalid" "8.2.0 should be valid format"
    fi

    if _phpenv_validate_version "7.4.33" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 7.4.33 accepted"
    else
        assert_equals "valid" "invalid" "7.4.33 should be valid format"
    fi
}

# Test _phpenv_validate_version with invalid version format
test_phpenv_validate_version_format_invalid() {
    if ! _phpenv_validate_version "invalid" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version 'invalid' rejected"
    else
        assert_equals "rejected" "accepted" "'invalid' should be rejected"
    fi

    if ! _phpenv_validate_version "8.3" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version '8.3' (no patch) rejected"
    else
        assert_equals "rejected" "accepted" "'8.3' should be rejected"
    fi

    if ! _phpenv_validate_version "php8.3.12" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version 'php8.3.12' (with prefix) rejected"
    else
        assert_equals "rejected" "accepted" "'php8.3.12' should be rejected"
    fi
}

# Test phpenv_is_php_project detection with composer.json
test_phpenv_is_php_project_with_composer_json() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    echo '{"require": {"php": ">=8.1"}}' > composer.json

    if phpenv_is_php_project; then
        assert_equals "true" "true" "Detected PHP project with composer.json"
    else
        assert_equals "detected" "not_detected" "Should detect composer.json as PHP project"
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test phpenv_is_php_project with .php-version file
test_phpenv_is_php_project_with_php_version() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    echo "8.3.12" > .php-version

    if phpenv_is_php_project; then
        assert_equals "true" "true" "Detected PHP project with .php-version"
    else
        assert_equals "detected" "not_detected" "Should detect .php-version as PHP project"
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test phpenv_is_php_project with artisan (Laravel)
test_phpenv_is_php_project_with_artisan() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    touch artisan

    if phpenv_is_php_project; then
        assert_equals "true" "true" "Detected PHP project with artisan"
    else
        assert_equals "detected" "not_detected" "Should detect artisan as PHP project"
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test phpenv_is_php_project with no PHP files
test_phpenv_is_php_project_not_php() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    echo "test" > test.txt

    if ! phpenv_is_php_project; then
        assert_equals "true" "true" "Correctly identified non-PHP project"
    else
        assert_equals "not_detected" "detected" "Should not detect as PHP project"
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test phpenv_get_current function exists
test_phpenv_get_current_function_exists() {
    if declare -f phpenv_get_current >/dev/null 2>&1; then
        assert_equals "true" "true" "phpenv_get_current function exists"
    else
        assert_equals "function_exists" "function_missing" "phpenv_get_current function should exist"
    fi
}

# Test composer_detect function exists
test_composer_detect_function_exists() {
    if declare -f composer_detect >/dev/null 2>&1; then
        assert_equals "true" "true" "composer_detect function exists"
    else
        assert_equals "function_exists" "function_missing" "composer_detect function should exist"
    fi
}

# Test laravel_detect_project function exists
test_laravel_detect_project_function_exists() {
    if declare -f laravel_detect_project >/dev/null 2>&1; then
        assert_equals "true" "true" "laravel_detect_project function exists"
    else
        assert_equals "function_exists" "function_missing" "laravel_detect_project function should exist"
    fi
}

# Test all exported functions exist
test_all_exported_functions_exist() {
    local functions=("phpenv_detect" "phpenv_install" "phpenv_list_versions" "phpenv_install_version"
                     "phpenv_set_global" "phpenv_set_local" "phpenv_get_current" "phpenv_validate_version"
                     "phpenv_get_prompt_version" "phpenv_is_php_project"
                     "composer_detect" "composer_install" "laravel_install" "laravel_detect_project")
    local missing=0

    for func in "${functions[@]}"; do
        if ! declare -f "$func" >/dev/null 2>&1; then
            echo "Missing function: $func"
            ((missing++))
        fi
    done

    if [[ $missing -eq 0 ]]; then
        assert_equals "true" "true" "All 14 exported functions exist"
    else
        assert_equals "0" "$missing" "$missing functions are missing"
    fi
}

# Run tests
echo "=== PHP Version Manager (phpenv) Tests ==="
test_phpenv_detect_function_exists
test_phpenv_detect_returns_value
test_phpenv_validate_version_format_valid
test_phpenv_validate_version_format_invalid
test_phpenv_is_php_project_with_composer_json
test_phpenv_is_php_project_with_php_version
test_phpenv_is_php_project_with_artisan
test_phpenv_is_php_project_not_php
test_phpenv_get_current_function_exists
test_composer_detect_function_exists
test_laravel_detect_project_function_exists
test_all_exported_functions_exist

exit $?
