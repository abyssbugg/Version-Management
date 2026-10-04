#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source paths; SC2034: intentionally exported vars

# Node.js Version Management Library Module
# Part of Professional Development Terminal Setup
# Provides standardized Node.js version management interface using nvm
# Integrates with foundational libraries for caching, logging, and environment setup

# Source foundational libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/cache.sh"
source "${SCRIPT_DIR}/logger.sh"

# Node.js version management configuration
NVM_CACHE_PREFIX="nvm"
NVM_CACHE_TTL=300  # 5 minutes cache for version lists

# NVM release pin (P2-6): lib/nvm.sh is the SINGLE source of truth for the
# nvm release this suite installs. Env-overridable for local testing/control;
# the default is the one hardcoded version below. Follow-up for another lane:
# setup-versions.sh:104 duplicates the pin in its install guidance and must
# consume $NVM_VERSION from this library instead of hard-coding it.
NVM_VERSION="${NVM_VERSION:-v0.39.7}"

# ============================================================================
# NVM DETECTION AND INSTALLATION
# ============================================================================

# Detect if nvm is installed and available
# Returns: 0 if nvm is available, 1 if not
nvm_detect() {
    log_debug "Detecting nvm installation"

    # Check if NVM_DIR is set and nvm.sh exists
    if [ -n "${NVM_DIR:-}" ] && [ -s "$NVM_DIR/nvm.sh" ]; then
        # Source nvm if not already loaded
        if ! command -v nvm >/dev/null 2>&1; then
            source "$NVM_DIR/nvm.sh"
        fi

        if command -v nvm >/dev/null 2>&1; then
            local nvm_version=$(nvm --version 2>/dev/null || echo "unknown")
            log_info "nvm detected: version $nvm_version"
            return 0
        fi
    fi

    log_warn "nvm not found or not properly configured"
    return 1
}

# Source nvm if available (for use by other scripts)
# This function sources nvm.sh if NVM_DIR is set and the file exists
# Returns: 0 if nvm was sourced successfully, 1 if not available
source_nvm_if_available() {
    # Check if NVM_DIR is set
    if [[ -z "${NVM_DIR:-}" ]]; then
        # Try default location
        if [[ -d "$HOME/.nvm" ]]; then
            export NVM_DIR="$HOME/.nvm"
        else
            log_debug "NVM_DIR not set and ~/.nvm does not exist"
            return 1
        fi
    fi

    # Check if nvm.sh exists and source it
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
        source "$NVM_DIR/nvm.sh"
        log_debug "Sourced nvm from $NVM_DIR/nvm.sh"
        return 0
    fi

    log_debug "nvm.sh not found at $NVM_DIR/nvm.sh"
    return 1
}

# Install nvm if missing
# Returns: 0 on success, 1 on failure
nvm_install() {
    log_info "Installing nvm..."

    if nvm_detect; then
        log_info "nvm already installed"
        return 0
    fi

    if ! command -v git >/dev/null 2>&1; then
        log_error "Git is required to install nvm"
        return 1
    fi

    local repo_url="https://github.com/nvm-sh/nvm.git"
    local target_dir="${NVM_DIR:-$HOME/.nvm}"
    local version="$NVM_VERSION"  # P2-6: consume the single env-overridable pin

    if [[ -d "$target_dir" ]]; then
        log_warn "Existing nvm installation detected. Creating backup..."
        mv "$target_dir" "${target_dir}.bak.$(date +%Y%m%d_%H%M%S)"
    fi

    if git clone --depth 1 --branch "$version" "$repo_url" "$target_dir" 2>/dev/null || \
       (git clone "$repo_url" "$target_dir" && git -C "$target_dir" checkout "$version"); then
        export NVM_DIR="$target_dir"
        [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"
        log_success "nvm installed successfully"
        return 0
    fi

    log_error "Failed to install nvm"
    return 1
}

# ============================================================================
# VERSION MANAGEMENT
# ============================================================================

# List available Node.js versions (cached)
# Returns: 0 on success, 1 on failure
nvm_list_versions() {
    log_debug "Listing available Node.js versions"

    if ! nvm_detect; then
        log_error "nvm not available"
        return 1
    fi

    local cache_key="${NVM_CACHE_PREFIX}_versions"
    local cached_versions

    if cached_versions=$(cache_get "$cache_key"); then
        log_debug "Using cached Node.js versions list"
        echo "$cached_versions"
        return 0
    fi

    log_debug "Fetching Node.js versions from nvm"
    local versions
    if versions=$(nvm list 2>/dev/null | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+'); then
        cache_set "$cache_key" "$versions" "$NVM_CACHE_TTL"
        echo "$versions"
        return 0
    else
        log_error "Failed to list Node.js versions"
        return 1
    fi
}

# Install specific Node.js version
# Args: version - Node.js version to install (e.g., "20.19.2" or "v20.19.2")
# Returns: 0 on success, 1 on failure
nvm_install_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Node.js version not specified"
        return 1
    fi

    # Remove 'v' prefix if present for validation
    local clean_version=${version#v}
    if ! _nvm_validate_version "$clean_version"; then
        return 1
    fi

    if ! nvm_detect; then
        log_error "nvm not available"
        return 1
    fi

    log_info "Installing Node.js $version..."

    # Check if already installed (nvm list shows versions with 'v' prefix)
    local version_with_v="v${clean_version}"
    if nvm list 2>/dev/null | grep -q "$version_with_v"; then
        log_info "Node.js $version already installed"
        return 0
    fi

    # Sync global packages from current version during install
    local install_args=("$clean_version")
    local sync_from
    sync_from=$(nvm current 2>/dev/null || echo "none")
    if [[ "$sync_from" != "none" && "$sync_from" != "system" ]]; then
        install_args+=("--reinstall-packages-from=$sync_from")
        log_info "Will sync global packages from $sync_from"
    fi

    # Install the version
    if nvm install "${install_args[@]}" >/dev/null 2>&1; then
        log_success "Node.js $version installed successfully"
        # Invalidate cache
        cache_delete "${NVM_CACHE_PREFIX}_versions"
        return 0
    else
        log_error "Failed to install Node.js $version"
        return 1
    fi
}

# Set global Node.js version (default alias)
# Args: version - Node.js version to set as global
# Returns: 0 on success, 1 on failure
nvm_set_global() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Node.js version not specified"
        return 1
    fi

    # Remove 'v' prefix if present for validation
    local clean_version=${version#v}
    if ! _nvm_validate_version "$clean_version"; then
        return 1
    fi

    if ! nvm_detect; then
        log_error "nvm not available"
        return 1
    fi

    # Check if version is installed
    if ! nvm_validate_version "$clean_version"; then
        log_warn "Node.js $version not found, attempting to install..."
        if ! nvm_install_version "$clean_version"; then
            return 1
        fi
    fi

    # Capture previous default for package sync
    local prev_default
    prev_default=$(nvm alias default 2>/dev/null | grep -o 'v[0-9][0-9.]*' || echo "")

    log_info "Setting global Node.js version to $version"
    if nvm alias default "$clean_version" >/dev/null 2>&1; then
        log_success "Global Node.js version set to $version"
        # Sync global packages from previous default
        if [[ -n "$prev_default" && "${prev_default#v}" != "$clean_version" ]]; then
            log_info "Syncing global packages from $prev_default to v$clean_version..."
            nvm use "$clean_version" >/dev/null 2>&1
            if nvm reinstall-packages "$prev_default" >/dev/null 2>&1; then
                log_success "Global packages synced from $prev_default"
            else
                log_warn "Could not sync global packages from $prev_default"
            fi
        fi
        return 0
    else
        log_error "Failed to set global Node.js version"
        return 1
    fi
}

# Set local Node.js version for current directory
# Args: version - Node.js version to set as local
# Returns: 0 on success, 1 on failure
nvm_set_local() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Node.js version not specified"
        return 1
    fi

    # Remove 'v' prefix if present for validation
    local clean_version=${version#v}
    if ! _nvm_validate_version "$clean_version"; then
        return 1
    fi

    if ! nvm_detect; then
        log_error "nvm not available"
        return 1
    fi

    # Check if version is installed
    if ! nvm_validate_version "$clean_version"; then
        log_warn "Node.js $version not found, attempting to install..."
        if ! nvm_install_version "$clean_version"; then
            return 1
        fi
    fi

    log_info "Setting local Node.js version to $version"

    # Create .nvmrc file
    if echo "$clean_version" > .nvmrc; then
        # Switch to the version
        if nvm use "$clean_version" >/dev/null 2>&1; then
            log_success "Local Node.js version set to $version"
            return 0
        else
            log_error "Failed to switch to Node.js $version"
            return 1
        fi
    else
        log_error "Failed to create .nvmrc file"
        return 1
    fi
}

# Get current Node.js version
# Returns: current Node.js version string
nvm_get_current() {
    log_debug "Getting current Node.js version"

    if ! nvm_detect; then
        echo "none"
        return 1
    fi

    local current_version
    if current_version=$(nvm current 2>/dev/null); then
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
nvm_validate_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Node.js version not specified"
        return 1
    fi

    if ! nvm_detect; then
        log_error "nvm not available"
        return 1
    fi

    log_debug "Validating Node.js version: $version"

    # nvm list shows versions with 'v' prefix
    local version_with_v="v${version}"
    if nvm list 2>/dev/null | grep -q "$version_with_v"; then
        log_debug "Node.js version $version is installed"
        return 0
    else
        log_warn "Node.js version $version is not installed"
        return 1
    fi
}

# ============================================================================
# PRIVATE HELPER FUNCTIONS
# ============================================================================

# Validate Node.js version format
# Args: version - version string to validate (without 'v' prefix)
# Returns: 0 if valid format, 1 if invalid
_nvm_validate_version() {
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
nvm_get_prompt_version() {
    if ! nvm_detect; then
        return 1
    fi

    local current_version=$(nvm_get_current)
    local default_version=$(nvm alias default 2>/dev/null | cut -d' ' -f3 || echo "none")

    # Only show if different from default or if project-specific
    if [ -f ".nvmrc" ] || [ "$current_version" != "$default_version" ]; then
        echo "$current_version"
    fi
}

# Check if current directory has Node.js project configuration
# Returns: 0 if Node.js project detected, 1 if not
nvm_is_node_project() {
    [ -f ".nvmrc" ] || [ -f "package.json" ] || [ -f "yarn.lock" ] || [ -f "package-lock.json" ]
}

# Get Node.js LTS versions
# Returns: list of LTS version names
nvm_get_lts_versions() {
    if ! nvm_detect; then
        log_error "nvm not available"
        return 1
    fi

    log_debug "Getting Node.js LTS versions"

    local cache_key="${NVM_CACHE_PREFIX}_lts_versions"
    local cached_lts

    if cached_lts=$(cache_get "$cache_key"); then
        log_debug "Using cached LTS versions list"
        echo "$cached_lts"
        return 0
    fi

    # Get LTS versions (this is a simplified approach)
    local lts_versions="hydrogen iron"  # Common LTS codenames
    cache_set "$cache_key" "$lts_versions" "$NVM_CACHE_TTL"
    echo "$lts_versions"
}

# Install latest LTS version
# Returns: 0 on success, 1 on failure
nvm_install_lts() {
    if ! nvm_detect; then
        log_error "nvm not available"
        return 1
    fi

    log_info "Installing latest Node.js LTS version..."

    local sync_from
    sync_from=$(nvm current 2>/dev/null || echo "none")
    local lts_install_args=("--lts")
    if [[ "$sync_from" != "none" && "$sync_from" != "system" ]]; then
        lts_install_args+=("--reinstall-packages-from=$sync_from")
        log_info "Will sync global packages from $sync_from"
    fi

    if nvm install "${lts_install_args[@]}" >/dev/null 2>&1; then
        log_success "Latest Node.js LTS version installed"
        # Invalidate cache
        cache_delete "${NVM_CACHE_PREFIX}_versions"
        return 0
    else
        log_error "Failed to install latest Node.js LTS version"
        return 1
    fi
}

# Switch to project version if .nvmrc exists
# Returns: 0 on success, 1 on failure or no .nvmrc
nvm_use_project_version() {
    if [ ! -f ".nvmrc" ]; then
        log_debug "No .nvmrc file found"
        return 1
    fi

    if ! nvm_detect; then
        log_error "nvm not available"
        return 1
    fi

    local project_version=$(tr -d '[:space:]' 2>/dev/null < .nvmrc)
    if [ -z "$project_version" ]; then
        log_error "Empty .nvmrc file"
        return 1
    fi

    log_info "Switching to project Node.js version: $project_version"

    if nvm use "$project_version" >/dev/null 2>&1; then
        log_success "Switched to Node.js $project_version"
        return 0
    else
        log_warn "Node.js $project_version not installed, attempting to install..."
        if nvm_install_version "$project_version"; then
            nvm use "$project_version" >/dev/null 2>&1
            return $?
        else
            return 1
        fi
    fi
}

# Migrate global packages from a previous Node.js version to the current one
# Uses `nvm reinstall-packages` so packages are re-installed fresh in the current version.
# Args: from_version - the Node.js version to migrate packages from (e.g., "v24.4.0")
# Returns: 0 on success, 1 on failure
nvm_migrate_packages() {
    local from_version="$1"

    if [ -z "$from_version" ]; then
        log_error "Source version not specified. Usage: nvm_migrate_packages <from_version>"
        return 1
    fi

    if ! nvm_detect; then
        log_error "nvm not available"
        return 1
    fi

    local current_version
    current_version=$(nvm_get_current)
    log_info "Migrating global packages from $from_version to $current_version..."

    if nvm reinstall-packages "$from_version" 2>&1; then
        log_success "Global packages migrated from $from_version to $current_version"
        return 0
    else
        log_error "Failed to migrate packages from $from_version"
        return 1
    fi
}

# Export functions for external use
export -f nvm_detect nvm_install nvm_list_versions nvm_install_version
export -f nvm_set_global nvm_set_local nvm_get_current nvm_validate_version
export -f nvm_get_prompt_version nvm_is_node_project nvm_get_lts_versions
export -f nvm_install_lts nvm_use_project_version nvm_migrate_packages
