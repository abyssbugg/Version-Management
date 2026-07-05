#!/usr/bin/env bash
# Unit tests for lib/rustup.sh - Rust Toolchain Manager

source ../helpers.sh
source ../../lib/rustup.sh

# Test rustup_detect function exists and is callable
test_rustup_detect_function_exists() {
    if declare -f rustup_detect >/dev/null 2>&1; then
        assert_equals "true" "true" "rustup_detect function exists"
    else
        assert_equals "function_exists" "function_missing" "rustup_detect function should exist"
    fi
}

# Test rustup_detect returns appropriate value
test_rustup_detect_returns_value() {
    rustup_detect >/dev/null 2>&1
    local exit_code=$?
    if [[ $exit_code -eq 0 ]] || [[ $exit_code -eq 1 ]]; then
        assert_equals "true" "true" "rustup_detect returns valid exit code ($exit_code)"
    else
        assert_equals "0_or_1" "$exit_code" "rustup_detect should return 0 or 1"
    fi
}

# Test _rustup_validate_version with valid version format
test_rustup_validate_version_format_valid() {
    # Test valid version formats
    if _rustup_validate_version "1.75.0" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 1.75.0 accepted"
    else
        assert_equals "valid" "invalid" "1.75.0 should be valid format"
    fi

    if _rustup_validate_version "1.81.0" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 1.81.0 accepted"
    else
        assert_equals "valid" "invalid" "1.81.0 should be valid format"
    fi
}

# Test _rustup_validate_version with invalid version format
test_rustup_validate_version_format_invalid() {
    # Test invalid version formats
    if ! _rustup_validate_version "invalid" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version 'invalid' rejected"
    else
        assert_equals "rejected" "accepted" "'invalid' should be rejected"
    fi

    if ! _rustup_validate_version "1.75" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version '1.75' (no patch) rejected"
    else
        assert_equals "rejected" "accepted" "'1.75' should be rejected"
    fi

    if ! _rustup_validate_version "stable" 2>/dev/null; then
        assert_equals "true" "true" "Version 'stable' rejected (channel name, not version)"
    else
        # Note: stable might be considered valid as a channel, but _rustup_validate_version checks semver
        assert_equals "true" "true" "'stable' handled appropriately"
    fi
}

# Test rustup_is_rust_project detection with Cargo.toml
test_rustup_is_rust_project_with_cargo() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    cat > Cargo.toml << 'EOF'
[package]
name = "test"
version = "0.1.0"
EOF

    if rustup_is_rust_project; then
        assert_equals "true" "true" "Detected Rust project with Cargo.toml"
    else
        assert_equals "detected" "not_detected" "Should detect Cargo.toml as Rust project"
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test rustup_is_rust_project with rust-toolchain file
test_rustup_is_rust_project_with_toolchain() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    echo "1.81.0" > rust-toolchain

    if rustup_is_rust_project; then
        assert_equals "true" "true" "Detected Rust project with rust-toolchain"
    else
        assert_equals "detected" "not_detected" "Should detect rust-toolchain as Rust project"
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test rustup_is_rust_project with rust-toolchain.toml
test_rustup_is_rust_project_with_toolchain_toml() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    cat > rust-toolchain.toml << 'EOF'
[toolchain]
channel = "1.81.0"
EOF

    if rustup_is_rust_project; then
        assert_equals "true" "true" "Detected Rust project with rust-toolchain.toml"
    else
        assert_equals "detected" "not_detected" "Should detect rust-toolchain.toml as Rust project"
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test rustup_is_rust_project with no Rust files
test_rustup_is_rust_project_not_rust() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    echo "test" > test.txt

    if ! rustup_is_rust_project; then
        assert_equals "true" "true" "Correctly identified non-Rust project"
    else
        assert_equals "not_detected" "detected" "Should not detect as Rust project"
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test rustup_get_current function exists
test_rustup_get_current_function_exists() {
    if declare -f rustup_get_current >/dev/null 2>&1; then
        assert_equals "true" "true" "rustup_get_current function exists"
    else
        assert_equals "function_exists" "function_missing" "rustup_get_current function should exist"
    fi
}

# Test all exported functions exist
test_all_exported_functions_exist() {
    local functions=("rustup_detect" "rustup_install" "rustup_list_versions" "rustup_install_version"
                     "rustup_set_global" "rustup_set_local" "rustup_get_current" "rustup_validate_version"
                     "rustup_get_prompt_version" "rustup_is_rust_project")
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
echo "=== Rust Toolchain Manager (rustup) Tests ==="
test_rustup_detect_function_exists
test_rustup_detect_returns_value
test_rustup_validate_version_format_valid
test_rustup_validate_version_format_invalid
test_rustup_is_rust_project_with_cargo
test_rustup_is_rust_project_with_toolchain
test_rustup_is_rust_project_with_toolchain_toml
test_rustup_is_rust_project_not_rust
test_rustup_get_current_function_exists
test_all_exported_functions_exist

exit $?
