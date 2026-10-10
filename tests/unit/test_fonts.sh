#!/usr/bin/env bash
# ============================================================================
# Unit Tests for lib/fonts.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/tests/helpers.sh"
source "$SCRIPT_DIR/lib/fonts.sh"

# ============================================================================
# Test Cases
# ============================================================================

test_font_get_directories() {
    start_test "font_get_directories returns paths"

    local dirs
    dirs=$(font_get_directories)

    # Should return at least one directory
    assert_not_empty "$dirs" "Should return font directories"

    # On macOS, should include Library/Fonts
    if [[ "$(uname -s)" == "Darwin" ]]; then
        assert_contains "Library/Fonts" "$dirs" "Should include Library/Fonts on macOS"
    fi

    # On Linux, should include .local/share/fonts
    if [[ "$(uname -s)" == "Linux" ]]; then
        assert_contains ".local/share/fonts" "$dirs" "Should include .local/share/fonts on Linux"
    fi

    end_test
}

test_font_get_target_directory() {
    start_test "font_get_target_directory returns user-writable path"

    local target
    target=$(font_get_target_directory)

    assert_not_empty "$target" "Should return a target directory"

    # Target should be in user's home directory
    assert_contains "$HOME" "$target" "Target should be in HOME"

    end_test
}

test_font_validate_file() {
    start_test "font_validate_file checks file existence"

    # Test with existing file
    local temp_file
    temp_file=$(mktemp)
    echo "test" > "$temp_file"

    if font_validate_file "$temp_file"; then
        pass "Validates existing file"
    else
        fail "Should validate existing file"
    fi

    rm -f "$temp_file"

    # Test with non-existent file
    if font_validate_file "/nonexistent/file.ttf"; then
        fail "Should not validate non-existent file"
    else
        pass "Correctly rejects non-existent file"
    fi

    end_test
}

# Regression: a checksum validator must fail CLOSED when it cannot verify.
# font_validate_checksum used to "assume valid" (return 0) when neither
# shasum nor sha256sum was on PATH, unlike the download path which already
# refuses to install an unverified font.
test_font_validate_checksum_fails_closed() {
    start_test "font_validate_checksum fails closed without a sha256 tool"

    local sb rc_ok rc_bad rc_notool good
    sb=$(mktemp -d "${TMPDIR:-/tmp}/vms-fvc.XXXXXX")
    mkdir -p "$sb/nohash"
    ln -s "$(command -v cut)" "$sb/nohash/cut"
    printf 'font-bytes\n' > "$sb/f.ttf"
    if command -v sha256sum >/dev/null 2>&1; then
        good=$(sha256sum "$sb/f.ttf" | cut -d' ' -f1)
    else
        good=$(shasum -a 256 "$sb/f.ttf" | cut -d' ' -f1)
    fi

    font_validate_checksum "$sb/f.ttf" "$good" && rc_ok=0 || rc_ok=$?
    font_validate_checksum "$sb/f.ttf" "0000" && rc_bad=0 || rc_bad=$?
    # shellcheck disable=SC2123 # deliberate: restricted PATH probe in a subshell
    ( PATH="$sb/nohash"; font_validate_checksum "$sb/f.ttf" "$good" ) >/dev/null 2>&1 && rc_notool=0 || rc_notool=$?
    rm -rf "$sb"

    assert_equals "0" "$rc_ok" "Matching checksum validates"
    assert_equals "1" "$rc_bad" "Mismatched checksum is rejected"
    assert_equals "1" "$rc_notool" "No sha256 tool is rejected, not assumed valid"

    end_test
}

test_bundled_fonts_array() {
    start_test "BUNDLED_FONTS array is defined"

    # Check array exists and has elements
    if [[ ${#BUNDLED_FONTS[@]} -gt 0 ]]; then
        pass "BUNDLED_FONTS has ${#BUNDLED_FONTS[@]} elements"
    else
        fail "BUNDLED_FONTS should have elements"
    fi

    # Check expected font names
    local expected_fonts=(
        "MesloLGS NF Regular.ttf"
        "MesloLGS NF Bold.ttf"
        "MesloLGS NF Italic.ttf"
        "MesloLGS NF Bold Italic.ttf"
    )

    for font in "${expected_fonts[@]}"; do
        local found=false
        for bundled in "${BUNDLED_FONTS[@]}"; do
            if [[ "$bundled" == "$font" ]]; then
                found=true
                break
            fi
        done

        if [[ "$found" == "true" ]]; then
            pass "Contains: $font"
        else
            fail "Missing: $font"
        fi
    done

    end_test
}

test_font_constants() {
    start_test "Font constants are defined"

    assert_not_empty "$FONT_FAMILY" "FONT_FAMILY should be defined"
    assert_not_empty "$FONT_ORIGIN" "FONT_ORIGIN should be defined"
    assert_not_empty "$FONT_LICENSE" "FONT_LICENSE should be defined"

    assert_contains "MesloLGS" "$FONT_FAMILY" "FONT_FAMILY should mention MesloLGS"
    assert_contains "github.com" "$FONT_ORIGIN" "FONT_ORIGIN should be a GitHub URL"

    end_test
}

test_font_detect_installed() {
    start_test "font_detect_installed runs without error"

    # Should not error even if no fonts found
    local result
    result=$(font_detect_installed 2>&1) || true

    # Result can be empty (no fonts) or contain paths
    # Just verify it doesn't crash
    pass "font_detect_installed completed"

    end_test
}

test_font_is_installed() {
    start_test "font_is_installed returns boolean"

    # Function should return 0 or 1 without crashing
    if font_is_installed; then
        pass "MesloLGS fonts are installed"
    else
        pass "MesloLGS fonts are not installed (expected on clean system)"
    fi

    end_test
}

test_font_bundled_exist() {
    start_test "font_bundled_exist checks project fonts"

    # Check if bundled fonts exist in project
    if font_bundled_exist; then
        pass "All bundled fonts exist in project"
    else
        # This might fail if fonts aren't in the repo
        skip "Some bundled fonts missing from project (may be gitignored)"
    fi

    end_test
}

test_font_status() {
    start_test "font_status outputs information"

    local output
    output=$(font_status)

    assert_not_empty "$output" "Should produce output"
    assert_contains "Status" "$output" "Should include status"
    assert_contains "Font Family" "$output" "Should include font family"

    end_test
}

test_font_check_terminal() {
    start_test "font_check_terminal provides guidance"

    local output
    output=$(font_check_terminal)

    assert_not_empty "$output" "Should produce output"
    assert_contains "MesloLGS" "$output" "Should mention MesloLGS font"

    end_test
}

# ============================================================================
# Run Tests
# ============================================================================

run_tests() {
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           Font Module Unit Tests                             ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo

    test_font_get_directories
    test_font_get_target_directory
    test_font_validate_file
    test_font_validate_checksum_fails_closed
    test_bundled_fonts_array
    test_font_constants
    test_font_detect_installed
    test_font_is_installed
    test_font_bundled_exist
    test_font_status
    test_font_check_terminal

    echo
    print_summary
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
fi
