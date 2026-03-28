#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source paths; SC2034: intentionally exported vars

# Java Version Management Library Module
# Part of Professional Development Terminal Setup
# Provides standardized Java version management interface using jenv
# Integrates with foundational libraries for caching, logging, and environment setup

# Source foundational libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/cache.sh"
source "${SCRIPT_DIR}/logger.sh"

# Java version management configuration
JENV_CACHE_PREFIX="jenv"
JENV_CACHE_TTL=300  # 5 minutes cache for version lists

# ============================================================================
# JENV DETECTION AND INSTALLATION
# ============================================================================

# Detect if jenv is installed and available
# Returns: 0 if jenv is available, 1 if not
jenv_detect() {
    log_debug "Detecting jenv installation"
    
    if command -v jenv >/dev/null 2>&1; then
        local jenv_version=$(jenv --version 2>/dev/null)
        log_info "jenv detected: version $jenv_version"
        return 0
    else
        log_warn "jenv not found in PATH"
        return 1
    fi
}

# Install jenv if missing
# Returns: 0 on success, 1 on failure
jenv_install() {
    log_info "Installing jenv..."
    
    if jenv_detect; then
        log_info "jenv already installed"
        return 0
    fi
    
    local os_type=$(detect_os)
    
    if ! command -v git >/dev/null 2>&1; then
        log_error "Git is required to install jenv"
        return 1
    fi

    local target_dir="${JENV_ROOT:-$HOME/.jenv}"
    local repo_url="https://github.com/jenv/jenv.git"

    export JENV_ROOT="$target_dir"

    if [[ -d "$target_dir" ]]; then
        log_warn "Existing jenv installation detected. Creating backup..."
        mv "$target_dir" "$target_dir.bak.$(date +%Y%m%d_%H%M%S)"
    fi

    case "$os_type" in
        "macos")
            if command -v brew >/dev/null 2>&1; then
                log_info "Installing jenv via Homebrew"
                if brew install jenv; then
                    log_success "jenv installed successfully via Homebrew"
                    return 0
                fi
                log_error "Failed to install jenv via Homebrew"
                return 1
            fi
            ;;
    esac

    if ! git clone --depth 1 "$repo_url" "$target_dir"; then
        log_error "Failed to clone jenv repository"
        return 1
    fi

    export PATH="$target_dir/bin:$PATH"
    log_success "jenv installed successfully"
    return 0
}

# ============================================================================
# VERSION MANAGEMENT
# ============================================================================

# List available Java versions (cached)
# Returns: 0 on success, 1 on failure
jenv_list_versions() {
    log_debug "Listing available Java versions"
    
    if ! jenv_detect; then
        log_error "jenv not available"
        return 1
    fi
    
    local cache_key="${JENV_CACHE_PREFIX}_versions"
    local cached_versions
    
    if cached_versions=$(cache_get "$cache_key"); then
        log_debug "Using cached Java versions list"
        echo "$cached_versions"
        return 0
    fi
    
    log_debug "Fetching Java versions from jenv"
    local versions
    if versions=$(jenv versions --bare 2>/dev/null); then
        cache_set "$cache_key" "$versions" "$JENV_CACHE_TTL"
        echo "$versions"
        return 0
    else
        log_error "Failed to list Java versions"
        return 1
    fi
}

# Install specific Java version
# Note: jenv doesn't install Java versions, it only manages existing installations
# Args: version - Java version to add to jenv (e.g., "17.0.8")
# Returns: 0 on success, 1 on failure
jenv_add_version() {
    local version="$1"
    local java_home="$2"
    
    if [ -z "$version" ]; then
        log_error "Java version not specified"
        return 1
    fi
    
    if [ -z "$java_home" ]; then
        log_error "Java home path not specified"
        return 1
    fi
    
    if ! _jenv_validate_version "$version"; then
        return 1
    fi
    
    if ! jenv_detect; then
        log_error "jenv not available"
        return 1
    fi
    
    if [ ! -d "$java_home" ]; then
        log_error "Java home path does not exist: $java_home"
        return 1
    fi
    
    log_info "Adding Java $version at $java_home to jenv..."
    
    # Add the version to jenv
    if jenv add "$java_home" 2>/dev/null; then
        log_success "Java $version added to jenv successfully"
        # Invalidate cache
        cache_delete "${JENV_CACHE_PREFIX}_versions"
        return 0
    else
        log_error "Failed to add Java $version to jenv"
        return 1
    fi
}

# Set global Java version
# Args: version - Java version to set as global
# Returns: 0 on success, 1 on failure
jenv_set_global() {
    local version="$1"
    
    if [ -z "$version" ]; then
        log_error "Java version not specified"
        return 1
    fi
    
    if ! _jenv_validate_version "$version"; then
        return 1
    fi
    
    if ! jenv_detect; then
        log_error "jenv not available"
        return 1
    fi
    
    # Check if version is installed
    if ! jenv_validate_version "$version"; then
        log_warn "Java $version not found in jenv registry"
        return 1
    fi
    
    log_info "Setting global Java version to $version"
    if jenv global "$version" 2>/dev/null; then
        log_success "Global Java version set to $version"
        return 0
    else
        log_error "Failed to set global Java version"
        return 1
    fi
}

# Set local Java version for current directory
# Args: version - Java version to set as local
# Returns: 0 on success, 1 on failure
jenv_set_local() {
    local version="$1"
    
    if [ -z "$version" ]; then
        log_error "Java version not specified"
        return 1
    fi
    
    if ! _jenv_validate_version "$version"; then
        return 1
    fi
    
    if ! jenv_detect; then
        log_error "jenv not available"
        return 1
    fi
    
    # Check if version is installed
    if ! jenv_validate_version "$version"; then
        log_warn "Java $version not found in jenv registry"
        return 1
    fi
    
    log_info "Setting local Java version to $version"
    
    # Set jenv local version
    if jenv local "$version" 2>/dev/null; then
        log_success "Local Java version set to $version"
        return 0
    else
        log_error "Failed to set local Java version with jenv"
        return 1
    fi
}

# Get current Java version
# Returns: current Java version string
jenv_get_current() {
    log_debug "Getting current Java version"
    
    if ! jenv_detect; then
        echo "system"
        return 1
    fi
    
    local current_version
    if current_version=$(jenv version-name 2>/dev/null); then
        echo "$current_version"
        return 0
    else
        echo "system"
        return 1
    fi
}

# Validate that a Java version exists in installed versions
# Args: version - Java version to validate
# Returns: 0 if version exists, 1 if not
jenv_validate_version() {
    local version="$1"
    
    if [ -z "$version" ]; then
        log_error "Java version not specified"
        return 1
    fi
    
    if ! jenv_detect; then
        log_error "jenv not available"
        return 1
    fi
    
    log_debug "Validating Java version: $version"
    
    if jenv versions --bare 2>/dev/null | grep -q "^${version}$"; then
        log_debug "Java version $version is installed"
        return 0
    else
        log_warn "Java version $version is not installed"
        return 1
    fi
}

# ============================================================================
# PRIVATE HELPER FUNCTIONS
# ============================================================================

# Validate Java version format
# Args: version - version string to validate
# Returns: 0 if valid format, 1 if invalid
_jenv_validate_version() {
    local version="$1"
    
    if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ ! $version =~ ^[0-9]+\.[0-9]+$ ]] && [[ ! $version =~ ^[0-9]+$ ]]; then
        log_error "Invalid Java version format: $version"
        log_info "Expected format: major.minor.patch, major.minor, or major (e.g., 17.0.8, 11.0, 8)"
        return 1
    fi
    
    return 0
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Get Java version for prompt display (only if different from global)
# Returns: Java version string or empty if same as global
jenv_get_prompt_version() {
    if ! jenv_detect; then
        return 1
    fi
    
    local current_version=$(jenv_get_current)
    local global_version=$(jenv global 2>/dev/null || echo "system")
    
    # Only show if different from global or if project-specific
    if [ -f ".java-version" ] || [ "$current_version" != "$global_version" ]; then
        echo "$current_version"
    fi
}

# Check if current directory has Java project configuration
# Returns: 0 if Java project detected, 1 if not
jenv_is_java_project() {
    [ -f ".java-version" ] || [ -f "pom.xml" ] || [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]
}

# Export functions for external use
export -f jenv_detect jenv_install jenv_list_versions jenv_add_version
export -f jenv_set_global jenv_set_local jenv_get_current jenv_validate_version
export -f jenv_get_prompt_version jenv_is_java_project