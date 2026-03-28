#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# ============================================================================
# Input Validation Module
# Part of Professional Development Terminal Setup
# ============================================================================
# Provides input validation functions for security and robustness.
# All public functions should validate their inputs using these helpers.
# ============================================================================

# Source logger if not already loaded
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f log_error >/dev/null 2>&1; then
    source "$SCRIPT_DIR/logger.sh" 2>/dev/null || {
        log_error() { echo "[ERROR] $*" >&2; }
        log_warn() { echo "[WARN] $*" >&2; }
        log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo "[DEBUG] $*"; }
    }
fi

# ============================================================================
# String Validation
# ============================================================================

# Validate string is not empty
# Usage: validate_not_empty "$var" "Variable name"
validate_not_empty() {
    local value="$1"
    local name="${2:-value}"
    
    if [[ -z "$value" ]]; then
        log_error "Validation failed: $name cannot be empty"
        return 1
    fi
    return 0
}

# Validate string matches regex pattern
# Usage: validate_pattern "$var" "^[a-z]+$" "must be lowercase letters"
validate_pattern() {
    local value="$1"
    local pattern="$2"
    local message="${3:-must match pattern $pattern}"
    
    if [[ ! "$value" =~ $pattern ]]; then
        log_error "Validation failed: '$value' $message"
        return 1
    fi
    return 0
}

# Validate string length is within bounds
# Usage: validate_length "$var" 1 255 "username"
validate_length() {
    local value="$1"
    local min="${2:-0}"
    local max="${3:-999999}"
    local name="${4:-value}"
    local len=${#value}
    
    if (( len < min )); then
        log_error "Validation failed: $name is too short (${len} < ${min})"
        return 1
    fi
    if (( len > max )); then
        log_error "Validation failed: $name is too long (${len} > ${max})"
        return 1
    fi
    return 0
}

# ============================================================================
# Version Validation
# ============================================================================

# Validate semantic version format (major.minor.patch)
# Usage: validate_semver "1.2.3"
validate_semver() {
    local version="$1"
    local strict="${2:-false}"
    
    if [[ "$strict" == "true" ]]; then
        # Strict: exactly major.minor.patch
        if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_error "Invalid version format: $version (expected major.minor.patch)"
            return 1
        fi
    else
        # Flexible: major, major.minor, or major.minor.patch
        if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)?(\.[0-9]+)?$ ]]; then
            log_error "Invalid version format: $version"
            return 1
        fi
    fi
    return 0
}

# Validate Node.js version format
# Usage: validate_node_version "20.10.0"
validate_node_version() {
    local version="$1"
    # Allow v prefix and various formats
    if [[ ! "$version" =~ ^v?[0-9]+(\.[0-9]+)?(\.[0-9]+)?$ ]]; then
        log_error "Invalid Node.js version: $version"
        return 1
    fi
    return 0
}

# Validate Python version format
# Usage: validate_python_version "3.12.0"
validate_python_version() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        log_error "Invalid Python version: $version"
        return 1
    fi
    return 0
}

# ============================================================================
# Path Validation
# ============================================================================

# Validate path contains no dangerous characters
# Usage: validate_safe_path "/home/user/file.txt"
validate_safe_path() {
    local path="$1"
    
    # Check for null bytes
    if [[ "$path" == *$'\0'* ]]; then
        log_error "Path contains null byte: potentially malicious"
        return 1
    fi
    
    # Check for path traversal attempts
    if [[ "$path" == *".."* ]]; then
        log_warn "Path contains '..': $path"
        # Not necessarily an error, but log for awareness
    fi
    
    # Check for shell metacharacters that could be dangerous
    if [[ "$path" =~ [\;\|\&\$\`] ]]; then
        log_error "Path contains shell metacharacters: potentially dangerous"
        return 1
    fi
    
    return 0
}

# Validate path is within allowed directory
# Usage: validate_path_within "$path" "/home/user"
validate_path_within() {
    local path="$1"
    local allowed_base="$2"
    
    # Resolve to absolute paths
    local abs_path abs_base
    abs_path="$(cd "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path")" || {
        log_error "Cannot resolve path: $path"
        return 1
    }
    abs_base="$(cd "$allowed_base" 2>/dev/null && pwd)" || {
        log_error "Cannot resolve base path: $allowed_base"
        return 1
    }
    
    if [[ "$abs_path" != "$abs_base"* ]]; then
        log_error "Path is outside allowed directory: $path"
        return 1
    fi
    return 0
}

# ============================================================================
# File Validation
# ============================================================================

# Validate file exists and is readable
# Usage: validate_file_readable "/path/to/file"
validate_file_readable() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file"
        return 1
    fi
    
    if [[ ! -r "$file" ]]; then
        log_error "File not readable: $file"
        return 1
    fi
    
    return 0
}

# Validate file is writable (or parent dir is writable for new files)
# Usage: validate_file_writable "/path/to/file"
validate_file_writable() {
    local file="$1"
    
    if [[ -f "$file" ]]; then
        if [[ ! -w "$file" ]]; then
            log_error "File not writable: $file"
            return 1
        fi
    else
        local dir
        dir="$(dirname "$file")"
        if [[ ! -d "$dir" ]]; then
            log_error "Parent directory does not exist: $dir"
            return 1
        fi
        if [[ ! -w "$dir" ]]; then
            log_error "Parent directory not writable: $dir"
            return 1
        fi
    fi
    
    return 0
}

# ============================================================================
# Numeric Validation
# ============================================================================

# Validate value is a positive integer
# Usage: validate_positive_int "$var" "port number"
validate_positive_int() {
    local value="$1"
    local name="${2:-value}"
    
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log_error "Invalid $name: must be a positive integer"
        return 1
    fi
    
    if (( value <= 0 )); then
        log_error "Invalid $name: must be greater than 0"
        return 1
    fi
    
    return 0
}

# Validate value is within numeric range
# Usage: validate_in_range "$var" 1 100 "percentage"
validate_in_range() {
    local value="$1"
    local min="$2"
    local max="$3"
    local name="${4:-value}"
    
    if [[ ! "$value" =~ ^-?[0-9]+$ ]]; then
        log_error "Invalid $name: must be a number"
        return 1
    fi
    
    if (( value < min || value > max )); then
        log_error "Invalid $name: must be between $min and $max"
        return 1
    fi
    
    return 0
}

# ============================================================================
# Selection Validation
# ============================================================================

# Validate value is one of allowed options
# Usage: validate_option "$choice" "yes" "no" "maybe"
validate_option() {
    local value="$1"
    shift
    local options=("$@")
    
    for opt in "${options[@]}"; do
        if [[ "$value" == "$opt" ]]; then
            return 0
        fi
    done
    
    log_error "Invalid option '$value'. Allowed: ${options[*]}"
    return 1
}

# ============================================================================
# Export Functions
# ============================================================================

export -f validate_not_empty validate_pattern validate_length
export -f validate_semver validate_node_version validate_python_version
export -f validate_safe_path validate_path_within
export -f validate_file_readable validate_file_writable
export -f validate_positive_int validate_in_range
export -f validate_option
