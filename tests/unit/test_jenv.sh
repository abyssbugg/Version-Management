#!/usr/bin/env bash
# Unit tests for lib/jenv.sh - Java Version Manager

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
source "$ROOT_DIR/lib/jenv.sh"

# Own strict-mode posture (remediation directive M0 step 3): lib/env.sh and
# lib/logger.sh set `set -euo pipefail` at source time and that posture leaks
# into this test shell. These tests branch on return codes themselves and must
# not abort on the first non-zero (e.g. jenv_detect returning 1 when jenv is
# absent), so the own posture is deliberately non-aborting:
set +e +u +o pipefail

failures=0

# Test jenv_detect function exists and is callable
test_jenv_detect_function_exists() {
    if declare -f jenv_detect >/dev/null 2>&1; then
        assert_equals "true" "true" "jenv_detect function exists" || failures=$((failures + 1))
    else
        assert_equals "function_exists" "function_missing" "jenv_detect function should exist" || failures=$((failures + 1))
    fi
}

# Test jenv_detect returns the correct value for the actual environment
test_jenv_detect_returns_value() {
    # M0 step 3 (environment-independent semantics): jenv presence is a
    # property of the host, so branch on it and assert the correct outcome for
    # each world instead of relying on the macOS host having jenv installed.
    if command -v jenv >/dev/null 2>&1; then
        jenv_detect >/dev/null 2>&1
        assert_exit_code 0 "$?" "jenv present: jenv_detect returns 0" || failures=$((failures + 1))
    else
        jenv_detect >/dev/null 2>&1
        assert_exit_code 1 "$?" "jenv absent: jenv_detect returns 1 (graceful not-installed)" || failures=$((failures + 1))
    fi
}

# Test _jenv_validate_version with valid version formats
test_jenv_validate_version_format_valid() {
    # Test valid version formats - Java supports multiple formats
    # Format: major.minor.patch
    if _jenv_validate_version "17.0.8" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 17.0.8 accepted" || failures=$((failures + 1))
    else
        assert_equals "valid" "invalid" "17.0.8 should be valid format" || failures=$((failures + 1))
    fi

    # Format: major.minor
    if _jenv_validate_version "11.0" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 11.0 accepted" || failures=$((failures + 1))
    else
        assert_equals "valid" "invalid" "11.0 should be valid format" || failures=$((failures + 1))
    fi

    # Format: major only (common for Java 8, 11, 17, 21)
    if _jenv_validate_version "17" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 17 accepted" || failures=$((failures + 1))
    else
        assert_equals "valid" "invalid" "17 should be valid format" || failures=$((failures + 1))
    fi
}

# Test _jenv_validate_version with invalid version format
test_jenv_validate_version_format_invalid() {
    # Test invalid version formats
    if ! _jenv_validate_version "invalid" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version 'invalid' rejected" || failures=$((failures + 1))
    else
        assert_equals "rejected" "accepted" "'invalid' should be rejected" || failures=$((failures + 1))
    fi

    if ! _jenv_validate_version "java17" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version 'java17' rejected" || failures=$((failures + 1))
    else
        assert_equals "rejected" "accepted" "'java17' should be rejected" || failures=$((failures + 1))
    fi
}

# Test jenv_is_java_project detection with pom.xml (Maven)
test_jenv_is_java_project_with_pom() {
    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    echo "<project></project>" > pom.xml

    if jenv_is_java_project; then
        assert_equals "true" "true" "Detected Java project with pom.xml" || failures=$((failures + 1))
    else
        assert_equals "detected" "not_detected" "Should detect pom.xml as Java project" || failures=$((failures + 1))
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test jenv_is_java_project with build.gradle (Gradle)
test_jenv_is_java_project_with_gradle() {
    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    echo "plugins { id 'java' }" > build.gradle

    if jenv_is_java_project; then
        assert_equals "true" "true" "Detected Java project with build.gradle" || failures=$((failures + 1))
    else
        assert_equals "detected" "not_detected" "Should detect build.gradle as Java project" || failures=$((failures + 1))
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test jenv_is_java_project with .java-version file
test_jenv_is_java_project_with_java_version() {
    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    echo "17.0.12" > .java-version

    if jenv_is_java_project; then
        assert_equals "true" "true" "Detected Java project with .java-version" || failures=$((failures + 1))
    else
        assert_equals "detected" "not_detected" "Should detect .java-version as Java project" || failures=$((failures + 1))
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test jenv_is_java_project with no Java files
test_jenv_is_java_project_not_java() {
    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    echo "test" > test.txt

    if ! jenv_is_java_project; then
        assert_equals "true" "true" "Correctly identified non-Java project" || failures=$((failures + 1))
    else
        assert_equals "not_detected" "detected" "Should not detect as Java project" || failures=$((failures + 1))
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test jenv_get_current function exists
test_jenv_get_current_function_exists() {
    if declare -f jenv_get_current >/dev/null 2>&1; then
        assert_equals "true" "true" "jenv_get_current function exists" || failures=$((failures + 1))
    else
        assert_equals "function_exists" "function_missing" "jenv_get_current function should exist" || failures=$((failures + 1))
    fi
}

# Test all exported functions exist
test_all_exported_functions_exist() {
    local functions=("jenv_detect" "jenv_install" "jenv_list_versions" "jenv_add_version"
                     "jenv_set_global" "jenv_set_local" "jenv_get_current" "jenv_validate_version"
                     "jenv_get_prompt_version" "jenv_is_java_project")
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
echo "=== Java Version Manager (jenv) Tests ==="
test_jenv_detect_function_exists
test_jenv_detect_returns_value
test_jenv_validate_version_format_valid
test_jenv_validate_version_format_invalid
test_jenv_is_java_project_with_pom
test_jenv_is_java_project_with_gradle
test_jenv_is_java_project_with_java_version
test_jenv_is_java_project_not_java
test_jenv_get_current_function_exists
test_all_exported_functions_exist

# M0 step 3: explicit failure accumulation — exit with the failure count, not
# merely the status of the last test case.
exit "$failures"
