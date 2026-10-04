#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source paths; SC2034: intentionally exported vars

# FNM (Fast Node Manager) Library Module
# Part of Professional Development Terminal Setup
# Provides standardized Node.js version management interface using fnm
# Integrates with foundational libraries for caching, logging, and environment setup

# Source guard — prevent re-sourcing crashes with `readonly` vars under set -e
[[ -n "${_FNM_SH_LOADED:-}" ]] && return 0
readonly _FNM_SH_LOADED=1

# Source foundational libraries
_VMS_FNM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_VMS_FNM_DIR}/env.sh"
source "${_VMS_FNM_DIR}/cache.sh"
source "${_VMS_FNM_DIR}/logger.sh"

# FNM version management configuration
FNM_CACHE_PREFIX="fnm"
FNM_CACHE_TTL=300  # 5 minutes cache for version lists

# ============================================================================
# FNM DETECTION AND INSTALLATION
# ============================================================================

# Detect if fnm is installed and available
# Returns: 0 if fnm is available, 1 if not
fnm_detect() {
    log_debug "Detecting fnm installation"

    if command -v fnm >/dev/null 2>&1; then
        local fnm_version
        fnm_version=$(fnm --version 2>/dev/null | cut -d' ' -f2)
        log_info "fnm detected: version $fnm_version"
        return 0
    else
        log_warn "fnm not found in PATH"
        return 1
    fi
}

# Install fnm if missing
# Returns: 0 on success, 1 on failure
fnm_install() {
    log_info "Installing fnm..."

    if fnm_detect; then
        log_info "fnm already installed"
        return 0
    fi

    local os_type
    os_type=$(detect_os)

    case "$os_type" in
        "macos")
            if command -v brew >/dev/null 2>&1; then
                log_info "Installing fnm via Homebrew"
                if brew install fnm; then
                    log_success "fnm installed successfully via Homebrew"
                    eval "$(fnm env)" 2>/dev/null || true
                    return 0
                fi
                log_error "Failed to install fnm via Homebrew"
                return 1
            fi
            ;;
    esac

    log_error "Failed to install fnm via package manager. Refusing to run remote install scripts (curl|bash)."
    log_info "Install fnm with a trusted package manager, then rerun setup."
    return 1
}

# ============================================================================
# VERSION MANAGEMENT
# ============================================================================

# List available Node.js versions (cached)
# Returns: 0 on success, 1 on failure
fnm_list_versions() {
    log_debug "Listing available Node.js versions via fnm"

    if ! fnm_detect; then
        log_error "fnm not available"
        return 1
    fi

    local cache_key="${FNM_CACHE_PREFIX}_versions"
    local cached_versions

    if cached_versions=$(cache_get "$cache_key"); then
        log_debug "Using cached Node.js versions list (fnm)"
        echo "$cached_versions"
        return 0
    fi

    log_debug "Fetching Node.js versions from fnm"
    local versions
    if versions=$(fnm list 2>/dev/null | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+'); then
        cache_set "$cache_key" "$versions" "$FNM_CACHE_TTL"
        echo "$versions"
        return 0
    else
        log_error "Failed to list Node.js versions via fnm"
        return 1
    fi
}

# Install specific Node.js version
# Args: version - Node.js version to install (e.g., "20.19.2" or "v20.19.2")
# Returns: 0 on success, 1 on failure
fnm_install_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Node.js version not specified"
        return 1
    fi

    # Remove 'v' prefix if present for validation
    local clean_version=${version#v}
    if ! _fnm_validate_version "$clean_version"; then
        return 1
    fi

    if ! fnm_detect; then
        log_error "fnm not available"
        return 1
    fi

    log_info "Installing Node.js $version via fnm..."

    # Check if already installed
    if fnm list 2>/dev/null | grep -q "v${clean_version}"; then
        log_info "Node.js $version already installed (fnm)"
        return 0
    fi

    # Install the version
    if fnm install "$clean_version" >/dev/null 2>&1; then
        log_success "Node.js $version installed successfully via fnm"
        # Invalidate cache
        cache_delete "${FNM_CACHE_PREFIX}_versions"
        return 0
    else
        log_error "Failed to install Node.js $version via fnm"
        return 1
    fi
}

# Set global (default) Node.js version
# Args: version - Node.js version to set as default
# Returns: 0 on success, 1 on failure
fnm_set_global() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Node.js version not specified"
        return 1
    fi

    local clean_version=${version#v}
    if ! _fnm_validate_version "$clean_version"; then
        return 1
    fi

    if ! fnm_detect; then
        log_error "fnm not available"
        return 1
    fi

    # Check if version is installed
    if ! fnm_validate_version "$clean_version"; then
        log_warn "Node.js $version not found, attempting to install..."
        if ! fnm_install_version "$clean_version"; then
            return 1
        fi
    fi

    log_info "Setting default Node.js version to $version (fnm)"
    if fnm default "$clean_version" >/dev/null 2>&1; then
        log_success "Default Node.js version set to $version (fnm)"
        return 0
    else
        log_error "Failed to set default Node.js version via fnm"
        return 1
    fi
}

# Set local Node.js version for current directory
# Args: version - Node.js version to set as local
# Returns: 0 on success, 1 on failure
fnm_set_local() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Node.js version not specified"
        return 1
    fi

    local clean_version=${version#v}
    if ! _fnm_validate_version "$clean_version"; then
        return 1
    fi

    if ! fnm_detect; then
        log_error "fnm not available"
        return 1
    fi

    # Check if version is installed
    if ! fnm_validate_version "$clean_version"; then
        log_warn "Node.js $version not found, attempting to install..."
        if ! fnm_install_version "$clean_version"; then
            return 1
        fi
    fi

    log_info "Setting local Node.js version to $version (fnm)"

    # Create .node-version file (fnm's preferred format)
    if echo "$clean_version" > .node-version; then
        if fnm use "$clean_version" >/dev/null 2>&1; then
            log_success "Local Node.js version set to $version (fnm)"
            return 0
        else
            log_error "Failed to switch to Node.js $version via fnm"
            return 1
        fi
    else
        log_error "Failed to create .node-version file"
        return 1
    fi
}

# Get current Node.js version via fnm
# Returns: current Node.js version string
fnm_get_current() {
    log_debug "Getting current Node.js version (fnm)"

    if ! fnm_detect; then
        echo "none"
        return 1
    fi

    local current_version
    if current_version=$(fnm current 2>/dev/null); then
        echo "$current_version"
        return 0
    else
        echo "none"
        return 1
    fi
}

# Validate that a Node.js version exists in installed versions
# Args: version - Node.js version to validate (without 'v' prefix)
# Returns: 0 if version exists, 1 if not
fnm_validate_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Node.js version not specified"
        return 1
    fi

    if ! fnm_detect; then
        log_error "fnm not available"
        return 1
    fi

    log_debug "Validating Node.js version: $version (fnm)"

    if fnm list 2>/dev/null | grep -q "v${version}"; then
        log_debug "Node.js version $version is installed (fnm)"
        return 0
    else
        log_warn "Node.js version $version is not installed (fnm)"
        return 1
    fi
}

# ============================================================================
# PRIVATE HELPER FUNCTIONS
# ============================================================================

# Validate Node.js version format
# Args: version - version string to validate (without 'v' prefix)
# Returns: 0 if valid format, 1 if invalid
_fnm_validate_version() {
    local version="$1"

    if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid Node.js version format: $version"
        log_info "Expected format: major.minor.patch (e.g., 20.19.2)"
        return 1
    fi

    return 0
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Get Node.js version for prompt display (only if different from default)
# Returns: Node.js version string or empty if same as default
fnm_get_prompt_version() {
    if ! fnm_detect; then
        return 1
    fi

    local current_version
    current_version=$(fnm_get_current)
    local default_version
    default_version=$(fnm default 2>/dev/null || echo "none")

    if [ -f ".node-version" ] || [ "$current_version" != "$default_version" ]; then
        echo "$current_version"
    fi
}

# Check if current directory has Node.js project configuration
# Returns: 0 if Node.js project detected, 1 if not
fnm_is_node_project() {
    [ -f ".node-version" ] || [ -f ".nvmrc" ] || [ -f "package.json" ] || [ -f "yarn.lock" ] || [ -f "package-lock.json" ]
}
