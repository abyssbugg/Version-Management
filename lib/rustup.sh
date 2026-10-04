#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source paths; SC2034: intentionally exported vars

# Rust Version Management Library Module
# Part of Professional Development Terminal Setup
# Provides standardized Rust version management interface using rustup
# Integrates with foundational libraries for caching, logging, and environment setup

# Source foundational libraries
_VMS_RUSTUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_VMS_RUSTUP_DIR}/env.sh"
source "${_VMS_RUSTUP_DIR}/cache.sh"
source "${_VMS_RUSTUP_DIR}/logger.sh"

# Rust version management configuration
RUSTUP_CACHE_PREFIX="rustup"
RUSTUP_CACHE_TTL=300  # 5 minutes cache for version lists

# ============================================================================
# RUSTUP DETECTION AND INSTALLATION
# ============================================================================

# Detect if rustup is installed and available
# Returns: 0 if rustup is available, 1 if not
rustup_detect() {
    log_debug "Detecting rustup installation"

    if command -v rustup >/dev/null 2>&1; then
        local rustup_version=$(rustup --version 2>/dev/null | head -n1 | cut -d' ' -f2)
        log_info "rustup detected: version $rustup_version"
        return 0
    else
        log_warn "rustup not found in PATH"
        return 1
    fi
}

# Install rustup if missing
# Returns: 0 on success, 1 on failure
rustup_install() {
    log_info "Installing rustup..."

    if rustup_detect; then
        log_info "rustup already installed"
        return 0
    fi

    local os_type=$(detect_os)

    # Check if curl is available
    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required to install rustup"
        return 1
    fi

    case "$os_type" in
        "macos")
            if command -v brew >/dev/null 2>&1; then
                log_info "Installing rustup via Homebrew"
                if brew install rustup; then
                    log_success "rustup installed successfully via Homebrew"
                    return 0
                fi
                log_error "Failed to install rustup via Homebrew"
                return 1
            fi
            ;;
    esac

    # Install via rustup-init.sh
    local rustup_init_script="$HOME/.cargo/rustup-init.sh"
    local rustup_dir="${RUSTUP_HOME:-$HOME/.rustup}"

    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$rustup_init_script")"

    # Download rustup-init.sh
    log_info "Downloading rustup installer..."
    if ! curl -fsSL -o "$rustup_init_script" "https://sh.rustup.rs"; then
        log_error "Failed to download rustup installer"
        return 1
    fi

    # Validate the downloaded script before execution (supply-chain safety)
    local script_size
    script_size=$(wc -c < "$rustup_init_script" 2>/dev/null || echo 0)
    if [[ ! -s "$rustup_init_script" ]]; then
        log_error "Downloaded rustup installer is empty"
        rm -f "$rustup_init_script"
        return 1
    fi
    if [[ "$script_size" -lt 1024 ]]; then
        log_error "Downloaded rustup installer is suspiciously small ($script_size bytes)"
        rm -f "$rustup_init_script"
        return 1
    fi
    if ! head -c 4 "$rustup_init_script" | grep -q '^#!'; then
        log_error "Downloaded rustup installer does not begin with a shebang (#!); refusing to execute"
        rm -f "$rustup_init_script"
        return 1
    fi
    log_info "Downloaded rustup installer validated (${script_size} bytes, shebang present)"
    chmod +x "$rustup_init_script"

    # Install rustup with minimal profile and no modifications to shell files
    log_info "Running rustup installer..."
    if "$rustup_init_script" -y --no-modify-path --profile minimal 2>/dev/null; then
        # Add cargo bin to PATH if not already there
        local cargo_bin="$HOME/.cargo/bin"
        if [[ ":$PATH:" != *":$cargo_bin:"* ]]; then
            export PATH="$cargo_bin:$PATH"
        fi

        log_success "rustup installed successfully"
        return 0
    else
        log_error "Failed to install rustup"
        return 1
    fi
}

# ============================================================================
# VERSION MANAGEMENT
# ============================================================================

# List available Rust versions (cached)
# Returns: 0 on success, 1 on failure
rustup_list_versions() {
    log_debug "Listing available Rust versions"

    if ! rustup_detect; then
        log_error "rustup not available"
        return 1
    fi

    local cache_key="${RUSTUP_CACHE_PREFIX}_versions"
    local cached_versions

    if cached_versions=$(cache_get "$cache_key"); then
        log_debug "Using cached Rust versions list"
        echo "$cached_versions"
        return 0
    fi

    log_debug "Fetching Rust versions from rustup"
    local versions
    if versions=$(rustup toolchain list 2>/dev/null); then
        cache_set "$cache_key" "$versions" "$RUSTUP_CACHE_TTL"
        echo "$versions"
        return 0
    else
        log_error "Failed to list Rust versions"
        return 1
    fi
}

# Install specific Rust version
# Args: version - Rust version to install (e.g., "1.75.0")
# Returns: 0 on success, 1 on failure
rustup_install_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Rust version not specified"
        return 1
    fi

    if ! _rustup_validate_version "$version"; then
        return 1
    fi

    if ! rustup_detect; then
        log_error "rustup not available"
        return 1
    fi

    log_info "Installing Rust $version..."

    # Check if already installed
    if rustup toolchain list 2>/dev/null | grep -q "$version"; then
        log_info "Rust $version already installed"
        return 0
    fi

    # Install the version
    if rustup toolchain install "$version" 2>/dev/null; then
        log_success "Rust $version installed successfully"
        # Invalidate cache
        cache_delete "${RUSTUP_CACHE_PREFIX}_versions"
        return 0
    else
        log_error "Failed to install Rust $version"
        return 1
    fi
}

# Set global Rust version
# Args: version - Rust version to set as default
# Returns: 0 on success, 1 on failure
rustup_set_global() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Rust version not specified"
        return 1
    fi

    if ! _rustup_validate_version "$version"; then
        return 1
    fi

    if ! rustup_detect; then
        log_error "rustup not available"
        return 1
    fi

    # Check if version is installed
    if ! rustup_validate_version "$version"; then
        log_warn "Rust $version not found, attempting to install..."
        if ! rustup_install_version "$version"; then
            return 1
        fi
    fi

    log_info "Setting global Rust version to $version"
    if rustup default "$version" 2>/dev/null; then
        log_success "Global Rust version set to $version"
        return 0
    else
        log_error "Failed to set global Rust version"
        return 1
    fi
}

# Set local Rust version for current directory
# Args: version - Rust version to set for current project
# Returns: 0 on success, 1 on failure
rustup_set_local() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Rust version not specified"
        return 1
    fi

    if ! _rustup_validate_version "$version"; then
        return 1
    fi

    if ! rustup_detect; then
        log_error "rustup not available"
        return 1
    fi

    # Check if version is installed
    if ! rustup_validate_version "$version"; then
        log_warn "Rust $version not found, attempting to install..."
        if ! rustup_install_version "$version"; then
            return 1
        fi
    fi

    log_info "Setting local Rust version to $version"

    # Create rust-toolchain file
    if echo "$version" > rust-toolchain; then
        log_success "Local Rust version set to $version"
        return 0
    else
        log_error "Failed to create rust-toolchain file"
        return 1
    fi
}

# Get current Rust version
# Returns: current Rust version string
rustup_get_current() {
    log_debug "Getting current Rust version"

    if ! rustup_detect; then
        echo "none"
        return 1
    fi

    local current_version
    if current_version=$(rustc --version 2>/dev/null | cut -d' ' -f2); then
        echo "$current_version"
        return 0
    else
        echo "none"
        return 1
    fi
}

# Validate that a Rust version exists in installed versions
# Args: version - Rust version to validate
# Returns: 0 if version exists, 1 if not
rustup_validate_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Rust version not specified"
        return 1
    fi

    if ! rustup_detect; then
        log_error "rustup not available"
        return 1
    fi

    log_debug "Validating Rust version: $version"

    if rustup toolchain list 2>/dev/null | grep -q "$version"; then
        log_debug "Rust version $version is installed"
        return 0
    else
        log_warn "Rust version $version is not installed"
        return 1
    fi
}

# ============================================================================
# PRIVATE HELPER FUNCTIONS
# ============================================================================

# Validate Rust version format
# Args: version - version string to validate
# Returns: 0 if valid format, 1 if invalid
_rustup_validate_version() {
    local version="$1"

    if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid Rust version format: $version"
        log_info "Expected format: major.minor.patch (e.g., 1.75.0)"
        return 1
    fi

    return 0
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Get Rust version for prompt display (only if different from default)
# Returns: Rust version string or empty if same as default
rustup_get_prompt_version() {
    if ! rustup_detect; then
        return 1
    fi

    local current_version=$(rustup_get_current)
    local default_version=$(rustup show active-toolchain 2>/dev/null | head -n1 | cut -d' ' -f1)

    # Only show if different from default or if project-specific
    if [ -f "rust-toolchain" ] || [ "$current_version" != "$default_version" ]; then
        echo "$current_version"
    fi
}

# Check if current directory has Rust project configuration
# Returns: 0 if Rust project detected, 1 if not
rustup_is_rust_project() {
    [ -f "rust-toolchain" ] || [ -f "Cargo.toml" ] || [ -f "rust-toolchain.toml" ]
}

# Export functions for external use
export -f rustup_detect rustup_install rustup_list_versions rustup_install_version
export -f rustup_set_global rustup_set_local rustup_get_current rustup_validate_version
export -f rustup_get_prompt_version rustup_is_rust_project
