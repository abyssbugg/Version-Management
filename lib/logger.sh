#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source paths; SC2034: intentionally exported vars

# Prevent re-sourcing
[[ -n "${_LOGGER_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_LOGGER_SH_LOADED=1

# =============================================================================
# Centralized Logging Utility for Version Management Setup
# =============================================================================
# Provides standardized logging functions with color support and optional file logging
#
# Functions:
#   - log_info     : Information messages (green)
#   - log_warn     : Warning messages (yellow)
#   - log_error    : Error messages (red)
#   - log_success  : Success messages (green) to highlight positive outcomes
#   - log_debug    : Debug messages (only when DEBUG=true)
#
# Usage:
#   source lib/logger.sh
#   log_info "Setup completed successfully"
#   log_warn "Configuration file not found, using defaults"
#   log_error "Failed to install package"
#   DEBUG=true log_debug "Variable value: $var"
#
# Environment Variables:
#   - DEBUG       : Set to 'true' to enable debug logging
#   - LOG_FILE    : Optional file path for logging output
#   - NO_COLOR    : Set to disable color output
#   - SILENT_MODE : Set to 'true' to suppress all terminal output (file logging still occurs)
# =============================================================================

set -euo pipefail

# Color codes for terminal output (only declare if not already set)
if [[ -z "${BLUE:-}" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly NC='\033[0m' # No Color
fi

# Check if terminal supports colors
_supports_color() {
    [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1
}

# Get current timestamp
_get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Write to log file if LOG_FILE is set
_write_to_file() {
    local level="$1"
    local message="$2"
    
    if [[ -n "${LOG_FILE:-}" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
        echo "[$(_get_timestamp)] [$level] $message" >> "$LOG_FILE"
    fi
}

# Core logging function
_log() {
    local level="$1"
    local color="$2"
    local message="$3"

    # Write to file first (without colors, regardless of SILENT_MODE)
    _write_to_file "$level" "$message"

    # Suppress terminal output in silent mode
    if [[ "${SILENT_MODE:-false}" == "true" ]]; then
        return 0
    fi

    # Format message for terminal output
    local formatted_message
    if _supports_color; then
        formatted_message="${color}[$(_get_timestamp)] [$level]${NC} $message"
    else
        formatted_message="[$(_get_timestamp)] [$level] $message"
    fi

    # Output to appropriate stream
    if [[ "$level" == "ERROR" ]]; then
        echo -e "$formatted_message" >&2
    else
        echo -e "$formatted_message"
    fi
}

# Public logging functions
log_info() {
    local message="$1"
    _log "INFO" "$GREEN" "$message"
}

log_warn() {
    local message="$1"
    _log "WARN" "$YELLOW" "$message"
}

log_error() {
    local message="$1"
    _log "ERROR" "$RED" "$message"
}

# Log a success message (green). This helper mirrors log_info but labels the
# message as SUCCESS to clearly distinguish positive outcomes (e.g., after
# successfully installing a dependency). Many higher-level scripts call
# log_success, so defining it here prevents "command not found" errors.
log_success() {
    local message="$1"
    _log "SUCCESS" "$GREEN" "$message"
}

log_debug() {
    local message="$1"
    
    # Only output debug messages when DEBUG is set to true
    if [[ "${DEBUG:-false}" == "true" ]]; then
        _log "DEBUG" "$BLUE" "$message"
    fi
}

# Validation function to ensure logger is working
validate_logger() {
    log_info "Logger validation: INFO level working"
    log_warn "Logger validation: WARN level working"
    log_debug "Logger validation: DEBUG level working (only visible when DEBUG=true)"
    
    # Test file logging if LOG_FILE is set
    if [[ -n "${LOG_FILE:-}" ]]; then
        if [[ -w "$(dirname "$LOG_FILE")" ]]; then
            log_info "File logging enabled: $LOG_FILE"
        else
            log_error "Cannot write to log file directory: $(dirname "$LOG_FILE")"
            return 1
        fi
    fi
    
    return 0
}

# Initialize logger system
init_logger() {
    local log_file="${1:-}"
    local debug_mode="${2:-false}"
    
    # Set LOG_FILE if provided
    if [[ -n "$log_file" ]]; then
        export LOG_FILE="$log_file"
        
        # Create log file directory if it doesn't exist
        local log_dir
        log_dir="$(dirname "$log_file")"
        if [[ ! -d "$log_dir" ]]; then
            mkdir -p "$log_dir" || {
                log_error "Failed to create log directory: $log_dir"
                return 1
            }
        fi
        
        # Test write permissions
        if ! touch "$log_file" 2>/dev/null; then
            log_error "Cannot write to log file: $log_file"
            return 1
        fi
    fi
    
    # Set DEBUG mode if provided
    if [[ "$debug_mode" == "true" ]]; then
        export DEBUG="true"
    fi
    
    # Log initialization message
    log_info "Logger initialized successfully"
    if [[ -n "${LOG_FILE:-}" ]]; then
        log_info "File logging enabled: $LOG_FILE"
    fi
    if [[ "${DEBUG:-false}" == "true" ]]; then
        log_debug "Debug logging enabled"
    fi
    
    return 0
}

# Export functions for use in other scripts
export -f log_info log_warn log_error log_success log_debug validate_logger init_logger
