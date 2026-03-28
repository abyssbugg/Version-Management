#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# ============================================================================
# Common Utility Functions
# Part of Professional Development Terminal Setup
# ============================================================================
# Provides shared utility functions used across multiple scripts to reduce
# code duplication and ensure consistent behavior.
# ============================================================================

# Source logger if not already loaded
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f log_info >/dev/null 2>&1; then
    source "$SCRIPT_DIR/logger.sh" 2>/dev/null || {
        log_info() { echo "[INFO] $*"; }
        log_warn() { echo "[WARN] $*" >&2; }
        log_error() { echo "[ERROR] $*" >&2; }
        log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo "[DEBUG] $*"; }
    }
fi

# ============================================================================
# Command Detection
# ============================================================================

# Check if a command is available
# Usage: has_command "git"
# Returns: 0 if command exists, 1 if not
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# Check if multiple commands are available
# Usage: has_commands "git" "curl" "zsh"
# Returns: 0 if all commands exist, 1 if any missing
has_commands() {
    local missing=()
    for cmd in "$@"; do
        if ! has_command "$cmd"; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_debug "Missing commands: ${missing[*]}"
        return 1
    fi
    return 0
}

# Get the full path of a command
# Usage: get_command_path "git"
# Returns: Full path or empty string
get_command_path() {
    command -v "$1" 2>/dev/null || echo ""
}

# ============================================================================
# File and Directory Helpers
# ============================================================================

# Check if file exists
# Usage: file_exists "/path/to/file"
file_exists() {
    [[ -f "$1" ]]
}

# Check if directory exists
# Usage: dir_exists "/path/to/dir"
dir_exists() {
    [[ -d "$1" ]]
}

# Create directory if it doesn't exist
# Usage: ensure_dir "/path/to/dir"
ensure_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" && log_debug "Created directory: $dir"
    fi
}

# Create parent directory for a file path
# Usage: ensure_parent_dir "/path/to/file"
ensure_parent_dir() {
    local dir
    dir="$(dirname "$1")"
    ensure_dir "$dir"
}

# Safely read a file, return empty if not exists
# Usage: content=$(safe_read_file "/path/to/file")
safe_read_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cat "$file"
    fi
}

# ============================================================================
# String Helpers
# ============================================================================

# Trim whitespace from string
# Usage: result=$(trim "  hello  ")
trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

# Check if string is empty or only whitespace
# Usage: is_empty "  "
is_empty() {
    local trimmed
    trimmed="$(trim "$1")"
    [[ -z "$trimmed" ]]
}

# Check if string contains substring
# Usage: contains "hello world" "world"
contains() {
    local string="$1"
    local substring="$2"
    [[ "$string" == *"$substring"* ]]
}

# ============================================================================
# Version Helpers
# ============================================================================

# Compare semantic versions
# Usage: version_compare "1.2.3" "1.2.4"
# Returns: -1 if v1 < v2, 0 if equal, 1 if v1 > v2
version_compare() {
    local v1="$1"
    local v2="$2"
    
    if [[ "$v1" == "$v2" ]]; then
        echo 0
        return
    fi
    
    local IFS=.
    local i
    read -ra v1_parts <<< "$v1"
    read -ra v2_parts <<< "$v2"
    
    # Fill empty parts with zeros
    for ((i=${#v1_parts[@]}; i<${#v2_parts[@]}; i++)); do
        v1_parts[i]=0
    done
    for ((i=${#v2_parts[@]}; i<${#v1_parts[@]}; i++)); do
        v2_parts[i]=0
    done
    
    for ((i=0; i<${#v1_parts[@]}; i++)); do
        if ((10#${v1_parts[i]} > 10#${v2_parts[i]})); then
            echo 1
            return
        fi
        if ((10#${v1_parts[i]} < 10#${v2_parts[i]})); then
            echo -1
            return
        fi
    done
    
    echo 0
}

# Check if version meets minimum requirement
# Usage: version_meets_min "1.2.3" "1.2.0"
version_meets_min() {
    local version="$1"
    local min_version="$2"
    local result
    result=$(version_compare "$version" "$min_version")
    [[ "$result" -ge 0 ]]
}

# ============================================================================
# Platform Detection
# ============================================================================

# Get current OS type
# Returns: macos, linux, or wsl
get_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)
            if grep -q Microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

# Check if running on macOS
is_macos() {
    [[ "$(get_os)" == "macos" ]]
}

# Check if running on Linux
is_linux() {
    [[ "$(get_os)" == "linux" ]]
}

# Check if running in WSL
is_wsl() {
    [[ "$(get_os)" == "wsl" ]]
}

# ============================================================================
# Shell Detection
# ============================================================================

# Get current shell name
get_shell() {
    basename "${SHELL:-/bin/bash}"
}

# Check if running in zsh
is_zsh() {
    [[ "$(get_shell)" == "zsh" ]] || [[ -n "${ZSH_VERSION:-}" ]]
}

# Check if running in bash
is_bash() {
    [[ "$(get_shell)" == "bash" ]] || [[ -n "${BASH_VERSION:-}" ]]
}

# ============================================================================
# Environment Helpers
# ============================================================================

# Get environment variable with default
# Usage: value=$(get_env "VAR_NAME" "default")
get_env() {
    local var_name="$1"
    local default="${2:-}"
    echo "${!var_name:-$default}"
}

# Set environment variable if not already set
# Usage: set_env_default "VAR_NAME" "default_value"
set_env_default() {
    local var_name="$1"
    local default="$2"
    if [[ -z "${!var_name:-}" ]]; then
        export "$var_name"="$default"
    fi
}

# ============================================================================
# Network Helpers
# ============================================================================

# Check if we have internet connectivity
# Usage: has_internet
has_internet() {
    if has_command curl; then
        curl -s --max-time 3 --head https://github.com >/dev/null 2>&1
    elif has_command wget; then
        wget -q --timeout=3 --spider https://github.com 2>/dev/null
    else
        # Fall back to ping
        ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1
    fi
}

# ============================================================================
# Export Functions
# ============================================================================

export -f has_command has_commands get_command_path
export -f file_exists dir_exists ensure_dir ensure_parent_dir safe_read_file
export -f trim is_empty contains
export -f version_compare version_meets_min
export -f get_os is_macos is_linux is_wsl
export -f get_shell is_zsh is_bash
export -f get_env set_env_default
export -f has_internet
