#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source paths; SC2034: intentionally exported vars

# Go Version Management Library Module
# Part of Professional Development Terminal Setup
# Provides standardized Go version management interface using goenv
# Integrates with foundational libraries for caching, logging, and environment setup

# Source foundational libraries
_VMS_GVM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_VMS_GVM_DIR}/env.sh"
source "${_VMS_GVM_DIR}/cache.sh"
source "${_VMS_GVM_DIR}/logger.sh"
# Unconditional (B1.13-new): install_dir_stage/install_dir_restore are
# export -f'd, so inherited copies would defeat a declare -f guard.
# backup.sh is re-source-safe (preserves live transaction state).
source "${_VMS_GVM_DIR}/backup.sh"

# Go version management configuration
GVM_CACHE_PREFIX="gvm"
GVM_CACHE_TTL=300  # 5 minutes cache for version lists

# ============================================================================
# GOENV DETECTION AND INSTALLATION
# ============================================================================

# Detect if goenv is installed and available
# Returns: 0 if goenv is available, 1 if not
gvm_detect() {
    log_debug "Detecting goenv installation"

    if command -v goenv >/dev/null 2>&1; then
        local goenv_version=$(goenv --version 2>/dev/null | cut -d' ' -f2)
        log_info "goenv detected: version $goenv_version"
        return 0
    else
        log_warn "goenv not found in PATH"
        return 1
    fi
}

# Install goenv if missing
# Returns: 0 on success, 1 on failure
gvm_install() {
    log_info "Installing goenv..."

    if gvm_detect; then
        log_info "goenv already installed"
        return 0
    fi

    local os_type=$(detect_os)

    if ! command -v git >/dev/null 2>&1; then
        log_error "Git is required to install goenv"
        return 1
    fi

    local target_dir="${GOENV_ROOT:-$HOME/.goenv}"
    local repo_url="https://github.com/syndbg/goenv.git"

    export GOENV_ROOT="$target_dir"

    case "$os_type" in
        "macos")
            if command -v brew >/dev/null 2>&1; then
                # Homebrew does not use $target_dir: never moved aside (AX-6d).
                log_info "Installing goenv via Homebrew"
                if brew install goenv; then
                    log_success "goenv installed successfully via Homebrew"
                    return 0
                fi
                log_error "Failed to install goenv via Homebrew"
                return 1
            fi
            ;;
    esac

    # AX-6d: stage IMMEDIATELY before the clone; restore on failure.
    local staged
    staged="$target_dir.bak.$(date +%Y%m%d_%H%M%S)"
    if [[ -d "$target_dir" ]]; then
        log_warn "Existing goenv installation detected. Creating backup..."
    fi
    install_dir_stage "$target_dir" "$staged" || return 1

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would git clone $repo_url -> $target_dir; nothing installed"
        return 0
    fi

    if ! git clone --depth 1 "$repo_url" "$target_dir"; then
        log_error "Failed to clone goenv repository"
        install_dir_restore "$target_dir" "$staged" || true
        return 1
    fi

    export PATH="$target_dir/bin:$PATH"
    log_success "goenv installed successfully"
    return 0
}

# ============================================================================
# VERSION MANAGEMENT
# ============================================================================

# List available Go versions (cached)
# Returns: 0 on success, 1 on failure
gvm_list_versions() {
    log_debug "Listing available Go versions"

    if ! gvm_detect; then
        log_error "goenv not available"
        return 1
    fi

    local cache_key="${GVM_CACHE_PREFIX}_versions"
    local cached_versions

    if cached_versions=$(cache_get "$cache_key"); then
        log_debug "Using cached Go versions list"
        echo "$cached_versions"
        return 0
    fi

    log_debug "Fetching Go versions from goenv"
    local versions
    if versions=$(goenv install --list 2>/dev/null); then
        cache_set "$cache_key" "$versions" "$GVM_CACHE_TTL"
        echo "$versions"
        return 0
    else
        log_error "Failed to list Go versions"
        return 1
    fi
}

# Install specific Go version
# Args: version - Go version to install (e.g., "1.21.5")
# Returns: 0 on success, 1 on failure
gvm_install_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Go version not specified"
        return 1
    fi

    if ! _gvm_validate_version "$version"; then
        return 1
    fi

    if ! gvm_detect; then
        log_error "goenv not available"
        return 1
    fi

    log_info "Installing Go $version..."

    # Check if already installed
    if goenv versions --bare 2>/dev/null | grep -q "^${version}$"; then
        log_info "Go $version already installed"
        return 0
    fi

    # Install the version
    if goenv install "$version" 2>/dev/null; then
        log_success "Go $version installed successfully"
        # Invalidate cache
        cache_delete "${GVM_CACHE_PREFIX}_versions"
        return 0
    else
        log_error "Failed to install Go $version"
        return 1
    fi
}

# Set global Go version
# Args: version - Go version to set as global
# Returns: 0 on success, 1 on failure
gvm_set_global() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Go version not specified"
        return 1
    fi

    if ! _gvm_validate_version "$version"; then
        return 1
    fi

    if ! gvm_detect; then
        log_error "goenv not available"
        return 1
    fi

    # Check if version is installed
    if ! gvm_validate_version "$version"; then
        log_warn "Go $version not found, attempting to install..."
        if ! gvm_install_version "$version"; then
            return 1
        fi
    fi

    log_info "Setting global Go version to $version"
    if goenv global "$version" 2>/dev/null; then
        log_success "Global Go version set to $version"
        return 0
    else
        log_error "Failed to set global Go version"
        return 1
    fi
}

# Set local Go version for current directory
# Args: version - Go version to set as local
# Returns: 0 on success, 1 on failure
gvm_set_local() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Go version not specified"
        return 1
    fi

    if ! _gvm_validate_version "$version"; then
        return 1
    fi

    if ! gvm_detect; then
        log_error "goenv not available"
        return 1
    fi

    # Check if version is installed
    if ! gvm_validate_version "$version"; then
        log_warn "Go $version not found, attempting to install..."
        if ! gvm_install_version "$version"; then
            return 1
        fi
    fi

    log_info "Setting local Go version to $version"

    # Create .go-version file
    if echo "$version" > .go-version; then
        # Set goenv local version
        if goenv local "$version" 2>/dev/null; then
            log_success "Local Go version set to $version"
            return 0
        else
            log_error "Failed to set local Go version with goenv"
            return 1
        fi
    else
        log_error "Failed to create .go-version file"
        return 1
    fi
}

# Get current Go version
# Returns: current Go version string
gvm_get_current() {
    log_debug "Getting current Go version"

    if ! gvm_detect; then
        echo "system"
        return 1
    fi

    local current_version
    if current_version=$(goenv version-name 2>/dev/null); then
        echo "$current_version"
        return 0
    else
        echo "system"
        return 1
    fi
}

# Validate that a Go version exists in installed versions
# Args: version - Go version to validate
# Returns: 0 if version exists, 1 if not
gvm_validate_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Go version not specified"
        return 1
    fi

    if ! gvm_detect; then
        log_error "goenv not available"
        return 1
    fi

    log_debug "Validating Go version: $version"

    if goenv versions --bare 2>/dev/null | grep -q "^${version}$"; then
        log_debug "Go version $version is installed"
        return 0
    else
        log_warn "Go version $version is not installed"
        return 1
    fi
}

# ============================================================================
# PRIVATE HELPER FUNCTIONS
# ============================================================================

# Validate Go version format
# Args: version - version string to validate
# Returns: 0 if valid format, 1 if invalid
_gvm_validate_version() {
    local version="$1"

    if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid Go version format: $version"
        log_info "Expected format: major.minor.patch (e.g., 1.21.5)"
        return 1
    fi

    return 0
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Get Go version for prompt display (only if different from global)
# Returns: Go version string or empty if same as global
gvm_get_prompt_version() {
    if ! gvm_detect; then
        return 1
    fi

    local current_version=$(gvm_get_current)
    local global_version=$(goenv global 2>/dev/null || echo "system")

    # Only show if different from global or if project-specific
    if [ -f ".go-version" ] || [ "$current_version" != "$global_version" ]; then
        echo "$current_version"
    fi
}

# Check if current directory has Go project configuration
# Returns: 0 if Go project detected, 1 if not
gvm_is_go_project() {
    [ -f ".go-version" ] || [ -f "go.mod" ] || [ -f "Gopkg.toml" ] || [ -f "glide.yaml" ]
}

# Export functions for external use
export -f gvm_detect gvm_install gvm_list_versions gvm_install_version
export -f gvm_set_global gvm_set_local gvm_get_current gvm_validate_version
export -f gvm_get_prompt_version gvm_is_go_project
