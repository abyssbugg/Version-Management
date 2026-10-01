#!/usr/bin/env bash
# ============================================================================
# Cross-Platform Integration Tests
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/tests/helpers.sh"

# ============================================================================
# Platform Detection Tests
# ============================================================================

test_platform_detection() {
    start_test "Platform is supported"

    local os
    os=$(uname -s)

    case "$os" in
        Darwin)
            pass "macOS detected - fully supported"
            ;;
        Linux)
            if grep -qi "microsoft" /proc/version 2>/dev/null; then
                pass "WSL2 detected - supported with limitations"
            else
                pass "Linux detected - fully supported"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            warn "Windows shell detected - partial support"
            ;;
        *)
            fail "Unknown platform: $os"
            ;;
    esac

    end_test
}

test_architecture() {
    start_test "Architecture is supported"

    local arch
    arch=$(uname -m)

    case "$arch" in
        x86_64|amd64)
            pass "x86_64 architecture - fully supported"
            ;;
        arm64|aarch64)
            pass "ARM64 architecture - supported"
            ;;
        *)
            warn "Unusual architecture: $arch - may have limitations"
            ;;
    esac

    end_test
}

# ============================================================================
# Shell Compatibility Tests
# ============================================================================

test_shell_compatibility() {
    start_test "Shell is zsh"

    local shell
    shell=$(basename "${SHELL:-/bin/bash}")

    if [[ "$shell" == "zsh" ]]; then
        pass "zsh is default shell"
    else
        warn "Default shell is $shell (zsh recommended)"
    fi

    # Check if zsh is available
    if command -v zsh >/dev/null 2>&1; then
        local zsh_version
        zsh_version=$(zsh --version 2>/dev/null | head -1)
        pass "zsh available: $zsh_version"
    else
        fail "zsh not installed"
    fi

    end_test
}

test_bash_version() {
    start_test "Bash version is adequate"

    local bash_version
    bash_version="${BASH_VERSION:-unknown}"

    if [[ "$bash_version" == "unknown" ]]; then
        fail "Cannot determine bash version"
    else
        local major
        major="${bash_version%%.*}"
        if [[ "$major" -ge 4 ]]; then
            pass "Bash $bash_version (4.0+ required)"
        else
            skip "Bash $bash_version (4.0+ recommended for associative arrays)"
        fi
    fi

    end_test
}

# ============================================================================
# Core Dependencies Tests
# ============================================================================

test_git_available() {
    start_test "Git is installed"

    if command -v git >/dev/null 2>&1; then
        local version
        version=$(git --version | head -1)
        pass "$version"
    else
        fail "Git not installed"
    fi

    end_test
}

test_curl_or_wget() {
    start_test "curl or wget available"

    if command -v curl >/dev/null 2>&1; then
        pass "curl available"
    elif command -v wget >/dev/null 2>&1; then
        pass "wget available"
    else
        fail "Neither curl nor wget installed"
    fi

    end_test
}

# ============================================================================
# Version Manager Tests
# ============================================================================

test_version_managers_installable() {
    start_test "Version manager paths are valid"

    local managers_found=0

    # Check NVM
    if [[ -d "${NVM_DIR:-$HOME/.nvm}" ]] || command -v nvm >/dev/null 2>&1; then
        pass "NVM: available"
        managers_found=$(( managers_found + 1 ))
    else
        info "NVM: not installed"
    fi

    # Check pyenv
    if [[ -d "${PYENV_ROOT:-$HOME/.pyenv}" ]] || command -v pyenv >/dev/null 2>&1; then
        pass "pyenv: available"
        managers_found=$(( managers_found + 1 ))
    else
        info "pyenv: not installed"
    fi

    # Check goenv
    if [[ -d "$HOME/.goenv" ]] || command -v goenv >/dev/null 2>&1; then
        pass "goenv: available"
        managers_found=$(( managers_found + 1 ))
    else
        info "goenv: not installed"
    fi

    # Check rustup
    if command -v rustup >/dev/null 2>&1; then
        pass "rustup: available"
        managers_found=$(( managers_found + 1 ))
    else
        info "rustup: not installed"
    fi

    # Check jenv
    if [[ -d "$HOME/.jenv" ]] || command -v jenv >/dev/null 2>&1; then
        pass "jenv: available"
        managers_found=$(( managers_found + 1 ))
    else
        info "jenv: not installed"
    fi

    if [[ $managers_found -ge 2 ]]; then
        pass "$managers_found version managers available"
    else
        warn "Only $managers_found version managers found (2+ recommended)"
    fi

    end_test
}

# ============================================================================
# File System Tests
# ============================================================================

test_home_directory_writable() {
    start_test "Home directory is writable"

    local test_file="$HOME/.version-manager-test-$$"

    if touch "$test_file" 2>/dev/null; then
        rm -f "$test_file"
        pass "Home directory writable"
    else
        fail "Cannot write to home directory"
    fi

    end_test
}

test_config_directory_creatable() {
    start_test "Config directories can be created"

    local test_dir="$HOME/.config/version-manager-test-$$"

    if mkdir -p "$test_dir" 2>/dev/null; then
        rmdir "$test_dir"
        pass "Can create config directories"
    else
        fail "Cannot create config directories"
    fi

    end_test
}

# ============================================================================
# Font System Tests
# ============================================================================

test_font_directories_exist() {
    start_test "Font directories accessible"

    local os
    os=$(uname -s)
    local font_dirs=()

    case "$os" in
        Darwin)
            font_dirs=("$HOME/Library/Fonts" "/Library/Fonts")
            ;;
        Linux)
            font_dirs=("$HOME/.local/share/fonts" "$HOME/.fonts" "/usr/share/fonts")
            ;;
    esac

    local found=0
    for dir in "${font_dirs[@]}"; do
        if [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null; then
            found=$(( found + 1 ))
        fi
    done

    if [[ $found -gt 0 ]]; then
        pass "Found $found font directory locations"
    else
        warn "No font directories accessible"
    fi

    end_test
}

# ============================================================================
# Project File Tests
# ============================================================================

test_project_structure() {
    start_test "Project structure is intact"

    local required_dirs=(
        "lib"
        "config"
        "tests"
        "tools"
        "scripts"
    )

    local missing=0
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$SCRIPT_DIR/$dir" ]]; then
            fail "Missing directory: $dir"
            missing=$(( missing + 1 ))
        fi
    done

    if [[ $missing -eq 0 ]]; then
        pass "All required directories present"
    fi

    end_test
}

test_core_scripts_executable() {
    start_test "Core scripts are executable"

    local scripts=(
        "setup.sh"
        "setup-theme.sh"
        "setup-versions.sh"
        "validate-setup.sh"
    )

    local not_executable=0
    for script in "${scripts[@]}"; do
        if [[ -f "$SCRIPT_DIR/$script" ]]; then
            if [[ ! -x "$SCRIPT_DIR/$script" ]]; then
                warn "$script is not executable"
                not_executable=$(( not_executable + 1 ))
            fi
        else
            fail "$script not found"
        fi
    done

    if [[ $not_executable -eq 0 ]]; then
        pass "All core scripts are executable"
    fi

    end_test
}

test_library_modules_sourceable() {
    start_test "Library modules can be sourced"

    local libs=(
        "lib/logger.sh"
        "lib/env.sh"
        "lib/backup.sh"
        "lib/cache.sh"
    )

    local failed=0
    for lib in "${libs[@]}"; do
        if [[ -f "$SCRIPT_DIR/$lib" ]]; then
            if bash -n "$SCRIPT_DIR/$lib" 2>/dev/null; then
                pass "$lib: valid syntax"
            else
                fail "$lib: syntax error"
                failed=$(( failed + 1 ))
            fi
        else
            warn "$lib: not found"
        fi
    done

    if [[ $failed -eq 0 ]]; then
        pass "All library modules have valid syntax"
    fi

    end_test
}

# ============================================================================
# Run Tests
# ============================================================================

run_tests() {
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           Cross-Platform Integration Tests                   ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo
    echo "Platform: $(uname -s) $(uname -m)"
    echo "Shell: ${SHELL:-unknown}"
    echo "Date: $(date)"
    echo

    echo "━━━ Platform Detection ━━━"
    test_platform_detection
    test_architecture

    echo
    echo "━━━ Shell Compatibility ━━━"
    test_shell_compatibility
    test_bash_version

    echo
    echo "━━━ Core Dependencies ━━━"
    test_git_available
    test_curl_or_wget

    echo
    echo "━━━ Version Managers ━━━"
    test_version_managers_installable

    echo
    echo "━━━ File System ━━━"
    test_home_directory_writable
    test_config_directory_creatable
    test_font_directories_exist

    echo
    echo "━━━ Project Structure ━━━"
    test_project_structure
    test_core_scripts_executable
    test_library_modules_sourceable

    echo
    print_summary
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
fi
