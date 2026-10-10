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
#   - VMS_LOG_RETENTION_DAYS : Age-based log rotation window in days (default 14).
#     init_logger prunes stale logs when it initializes a LOG_FILE; set to 0
#     (or any non-integer) to disable pruning.
#
# Stream contract (directive M4, finding B2.4): ALL human-facing log output
# (INFO/WARN/ERROR/SUCCESS/DEBUG) goes to STDERR. Value-returning functions
# own a clean stdout — a function that logs and echoes a value can be safely
# captured with command substitution and yields only the value. The only
# stdout-facing helper in this file is the private _get_timestamp, whose
# output is captured internally and never shown to the user.
# =============================================================================

# Contract (directive A2/M1): this file is SOURCED — it must not set global
# shell options; callers own their strict-mode posture. Argument validation
# and error propagation are explicit inside library functions.

# Color codes for terminal output. Each one is defined only when the caller
# has not defined it: `${VAR=default}` leaves a set (even deliberately
# EMPTY) variable alone, so a caller that disabled colors keeps them
# disabled, and a caller's own — possibly readonly — palette is never
# assigned to. Plain assignments, never readonly (AX-12): a sourced library
# must not freeze the caller's globals — scripts that define their own
# palette after sourcing (setup-wizard, system-diagnostics, analytics-report)
# died at startup with "GREEN: readonly variable", and sourcing the logger
# after a readonly partial palette (tools/preview-nerd-fonts.sh) died the
# same way.
: "${RED=\033[0;31m}"
: "${GREEN=\033[0;32m}"
: "${YELLOW=\033[1;33m}"
: "${BLUE=\033[0;34m}"
: "${NC=\033[0m}" # No Color

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
        formatted_message="${color}[$(_get_timestamp)] [$level]${NC:-\033[0m} $message"
    else
        formatted_message="[$(_get_timestamp)] [$level] $message"
    fi

    # Output to stderr (directive M4, finding B2.4): all human-facing log
    # levels go to stderr — value-returning functions own a clean stdout.
    echo -e "$formatted_message" >&2
}

# Public logging functions
log_info() {
    local message="$1"
    _log "INFO" "${GREEN:-}" "$message"
}

log_warn() {
    local message="$1"
    _log "WARN" "${YELLOW:-}" "$message"
}

log_error() {
    local message="$1"
    _log "ERROR" "${RED:-}" "$message"
}

# Log a success message (green). This helper mirrors log_info but labels the
# message as SUCCESS to clearly distinguish positive outcomes (e.g., after
# successfully installing a dependency). Many higher-level scripts call
# log_success, so defining it here prevents "command not found" errors.
log_success() {
    local message="$1"
    _log "SUCCESS" "${GREEN:-}" "$message"
}

log_debug() {
    local message="$1"

    # Only output debug messages when DEBUG is set to true
    if [[ "${DEBUG:-false}" == "true" ]]; then
        _log "DEBUG" "${BLUE:-}" "$message"
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

# Age-based log rotation (P2-5): prune stale logs when the logger initializes
# a LOG_FILE. Scope is deliberately narrow — only the configured log file and
# its rotated fragments ("<basename>.*") in the same directory are candidates;
# arbitrary sibling files are never touched. The window is VMS_LOG_RETENTION_DAYS
# (default 14 days); 0 or a non-integer disables pruning. This library owns no
# global shell options (M1): validation is explicit, failures are silent no-ops.
_logger_prune_old_logs() {
    local log_file="$1"

    [[ -n "$log_file" ]] || return 0

    local retention_days="${VMS_LOG_RETENTION_DAYS:-14}"
    if ! [[ "$retention_days" =~ ^[0-9]+$ ]] || (( retention_days == 0 )); then
        return 0
    fi

    local log_dir
    log_dir="$(dirname "$log_file")"
    [[ -d "$log_dir" ]] || return 0

    local base
    base="$(basename "$log_file")"
    # find -mtime +N selects files strictly older than N whole days; the -1
    # shift turns the retention window into that "older than the window" test.
    find "$log_dir" -maxdepth 1 -type f \
        \( -name "$base" -o -name "$base.*" \) \
        -mtime "+$((retention_days - 1))" -exec rm -f {} + 2>/dev/null
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

        # P2-5: drop logs beyond the retention window before appending, so a
        # fresh file starts below (stale content is discarded, not rotated in).
        _logger_prune_old_logs "$log_file"

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

# Export functions for use in other scripts. The private helpers are exported
# too (AX-13): an inherited log_* in a child bash otherwise fails with
# "_log: command not found". None of them contains a here-document (AX-7).
export -f log_info log_warn log_error log_success log_debug validate_logger init_logger
export -f _log _write_to_file _get_timestamp _supports_color _logger_prune_old_logs
