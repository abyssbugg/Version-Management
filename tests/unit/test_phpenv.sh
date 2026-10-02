#!/usr/bin/env bash
# Unit tests for lib/phpenv.sh - PHP Version Manager

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"

# warn/info — environment-inventory branches legitimately differ between
# hosts (macOS workstation vs Linux container); they report without failing
# the file. Defined here rather than in tests/helpers.sh, which carries
# user-owned staged changes (remediation directive Rule 2) — do not move
# back into helpers.sh while that holds.
warn() {
    # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
    local message="${1:-warning}"
    # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
    echo -e "${YELLOW}⚠ ${message}${NC}"
}

info() {
    # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
    local message="${1:-info}"
    # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
    echo -e "ℹ ${message}"
}

# Provide logger stubs needed by phpenv.sh
# shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
log_info()  { :; }
# shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
log_debug() { :; }
# shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
log_error() { :; }
# shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
log_warn()  { :; }
export -f log_info log_debug log_error log_warn

source "$ROOT_DIR/lib/phpenv.sh"

# Own strict-mode posture (remediation directive M0 step 3): lib/phpenv.sh
# transitively sources lib/env.sh and lib/logger.sh, which set
# `set -euo pipefail` at source time; that -e must not govern this test. The
# file's own posture (set -uo pipefail above) is kept, minus the leaked -e:
set +e

failures=0

# Test phpenv_detect function exists and is callable
test_phpenv_detect_function_exists() {
    if declare -f phpenv_detect >/dev/null 2>&1; then
        assert_equals "true" "true" "phpenv_detect function exists" || failures=$((failures + 1))
    else
        assert_equals "function_exists" "function_missing" "phpenv_detect function should exist" || failures=$((failures + 1))
    fi
}

# Test phpenv_detect returns the correct value for the actual environment
test_phpenv_detect_returns_value() {
    # M0 step 3 (environment-independent semantics): phpenv presence is a
    # property of the host, so branch on it and assert the correct outcome for
    # each world instead of relying on the macOS host having phpenv installed.
    if command -v phpenv >/dev/null 2>&1; then
        phpenv_detect >/dev/null 2>&1
        assert_exit_code 0 "$?" "phpenv present: phpenv_detect returns 0" || failures=$((failures + 1))
    else
        phpenv_detect >/dev/null 2>&1
        assert_exit_code 1 "$?" "phpenv absent: phpenv_detect returns 1 (graceful not-installed)" || failures=$((failures + 1))
    fi
}

# Test _phpenv_validate_version with valid version format
test_phpenv_validate_version_format_valid() {
    if _phpenv_validate_version "8.3.12" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 8.3.12 accepted" || failures=$((failures + 1))
    else
        assert_equals "valid" "invalid" "8.3.12 should be valid format" || failures=$((failures + 1))
    fi

    if _phpenv_validate_version "8.2.0" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 8.2.0 accepted" || failures=$((failures + 1))
    else
        assert_equals "valid" "invalid" "8.2.0 should be valid format" || failures=$((failures + 1))
    fi

    if _phpenv_validate_version "7.4.33" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 7.4.33 accepted" || failures=$((failures + 1))
    else
        assert_equals "valid" "invalid" "7.4.33 should be valid format" || failures=$((failures + 1))
    fi
}

# Test _phpenv_validate_version with invalid version format
test_phpenv_validate_version_format_invalid() {
    if ! _phpenv_validate_version "invalid" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version 'invalid' rejected" || failures=$((failures + 1))
    else
        assert_equals "rejected" "accepted" "'invalid' should be rejected" || failures=$((failures + 1))
    fi

    if ! _phpenv_validate_version "8.3" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version '8.3' (no patch) rejected" || failures=$((failures + 1))
    else
        assert_equals "rejected" "accepted" "'8.3' should be rejected" || failures=$((failures + 1))
    fi

    if ! _phpenv_validate_version "php8.3.12" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version 'php8.3.12' (with prefix) rejected" || failures=$((failures + 1))
    else
        assert_equals "rejected" "accepted" "'php8.3.12' should be rejected" || failures=$((failures + 1))
    fi
}

# Test phpenv_is_php_project detection with composer.json
test_phpenv_is_php_project_with_composer_json() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    echo '{"require": {"php": ">=8.1"}}' > composer.json

    if phpenv_is_php_project; then
        assert_equals "true" "true" "Detected PHP project with composer.json" || failures=$((failures + 1))
    else
        assert_equals "detected" "not_detected" "Should detect composer.json as PHP project" || failures=$((failures + 1))
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
        assert_equals "true" "true" "Detected PHP project with .php-version" || failures=$((failures + 1))
    else
        assert_equals "detected" "not_detected" "Should detect .php-version as PHP project" || failures=$((failures + 1))
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
        assert_equals "true" "true" "Detected PHP project with artisan" || failures=$((failures + 1))
    else
        assert_equals "detected" "not_detected" "Should detect artisan as PHP project" || failures=$((failures + 1))
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
        assert_equals "true" "true" "Correctly identified non-PHP project" || failures=$((failures + 1))
    else
        assert_equals "not_detected" "detected" "Should not detect as PHP project" || failures=$((failures + 1))
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test phpenv_get_current function exists
test_phpenv_get_current_function_exists() {
    if declare -f phpenv_get_current >/dev/null 2>&1; then
        assert_equals "true" "true" "phpenv_get_current function exists" || failures=$((failures + 1))
    else
        assert_equals "function_exists" "function_missing" "phpenv_get_current function should exist" || failures=$((failures + 1))
    fi
}

# Test composer_detect function exists
test_composer_detect_function_exists() {
    if declare -f composer_detect >/dev/null 2>&1; then
        assert_equals "true" "true" "composer_detect function exists" || failures=$((failures + 1))
    else
        assert_equals "function_exists" "function_missing" "composer_detect function should exist" || failures=$((failures + 1))
    fi
}

# Test laravel_detect_project function exists
test_laravel_detect_project_function_exists() {
    if declare -f laravel_detect_project >/dev/null 2>&1; then
        assert_equals "true" "true" "laravel_detect_project function exists" || failures=$((failures + 1))
    else
        assert_equals "function_exists" "function_missing" "laravel_detect_project function should exist" || failures=$((failures + 1))
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
            missing=$(( missing + 1 ))
        fi
    done

    if [[ $missing -eq 0 ]]; then
        assert_equals "true" "true" "All 14 exported functions exist" || failures=$((failures + 1))
    else
        assert_equals "0" "$missing" "$missing functions are missing" || failures=$((failures + 1))
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

# M0 step 3: explicit failure accumulation — exit with the failure count, not
# merely the status of the last test case.
exit "$failures"
