#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# ============================================================================
# Enhanced Error Handling System
# Part of Professional Development Terminal Setup
# ============================================================================
# Provides standardized error handling, retry logic, and cleanup management
# for use across all scripts in the suite.
# ============================================================================

# Source logger if available for consistent output
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/logger.sh" ]]; then
    source "$SCRIPT_DIR/logger.sh"
else
    # Fallback logging functions
    log_error() { echo "[ERROR] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_info() { echo "[INFO] $*"; }
    log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo "[DEBUG] $*"; }
fi

# Configuration
_ERROR_LOG_DIR="${HOME}/.cache/version-management-setup"
[[ -d "$_ERROR_LOG_DIR" ]] || mkdir -p "$_ERROR_LOG_DIR" 2>/dev/null || _ERROR_LOG_DIR="/tmp"
export ERROR_LOG="${ERROR_LOG:-${_ERROR_LOG_DIR}/setup-errors.log}"
export MAX_RETRIES="${MAX_RETRIES:-3}"
export RETRY_DELAY="${RETRY_DELAY:-2}"

# Track cleanup functions for graceful exit
declare -a _CLEANUP_FUNCTIONS=()

# ============================================================================
# Core Error Handler
# ============================================================================

# Handle errors with detailed logging
# Usage: trap 'handle_error $LINENO "$BASH_COMMAND"' ERR
# Args:
#   $1 - Line number where error occurred
#   $2 - Command that failed
handle_error() {
    local exit_code=$?
    local line_number="${1:-unknown}"
    local command="${2:-unknown command}"
    local script_name="${BASH_SOURCE[1]:-unknown}"
    
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local error_msg="[$timestamp] ERROR in $script_name at line $line_number - Command failed (exit $exit_code): $command"
    
    # Log to file
    echo "$error_msg" >> "$ERROR_LOG"
    
    # Output to stderr
    log_error "Command failed at line $line_number: $command (exit code: $exit_code)"
    
    return $exit_code
}

# ============================================================================
# Retry Logic
# ============================================================================

# Execute command with retry logic
# Usage: safe_exec "command" [max_retries] [retry_delay]
# Args:
#   $1 - Command to execute
#   $2 - Maximum retries (default: 3)
#   $3 - Delay between retries in seconds (default: 2)
safe_exec() {
    local command="$1"
    local max_retries="${2:-$MAX_RETRIES}"
    local retry_delay="${3:-$RETRY_DELAY}"
    local attempt=0

    # Guard: reject empty commands
    if [[ -z "$command" ]]; then
        log_error "safe_exec: command argument must not be empty"
        return 1
    fi
    # NOTE: eval is used here intentionally to support composite shell commands
    # (e.g., pipes, redirections). Callers MUST pass only trusted, controlled
    # command strings — never pass user-supplied input directly.

    while (( attempt < max_retries )); do
        if eval "$command"; then
            return 0
        fi

        attempt=$((attempt + 1))  # portable: avoids exit-1 from ((attempt++)) when attempt==0 under set -e
        log_warn "Command failed (attempt $attempt/$max_retries): $command"
        
        if (( attempt < max_retries )); then
            log_debug "Retrying in $retry_delay seconds..."
            sleep "$retry_delay"
        fi
    done
    
    log_error "Command failed after $max_retries attempts: $command"
    return 1
}

# Execute command with exponential backoff
# Usage: safe_exec_backoff "command" [max_retries] [initial_delay]
# Args:
#   $1 - Command to execute
#   $2 - Maximum retries (default: 5)
#   $3 - Initial delay in seconds (default: 1)
safe_exec_backoff() {
    local command="$1"
    local max_retries="${2:-5}"
    local delay="${3:-1}"
    local attempt=0

    # Guard: reject empty commands
    if [[ -z "$command" ]]; then
        log_error "safe_exec_backoff: command argument must not be empty"
        return 1
    fi
    # NOTE: eval is used here intentionally — see safe_exec() note above.
    # Only pass trusted, controlled command strings.

    while (( attempt < max_retries )); do
        if eval "$command"; then
            return 0
        fi

        attempt=$((attempt + 1))  # portable: avoids exit-1 from ((attempt++)) when attempt==0 under set -e
        log_warn "Command failed (attempt $attempt/$max_retries): $command"
        
        if (( attempt < max_retries )); then
            log_debug "Retrying in $delay seconds (exponential backoff)..."
            sleep "$delay"
            delay=$((delay * 2))  # Exponential backoff
        fi
    done
    
    log_error "Command failed after $max_retries attempts with backoff: $command"
    return 1
}

# ============================================================================
# Cleanup Management
# ============================================================================

# Register a cleanup function to be called on exit
# Usage: register_cleanup "cleanup_function_name"
register_cleanup() {
    local func="$1"
    _CLEANUP_FUNCTIONS+=("$func")
    log_debug "Registered cleanup function: $func"
}

# Run all registered cleanup functions
# Called automatically on exit if trap is set
run_cleanup() {
    local exit_code=$?
    log_debug "Running cleanup functions (exit code: $exit_code)"
    
    for func in "${_CLEANUP_FUNCTIONS[@]}"; do
        if declare -f "$func" >/dev/null 2>&1; then
            log_debug "Executing cleanup: $func"
            "$func" || log_warn "Cleanup function $func failed"
        fi
    done
    
    return $exit_code
}

# ============================================================================
# Validation Helpers
# ============================================================================

# Check if a command exists
# Usage: require_command "git" "Git is required for this operation"
require_command() {
    local cmd="$1"
    local message="${2:-Command '$cmd' is required but not found}"
    
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "$message"
        return 1
    fi
    return 0
}

# Check if a file exists
# Usage: require_file "/path/to/file" "Configuration file required"
require_file() {
    local file="$1"
    local message="${2:-Required file not found: $file}"
    
    if [[ ! -f "$file" ]]; then
        log_error "$message"
        return 1
    fi
    return 0
}

# Check if a directory exists
# Usage: require_dir "/path/to/dir" "Directory required"
require_dir() {
    local dir="$1"
    local message="${2:-Required directory not found: $dir}"
    
    if [[ ! -d "$dir" ]]; then
        log_error "$message"
        return 1
    fi
    return 0
}

# ============================================================================
# Error Trap Setup Helper
# ============================================================================

# Enable standard error trapping for a script
# Usage: Call at the beginning of your script after sourcing this file
setup_error_trap() {
    trap 'handle_error $LINENO "$BASH_COMMAND"' ERR
    trap 'run_cleanup' EXIT
    log_debug "Error trapping enabled"
}

# Export functions for use in sourcing scripts
export -f handle_error safe_exec safe_exec_backoff
export -f register_cleanup run_cleanup
export -f require_command require_file require_dir
export -f setup_error_trap
