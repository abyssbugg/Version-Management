#!/usr/bin/env bash
# Unit tests for lib/jenv.sh - Java Version Manager

source ../helpers.sh
source ../../lib/jenv.sh

# Test jenv_detect function exists and is callable
test_jenv_detect_function_exists() {
    if declare -f jenv_detect >/dev/null 2>&1; then
        assert_equals "true" "true" "jenv_detect function exists"
    else
        assert_equals "function_exists" "function_missing" "jenv_detect function should exist"
    fi
}

# Test jenv_detect returns appropriate value
test_jenv_detect_returns_value() {
    jenv_detect >/dev/null 2>&1
    local exit_code=$?
    if [[ $exit_code -eq 0 ]] || [[ $exit_code -eq 1 ]]; then
        assert_equals "true" "true" "jenv_detect returns valid exit code ($exit_code)"
    else
        assert_equals "0_or_1" "$exit_code" "jenv_detect should return 0 or 1"
    fi
}

# Test _jenv_validate_version with valid version formats
test_jenv_validate_version_format_valid() {
    # Test valid version formats - Java supports multiple formats
    # Format: major.minor.patch
    if _jenv_validate_version "17.0.8" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 17.0.8 accepted"
    else
        assert_equals "valid" "invalid" "17.0.8 should be valid format"
    fi

    # Format: major.minor
    if _jenv_validate_version "11.0" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 11.0 accepted"
    else
        assert_equals "valid" "invalid" "11.0 should be valid format"
    fi

    # Format: major only (common for Java 8, 11, 17, 21)
    if _jenv_validate_version "17" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 17 accepted"
    else
        assert_equals "valid" "invalid" "17 should be valid format"
    fi
}

# Test _jenv_validate_version with invalid version format
test_jenv_validate_version_format_invalid() {
    # Test invalid version formats
    if ! _jenv_validate_version "invalid" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version 'invalid' rejected"
    else
        assert_equals "rejected" "accepted" "'invalid' should be rejected"
    fi

    if ! _jenv_validate_version "java17" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version 'java17' rejected"
    else
        assert_equals "rejected" "accepted" "'java17' should be rejected"
    fi
}

# Test jenv_is_java_project detection with pom.xml (Maven)
test_jenv_is_java_project_with_pom() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    echo "<project></project>" > pom.xml

    if jenv_is_java_project; then
        assert_equals "true" "true" "Detected Java project with pom.xml"
    else
        assert_equals "detected" "not_detected" "Should detect pom.xml as Java project"
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test jenv_is_java_project with build.gradle (Gradle)
test_jenv_is_java_project_with_gradle() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    echo "plugins { id 'java' }" > build.gradle

    if jenv_is_java_project; then
        assert_equals "true" "true" "Detected Java project with build.gradle"
    else
        assert_equals "detected" "not_detected" "Should detect build.gradle as Java project"
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test jenv_is_java_project with .java-version file
test_jenv_is_java_project_with_java_version() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    echo "17.0.12" > .java-version

    if jenv_is_java_project; then
        assert_equals "true" "true" "Detected Java project with .java-version"
    else
        assert_equals "detected" "not_detected" "Should detect .java-version as Java project"
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test jenv_is_java_project with no Java files
test_jenv_is_java_project_not_java() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    echo "test" > test.txt

    if ! jenv_is_java_project; then
        assert_equals "true" "true" "Correctly identified non-Java project"
    else
        assert_equals "not_detected" "detected" "Should not detect as Java project"
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test jenv_get_current function exists
test_jenv_get_current_function_exists() {
    if declare -f jenv_get_current >/dev/null 2>&1; then
        assert_equals "true" "true" "jenv_get_current function exists"
    else
        assert_equals "function_exists" "function_missing" "jenv_get_current function should exist"
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

exit $?
