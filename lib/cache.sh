#!/bin/bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source paths; SC2034: intentionally exported vars

# Caching utilities for storing temporary data and configuration state
# Provides file-based caching with TTL and cleanup functionality

# Prevent re-sourcing
[[ -n "${_CACHE_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_CACHE_SH_LOADED=1

# Source logger for consistent output
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/logger.sh"

# Configuration
readonly CACHE_DIR="${CACHE_DIR:-$HOME/.cache/version-management-setup}"
readonly DEFAULT_TTL="${CACHE_DEFAULT_TTL:-300}"  # 5 minutes default TTL
readonly MAX_CACHE_SIZE="${CACHE_MAX_SIZE_LIMIT:-100}"  # Maximum number of cache entries

# Performance-optimized TTL values for different cache types
readonly TTL_VERSION_CHECK="${TTL_VERSION_CHECK:-600}"    # 10 minutes for version checks
readonly TTL_COMMAND_CHECK="${TTL_COMMAND_CHECK:-3600}"   # 1 hour for command existence
readonly TTL_FILE_CHECK="${TTL_FILE_CHECK:-60}"           # 1 minute for file checks
readonly TTL_THEME_CHECK="${TTL_THEME_CHECK:-1800}"       # 30 minutes for theme data

# Initialize cache variables if not set
: "${CACHE_ENABLED:=1}"
: "${CACHE_MAX_SIZE:=$MAX_CACHE_SIZE}"
: "${CACHE_ASYNC_CLEANUP:=true}"  # Enable background cleanup

# Initialize cache directory
init_cache_dir() {
    if [ ! -d "$CACHE_DIR" ]; then
        log_debug "Creating cache directory: $CACHE_DIR"
        mkdir -p "$CACHE_DIR" || {
            log_error "Failed to create cache directory"
            return 1
        }
    fi
    return 0
}

# List files in a directory sorted by modification time (oldest first).
# Portable replacement for 'find -printf \'%T+ %p\\n\'' which is GNU-only.
# Works on macOS (BSD stat -f) and Linux (GNU stat -c).
_find_files_by_mtime() {
    local dir="$1"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        find "$dir" -type f -exec stat -f '%m %N' {} \; 2>/dev/null | sort -n | cut -d' ' -f2-
    else
        find "$dir" -type f -exec stat -c '%Y %n' {} \; 2>/dev/null | sort -n | cut -d' ' -f2-
    fi
}

# Generate cache key from input
generate_cache_key() {
    local input="$1"
    echo "$input" | sha256sum 2>/dev/null | cut -d' ' -f1 || echo "$input" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "${input//[^a-zA-Z0-9]/_}"
}

# Check if cache entry is valid (not expired)
is_cache_valid() {
    local cache_file="$1"
    local ttl="${2:-$DEFAULT_TTL}"
    
    if [ ! -f "$cache_file" ]; then
        return 1
    fi
    
    local file_age
    local current_time
    
    # Get file modification time and current time
    if command -v stat >/dev/null 2>&1; then
        # Try GNU stat first, then BSD stat
        file_age=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
        current_time=$(date +%s)
    else
        log_debug "stat command not available, treating cache as invalid"
        return 1
    fi
    
    if [ -n "$file_age" ] && [ -n "$current_time" ]; then
        local age_diff=$((current_time - file_age))
        if [ "$age_diff" -le "$ttl" ]; then
            log_debug "Cache entry valid (age: ${age_diff}s, TTL: ${ttl}s)"
            return 0
        else
            log_debug "Cache entry expired (age: ${age_diff}s, TTL: ${ttl}s)"
            return 1
        fi
    else
        log_debug "Could not determine cache age, treating as invalid"
        return 1
    fi
}

# Store data in cache
cache_set() {
    local key="$1"
    local value="$2"
    local ttl="${3:-$DEFAULT_TTL}"
    
    init_cache_dir || return 1
    
    local cache_key
    cache_key=$(generate_cache_key "$key")
    local cache_file="$CACHE_DIR/$cache_key"
    
    log_debug "Storing cache entry: $key -> $cache_key"
    
    # Store the value with metadata
    {
        echo "# Cache entry for: $key"
        echo "# TTL: $ttl seconds"
        echo "# Created: $(date)"
        echo "$value"
    } > "$cache_file"
}

# Retrieve data from cache
cache_get() {
    local key="$1"
    local ttl="${2:-$DEFAULT_TTL}"
    
    local cache_key
    cache_key=$(generate_cache_key "$key")
    local cache_file="$CACHE_DIR/$cache_key"
    
    if is_cache_valid "$cache_file" "$ttl"; then
        log_debug "Cache hit for: $key"
        # Skip metadata lines and return the actual content
        tail -n +4 "$cache_file" 2>/dev/null
        return 0
    else
        log_debug "Cache miss for: $key"
        return 1
    fi
}

# Remove specific cache entry
cache_delete() {
    local key="$1"
    
    local cache_key
    cache_key=$(generate_cache_key "$key")
    local cache_file="$CACHE_DIR/$cache_key"
    
    if [ -f "$cache_file" ]; then
        log_debug "Deleting cache entry: $key"
        rm "$cache_file"
        return $?
    else
        log_debug "Cache entry not found for deletion: $key"
        return 1
    fi
}

# Clear all cache entries
cache_clear() {
    if [ -d "$CACHE_DIR" ]; then
        log_info "Clearing all cache entries"
        rm -f "$CACHE_DIR"/*
        return $?
    else
        log_debug "Cache directory does not exist"
        return 0
    fi
}

# Clean up expired cache entries
cache_cleanup() {
    local ttl="${1:-$DEFAULT_TTL}"
    
    if [ ! -d "$CACHE_DIR" ]; then
        log_debug "Cache directory does not exist, nothing to clean"
        return 0
    fi
    
    log_info "Cleaning up expired cache entries (TTL: ${ttl}s)"
    
    local cleaned_count=0
    
    for cache_file in "$CACHE_DIR"/*; do
        if [ -f "$cache_file" ]; then
            if ! is_cache_valid "$cache_file" "$ttl"; then
                log_debug "Removing expired cache file: $(basename "$cache_file")"
                rm "$cache_file"
                ((cleaned_count++))
            fi
        fi
    done
    
    log_info "Cache cleanup completed. Removed $cleaned_count expired entries"
    return 0
}

# Limit cache size by removing oldest entries
cache_limit_size() {
    local max_size="${1:-$MAX_CACHE_SIZE}"
    
    if [ ! -d "$CACHE_DIR" ]; then
        return 0
    fi
    
    local cache_count
    cache_count=$(find "$CACHE_DIR" -type f | wc -l)
    
    if [ "$cache_count" -le "$max_size" ]; then
        log_debug "Cache size ($cache_count) within limit ($max_size)"
        return 0
    fi
    
    log_info "Cache size ($cache_count) exceeds limit ($max_size), removing oldest entries"
    
    local excess_count=$((cache_count - max_size))
    
    # Remove oldest files (portable: _find_files_by_mtime sorts oldest-first)
    _find_files_by_mtime "$CACHE_DIR" | head -n "$excess_count" | while read -r cache_file; do
        log_debug "Removing old cache file: $(basename "$cache_file")"
        rm "$cache_file"
    done
    
    log_info "Cache size limit enforced. Removed $excess_count old entries"
}

# Cache dependency check results
cache_dependency_check() {
    local dependency="$1"
    local result="$2"
    local ttl="${3:-600}"  # 10 minutes for dependency checks
    
    cache_set "dependency_check_$dependency" "$result" "$ttl"
}

# Get cached dependency check result
get_cached_dependency_check() {
    local dependency="$1"
    local ttl="${2:-600}"
    
    cache_get "dependency_check_$dependency" "$ttl"
}

# Cache user preferences
cache_user_preference() {
    local preference_key="$1"
    local preference_value="$2"
    local ttl="${3:-86400}"  # 24 hours for user preferences
    
    cache_set "user_pref_$preference_key" "$preference_value" "$ttl"
}

# Get cached user preference
get_cached_user_preference() {
    local preference_key="$1"
    local ttl="${2:-86400}"
    
    cache_get "user_pref_$preference_key" "$ttl"
}

# Store setup state between script executions
cache_setup_state() {
    local state_key="$1"
    local state_value="$2"
    local ttl="${3:-3600}"  # 1 hour for setup state
    
    cache_set "setup_state_$state_key" "$state_value" "$ttl"
}

# Get cached setup state
get_cached_setup_state() {
    local state_key="$1"
    local ttl="${2:-3600}"
    
    cache_get "setup_state_$state_key" "$ttl"
}

# Setup cleanup on script exit
setup_cache_cleanup() {
    trap 'cache_cleanup; cache_limit_size' EXIT
}

# Export functions for use in other scripts
export -f init_cache_dir cache_set cache_get cache_delete cache_clear cache_cleanup
export -f cache_limit_size cache_dependency_check get_cached_dependency_check
export -f cache_user_preference get_cached_user_preference cache_setup_state
export -f get_cached_setup_state setup_cache_cleanup

# Initialize cache system
cache_init() {
    if [ "$CACHE_ENABLED" != "1" ]; then
        return 0
    fi
    
    # Create cache directory structure
    mkdir -p "$CACHE_DIR"/{version-managers,files,commands,themes,metadata}
    
    # Create cache metadata file if it doesn't exist
    local metadata_file="$CACHE_DIR/metadata/cache.meta"
    if [ ! -f "$metadata_file" ]; then
        echo "# Cache metadata - DO NOT EDIT MANUALLY" > "$metadata_file"
        echo "cache_version=1.0" >> "$metadata_file"
        echo "created=$(date +%s)" >> "$metadata_file"
    fi
    
    # Clean up old cache entries on init
    cache_cleanup_old
}

# Generate cache key from input parameters
cache_key() {
    local namespace="$1"
    local identifier="$2"
    local context="${3:-}"
    
    # Create a hash-like key from the inputs
    local key_base="${namespace}_${identifier}"
    if [ -n "$context" ]; then
        key_base="${key_base}_${context}"
    fi
    
    # Replace problematic characters for filesystem
    echo "$key_base" | tr '/' '_' | tr ' ' '_' | tr -d '()[]{}*?'
}

_cache_validate_namespace() {
    local namespace="$1"

    if [[ ! "$namespace" =~ ^[A-Za-z0-9_-]+$ ]]; then
        log_error "Invalid cache namespace: $namespace"
        return 1
    fi

    return 0
}

_cache_validate_cache_dir_for_delete() {
    if [ -z "$CACHE_DIR" ] || [ "$CACHE_DIR" = "/" ]; then
        log_error "Refusing to delete unsafe cache directory: ${CACHE_DIR:-<empty>}"
        return 1
    fi

    case "$CACHE_DIR" in
        "$HOME/.cache/version-management-setup"|"${XDG_CACHE_HOME:-}/version-management-setup")
            return 0
            ;;
        *)
            log_error "Refusing to delete unexpected cache directory: $CACHE_DIR"
            return 1
            ;;
    esac
}

# Check if cache entry is valid (not expired)
cache_is_valid() {
    local cache_file="$1"
    
    if [ "$CACHE_ENABLED" != "1" ] || [ ! -f "$cache_file" ]; then
        return 1
    fi
    
    local file_time
    if command -v stat >/dev/null 2>&1; then
        # Get file modification time
        if [[ "$OSTYPE" == "darwin"* ]]; then
            file_time=$(stat -f %m "$cache_file" 2>/dev/null)
        else
            file_time=$(stat -c %Y "$cache_file" 2>/dev/null)
        fi
    else
        return 1
    fi
    
    if [ -z "$file_time" ]; then
        return 1
    fi
    
    local current_time=$(date +%s)
    local age=$((current_time - file_time))
    
    local ttl_limit="${CACHE_TTL:-$DEFAULT_TTL}"
    if [ "$age" -le "$ttl_limit" ]; then
        return 0
    else
        return 1
    fi
}

# Get value from cache (namespaced variant)
cache_namespace_get() {
    local namespace="$1"
    local identifier="$2"
    local context="${3:-}"

    _cache_validate_namespace "$namespace" || return 1
    
    if [ "$CACHE_ENABLED" != "1" ]; then
        return 1
    fi
    
    local key=$(cache_key "$namespace" "$identifier" "$context")
    local cache_file="$CACHE_DIR/$namespace/$key.cache"
    
    if cache_is_valid "$cache_file"; then
        cat "$cache_file" 2>/dev/null
        return 0
    else
        # Remove invalid cache file
        rm -f "$cache_file" 2>/dev/null
        return 1
    fi
}

# Set value in cache (namespaced variant)
cache_namespace_set() {
    local namespace="$1"
    local identifier="$2"
    local value="$3"
    local context="${4:-}"

    _cache_validate_namespace "$namespace" || return 1
    
    if [ "$CACHE_ENABLED" != "1" ]; then
        return 0
    fi
    
    local key=$(cache_key "$namespace" "$identifier" "$context")
    local cache_dir="$CACHE_DIR/$namespace"
    local cache_file="$cache_dir/$key.cache"
    
    # Ensure namespace directory exists
    mkdir -p "$cache_dir"
    
    # Write value to cache file
    echo "$value" > "$cache_file" 2>/dev/null || return 1
    
    # Update access tracking
    echo "$(date +%s):$namespace:$identifier" >> "$CACHE_DIR/metadata/access.log" 2>/dev/null
    
    return 0
}

# Clear specific cache entry (namespaced variant)
cache_namespace_clear() {
    local namespace="$1"
    local identifier="${2:-}"
    local context="${3:-}"

    _cache_validate_namespace "$namespace" || return 1
    
    if [ -z "$identifier" ]; then
        # Clear entire namespace
        rm -rf "${CACHE_DIR:?}/${namespace:?}" 2>/dev/null
        mkdir -p "$CACHE_DIR/$namespace"
    else
        # Clear specific entry
        local key=$(cache_key "$namespace" "$identifier" "$context")
        local cache_file="$CACHE_DIR/$namespace/$key.cache"
        rm -f "$cache_file" 2>/dev/null
    fi
}

# Clear all cache (namespaced variant)
cache_namespace_clear_all() {
    if [ -d "$CACHE_DIR" ]; then
        _cache_validate_cache_dir_for_delete || return 1
        rm -rf "$CACHE_DIR"
        cache_init
    fi
}

# Clean up old cache entries
cache_cleanup_old() {
    if [ "$CACHE_ENABLED" != "1" ] || [ ! -d "$CACHE_DIR" ]; then
        return 0
    fi
    
    local current_time=$(date +%s)
    
    # Find and remove expired cache files
    find "$CACHE_DIR" -name "*.cache" -type f 2>/dev/null | while read -r cache_file; do
        if ! cache_is_valid "$cache_file"; then
            rm -f "$cache_file" 2>/dev/null
        fi
    done
    
    # Limit cache size by removing oldest entries if needed
    local cache_count=$(find "$CACHE_DIR" -name "*.cache" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$cache_count" -gt "$CACHE_MAX_SIZE" ]; then
        local excess=$((cache_count - CACHE_MAX_SIZE))
        find "$CACHE_DIR" -name "*.cache" -type f -exec ls -t {} + 2>/dev/null | tail -n "$excess" | xargs rm -f 2>/dev/null
    fi
}

# Cache pyenv versions output
cache_pyenv_versions() {
    local format="${1:-bare}"
    local cache_key="pyenv_versions_$format"
    
    # Try to get from cache first
    local cached_result
    if cached_result=$(cache_namespace_get "version-managers" "$cache_key"); then
        echo "$cached_result"
        return 0
    fi
    
    # Execute command and cache result
    local result
    if command -v pyenv >/dev/null 2>&1; then
        if [ "$format" = "bare" ]; then
            result=$(pyenv versions --bare 2>/dev/null)
        else
            result=$(pyenv versions 2>/dev/null)
        fi
        
        if [ $? -eq 0 ] && [ -n "$result" ]; then
            cache_namespace_set "version-managers" "$cache_key" "$result"
            echo "$result"
            return 0
        fi
    fi
    
    return 1
}

# Cache nvm list output
cache_nvm_list() {
    local cache_key="nvm_list"
    
    # Try to get from cache first
    local cached_result
    if cached_result=$(cache_namespace_get "version-managers" "$cache_key"); then
        echo "$cached_result"
        return 0
    fi
    
    # Execute command and cache result
    local result
    if [ -n "$NVM_DIR" ] && [ -s "$NVM_DIR/nvm.sh" ] && command -v nvm >/dev/null 2>&1; then
        result=$(nvm list 2>/dev/null)
        
        if [ $? -eq 0 ] && [ -n "$result" ]; then
            cache_namespace_set "version-managers" "$cache_key" "$result"
            echo "$result"
            return 0
        fi
    fi
    
    return 1
}

# Cache file contents
cache_file_content() {
    local file_path="$1"
    local file_name=$(basename "$file_path")
    local dir_hash=$(dirname "$file_path" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "default")
    local cache_key="${file_name}_${dir_hash}"
    
    # Check if file exists
    if [ ! -f "$file_path" ]; then
        return 1
    fi
    
    # Get file modification time for cache validation
    local file_mtime
    if [[ "$OSTYPE" == "darwin"* ]]; then
        file_mtime=$(stat -f %m "$file_path" 2>/dev/null)
    else
        file_mtime=$(stat -c %Y "$file_path" 2>/dev/null)
    fi
    
    # Try to get from cache first
    local cached_result
    local cache_file="$CACHE_DIR/files/$cache_key.cache"
    
    if [ -f "$cache_file" ]; then
        local cache_mtime
        if [[ "$OSTYPE" == "darwin"* ]]; then
            cache_mtime=$(stat -f %m "$cache_file" 2>/dev/null)
        else
            cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null)
        fi
        
        # Check if cache is newer than file
        if [ -n "$cache_mtime" ] && [ -n "$file_mtime" ] && [ "$cache_mtime" -ge "$file_mtime" ]; then
            if cached_result=$(cache_namespace_get "files" "$cache_key"); then
                echo "$cached_result"
                return 0
            fi
        fi
    fi
    
    # Read file and cache result
    local result
    if result=$(cat "$file_path" 2>/dev/null | tr -d '[:space:]'); then
        cache_namespace_set "files" "$cache_key" "$result"
        echo "$result"
        return 0
    fi
    
    return 1
}

# Cache command existence checks
cache_command_exists() {
    local command_name="$1"
    local cache_key="cmd_exists_$command_name"
    
    # Try to get from cache first
    local cached_result
    if cached_result=$(cache_namespace_get "commands" "$cache_key"); then
        [ "$cached_result" = "1" ]
        return $?
    fi
    
    # Check command existence and cache result
    local result="0"
    if command -v "$command_name" >/dev/null 2>&1; then
        result="1"
    fi
    
    cache_namespace_set "commands" "$cache_key" "$result"
    [ "$result" = "1" ]
    return $?
}

# Cache theme file listings
cache_theme_files() {
    local theme_dir="$1"
    local cache_key="theme_files_$(basename "$theme_dir")"
    
    # Try to get from cache first
    local cached_result
    if cached_result=$(cache_namespace_get "themes" "$cache_key"); then
        echo "$cached_result"
        return 0
    fi
    
    # List theme files and cache result
    local result
    if [ -d "$theme_dir" ]; then
        result=$(find "$theme_dir" -name "*.zsh" -type f 2>/dev/null | sort)
        
        if [ $? -eq 0 ]; then
            cache_namespace_set "themes" "$cache_key" "$result"
            echo "$result"
            return 0
        fi
    fi
    
    return 1
}

# Cache package.json parsing
cache_package_json() {
    local package_file="${1:-package.json}"
    local field="${2:-name}"
    local cache_key="package_json_${field}_$(basename "$(dirname "$package_file")")"
    
    # Check if file exists
    if [ ! -f "$package_file" ]; then
        return 1
    fi
    
    # Get file modification time for cache validation
    local file_mtime
    if [[ "$OSTYPE" == "darwin"* ]]; then
        file_mtime=$(stat -f %m "$package_file" 2>/dev/null)
    else
        file_mtime=$(stat -c %Y "$package_file" 2>/dev/null)
    fi
    
    # Try to get from cache first
    local cached_result
    local cache_file="$CACHE_DIR/files/$cache_key.cache"
    
    if [ -f "$cache_file" ]; then
        local cache_mtime
        if [[ "$OSTYPE" == "darwin"* ]]; then
            cache_mtime=$(stat -f %m "$cache_file" 2>/dev/null)
        else
            cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null)
        fi
        
        # Check if cache is newer than file
        if [ -n "$cache_mtime" ] && [ -n "$file_mtime" ] && [ "$cache_mtime" -ge "$file_mtime" ]; then
            if cached_result=$(cache_namespace_get "files" "$cache_key"); then
                echo "$cached_result"
                return 0
            fi
        fi
    fi
    
    # Parse package.json and cache result
    local result
    if command -v jq >/dev/null 2>&1; then
        result=$(jq -r ".$field // \"unknown\"" "$package_file" 2>/dev/null)
    else
        # Fallback parsing without jq
        case "$field" in
            "name")
                result=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$package_file" 2>/dev/null | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
                ;;
            "version")
                result=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$package_file" 2>/dev/null | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
                ;;
            *)
                result="unknown"
                ;;
        esac
    fi
    
    if [ -n "$result" ] && [ "$result" != "null" ]; then
        cache_set "files" "$cache_key" "$result"
        echo "$result"
        return 0
    fi
    
    return 1
}

# Cache backup file listings
cache_backup_files() {
    local backup_dir="$1"
    local cache_key="backup_files_$(basename "$backup_dir")"
    
    # Try to get from cache first
    local cached_result
    if cached_result=$(cache_namespace_get "themes" "$cache_key"); then
        echo "$cached_result"
        return 0
    fi
    
    # List backup files and cache result
    local result
    if [ -d "$backup_dir" ]; then
        result=$(ls -1t "$backup_dir"/.p10k_backup_*.zsh "$backup_dir"/.p10k_manual_backup_*.zsh 2>/dev/null | head -20)
        
        if [ $? -eq 0 ]; then
            cache_set "themes" "$cache_key" "$result"
            echo "$result"
            return 0
        fi
    fi
    
    return 1
}

# Get cache statistics
cache_stats() {
    local blue="${BLUE:-}"
    local cyan="${CYAN:-}"
    local yellow="${YELLOW:-}"
    local reset="${NC:-}"

    if [ "$CACHE_ENABLED" != "1" ]; then
        echo -e "${yellow}Cache is disabled${reset}"
        return 0
    fi
    
    if [ ! -d "$CACHE_DIR" ]; then
        echo -e "${yellow}Cache directory does not exist${reset}"
        return 0
    fi
    
    echo -e "${blue} Cache Statistics${reset}"
    echo "==================="
    
    # Count cache entries by namespace
    for namespace in version-managers files commands themes; do
        if [ -d "$CACHE_DIR/$namespace" ]; then
            local count=$(find "$CACHE_DIR/$namespace" -name "*.cache" -type f 2>/dev/null | wc -l | tr -d ' ')
            echo -e "${cyan}$namespace:${reset} $count entries"
        fi
    done
    
    # Total cache size
    local total_size
    if command -v du >/dev/null 2>&1; then
        total_size=$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)
        echo -e "${cyan}Total size:${reset} $total_size"
    fi
    
    # Cache hit rate (if access log exists)
    if [ -f "$CACHE_DIR/metadata/access.log" ]; then
        local total_accesses=$(wc -l < "$CACHE_DIR/metadata/access.log" 2>/dev/null || echo "0")
        echo -e "${cyan}Total accesses:${reset} $total_accesses"
    fi
    
    echo -e "${cyan}TTL:${reset} ${CACHE_TTL:-$DEFAULT_TTL}s"
    echo -e "${cyan}Max entries:${reset} $CACHE_MAX_SIZE"
}

# Invalidate cache for specific operations
cache_invalidate_version_managers() {
    cache_namespace_clear "version-managers"
}

cache_invalidate_files() {
    cache_namespace_clear "files"
}

cache_invalidate_themes() {
    cache_namespace_clear "themes"
}

# Execute argv and cache successful non-empty output.
cache_exec_argv() {
    local cache_key="$1"
    local ttl="$2"
    shift 2

    if [ -z "$cache_key" ]; then
        log_error "cache_exec_argv requires a cache key"
        return 1
    fi

    if [ "$#" -eq 0 ]; then
        log_error "cache_exec_argv requires a command"
        return 1
    fi

    local cached_result
    if cached_result=$(cache_get "$cache_key" "$ttl"); then
        echo "$cached_result"
        return 0
    fi

    local result
    result=$("$@" 2>/dev/null)
    local exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        return "$exit_code"
    fi

    if [ -n "$result" ]; then
        cache_set "$cache_key" "$result" "$ttl"
    fi

    echo "$result"
    return 0
}

# Safe argv execution with cache fallback
cache_safe_execute() {
    local cache_key="$1"
    local ttl="$2"
    shift 2

    cache_exec_argv "$cache_key" "$ttl" "$@"
}

# ============================================================================
# ALIASES FOR COMPATIBILITY
# ============================================================================
# lib/cache.sh has two naming layers (added at different times):
#   Layer 1 (flat):       generate_cache_key, is_cache_valid, cache_set/get/delete
#   Layer 2 (namespaced): cache_key, cache_is_valid, cache_namespace_*
# Both layers are fully implemented and exported.
# New code should prefer Layer 2 (namespaced) functions.
# Existing callers of Layer 1 functions continue to work without changes.

# Alias for scripts that call init_cache_system instead of cache_init
alias init_cache_system=cache_init

# Initialize cache on source
cache_init

# Export functions for use by other scripts
export -f cache_namespace_get cache_namespace_set cache_namespace_clear cache_namespace_clear_all cache_is_valid
export -f cache_pyenv_versions cache_nvm_list cache_file_content cache_command_exists
export -f cache_theme_files cache_package_json cache_backup_files
export -f cache_invalidate_version_managers cache_invalidate_files cache_invalidate_themes
export -f cache_exec_argv cache_safe_execute cache_stats cache_cleanup_old
