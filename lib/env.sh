#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source paths; SC2034: intentionally exported vars

# Prevent re-sourcing
[[ -n "${_ENV_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_ENV_SH_LOADED=1

# =============================================================================
# Environment Setup Utilities for Version Management Setup
# =============================================================================
# Provides environment detection and setup functions for cross-platform compatibility
# 
# Functions:
#   - detect_shell        : Detect current shell (bash/zsh)
#   - detect_os           : Detect operating system platform
#   - validate_env_var    : Validate environment variable existence and value
#   - detect_nvm          : Check if nvm is installed and available
#   - detect_pyenv        : Check if pyenv is installed and available
#   - setup_path_mod      : Setup PATH modification utilities
#   - setup_nvm_silent    : Configure NVM_SILENT based on .nvmrc-config
#
# Usage:
#   source lib/env.sh
#   SHELL_TYPE=$(detect_shell)
#   OS_TYPE=$(detect_os)
#   if detect_nvm; then echo "NVM is available"; fi
# =============================================================================

set -euo pipefail

# Source logger if available
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/logger.sh" ]]; then
    # shellcheck source=lib/logger.sh
    source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"
else
    # Fallback logging functions if logger is not available
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1" >&2; }
    log_error() { echo "[ERROR] $1" >&2; }
    log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo "[DEBUG] $1"; }
fi

# =============================================================================
# Shell Detection Functions
# =============================================================================

# Detect the current shell being used
detect_shell() {
    local shell_name=""
    
    # Method 1: Check SHELL environment variable
    if [[ -n "${SHELL:-}" ]]; then
        shell_name=$(basename "$SHELL")
        log_debug "Shell detected from \$SHELL: $shell_name"
    fi
    
    # Method 2: Check process name if SHELL is not reliable
    if [[ -z "$shell_name" ]] || [[ "$shell_name" == "sh" ]]; then
        if command -v ps >/dev/null 2>&1; then
            local ps_shell
            ps_shell=$(ps -p $$ -o comm= 2>/dev/null | tr -d ' ')
            if [[ -n "$ps_shell" ]]; then
                shell_name="$ps_shell"
                log_debug "Shell detected from ps: $shell_name"
            fi
        fi
    fi
    
    # Method 3: Check ZSH_VERSION or BASH_VERSION
    if [[ -z "$shell_name" ]] || [[ "$shell_name" == "sh" ]]; then
        if [[ -n "${ZSH_VERSION:-}" ]]; then
            shell_name="zsh"
            log_debug "Shell detected from ZSH_VERSION"
        elif [[ -n "${BASH_VERSION:-}" ]]; then
            shell_name="bash"
            log_debug "Shell detected from BASH_VERSION"
        fi
    fi
    
    # Normalize shell name
    case "$shell_name" in
        *zsh*) echo "zsh" ;;
        *bash*) echo "bash" ;;
        *) 
            log_warn "Unknown shell detected: $shell_name, defaulting to bash"
            echo "bash"
            ;;
    esac
}

# =============================================================================
# Operating System Detection Functions
# =============================================================================

# Detect the operating system platform
detect_os() {
    local os_type=""
    
    if command -v uname >/dev/null 2>&1; then
        local uname_output
        uname_output=$(uname -s)
        
        case "$uname_output" in
            Darwin*)
                os_type="macos"
                log_debug "OS detected: macOS"
                ;;
            Linux*)
                os_type="linux"
                log_debug "OS detected: Linux"
                ;;
            CYGWIN*|MINGW*|MSYS*)
                os_type="windows"
                log_debug "OS detected: Windows (via $uname_output)"
                ;;
            *)
                os_type="unknown"
                log_warn "Unknown OS detected: $uname_output"
                ;;
        esac
    else
        log_error "uname command not available, cannot detect OS"
        os_type="unknown"
    fi
    
    echo "$os_type"
}

# =============================================================================
# Environment Variable Validation Functions
# =============================================================================

# Validate that an environment variable exists and optionally check its value
validate_env_var() {
    local var_name="$1"
    local expected_value="${2:-}"
    local allow_empty="${3:-false}"
    
    if [[ -z "$var_name" ]]; then
        log_error "validate_env_var: Variable name is required"
        return 1
    fi
    
    # Check if variable is set
    if [[ -z "${!var_name:-}" ]]; then
        if [[ "$allow_empty" == "true" ]]; then
            log_debug "Environment variable $var_name is empty (allowed)"
            return 0
        else
            log_error "Environment variable $var_name is not set or empty"
            return 1
        fi
    fi
    
    # Check expected value if provided
    if [[ -n "$expected_value" ]]; then
        if [[ "${!var_name}" == "$expected_value" ]]; then
            log_debug "Environment variable $var_name has expected value: $expected_value"
            return 0
        else
            log_error "Environment variable $var_name has value '${!var_name}', expected '$expected_value'"
            return 1
        fi
    fi
    
    log_debug "Environment variable $var_name is set: ${!var_name}"
    return 0
}

# =============================================================================
# Version Manager Detection Functions
# =============================================================================

# Check if nvm is installed and available
detect_nvm() {
    # Check if nvm command is available
    if command -v nvm >/dev/null 2>&1; then
        log_debug "NVM detected via command"
        return 0
    fi
    
    # Check if nvm function is loaded
    if declare -f nvm >/dev/null 2>&1; then
        log_debug "NVM detected as function"
        return 0
    fi
    
    # Check common nvm installation paths
    local nvm_paths=(
        "$HOME/.nvm/nvm.sh"
        "/usr/local/opt/nvm/nvm.sh"
        "/opt/homebrew/opt/nvm/nvm.sh"
    )
    
    for nvm_path in "${nvm_paths[@]}"; do
        if [[ -f "$nvm_path" ]]; then
            log_debug "NVM script found at: $nvm_path"
            return 0
        fi
    done
    
    log_debug "NVM not detected"
    return 1
}

# Check if pyenv is installed and available
detect_pyenv() {
    if command -v pyenv >/dev/null 2>&1; then
        log_debug "pyenv detected"
        return 0
    fi
    
    log_debug "pyenv not detected"
    return 1
}

# =============================================================================
# PATH Modification Functions
# =============================================================================

# Setup PATH modification utilities
setup_path_mod() {
    local new_path="$1"
    local position="${2:-prepend}"  # prepend or append
    
    if [[ -z "$new_path" ]]; then
        log_error "setup_path_mod: Path is required"
        return 1
    fi
    
    if [[ ! -d "$new_path" ]]; then
        log_warn "Path does not exist: $new_path"
        return 1
    fi
    
    # Check if path is already in PATH
    if [[ ":$PATH:" == *":$new_path:"* ]]; then
        log_debug "Path already in PATH: $new_path"
        return 0
    fi
    
    # Add to PATH
    case "$position" in
        prepend)
            export PATH="$new_path:$PATH"
            log_debug "Prepended to PATH: $new_path"
            ;;
        append)
            export PATH="$PATH:$new_path"
            log_debug "Appended to PATH: $new_path"
            ;;
        *)
            log_error "Invalid position: $position (use 'prepend' or 'append')"
            return 1
            ;;
    esac
    
    return 0
}

# =============================================================================
# NVM Silent Setup Functions
# =============================================================================

# Configure NVM_SILENT based on .nvmrc-config instructions
setup_nvm_silent() {
    local config_file="${1:-.nvmrc-config}"
    local enable_silent="${2:-true}"
    
    if [[ ! -f "$config_file" ]]; then
        log_warn "NVM config file not found: $config_file"
        return 1
    fi
    
    log_debug "Reading NVM configuration from: $config_file"
    
    if [[ "$enable_silent" == "true" ]]; then
        export NVM_SILENT=true
        log_info "NVM_SILENT enabled for quieter operation"
    else
        unset NVM_SILENT
        log_info "NVM_SILENT disabled for verbose operation"
    fi
    
    return 0
}

# =============================================================================
# Compatibility Wrapper Functions
# =============================================================================
#
# Some scripts in this project use legacy function names such as
# `check_nvm_installed`, `check_pyenv_installed` and
# `check_nvm_silent_configured`. These wrappers bridge the gap
# between those calls and the canonical detection helpers defined in
# nvm.sh and this env.sh. By providing them here we ensure
# backward‑compatibility without requiring all scripts to be updated.

# Check if Node Version Manager (nvm) is installed.
# Returns: 0 if available, 1 otherwise.
check_nvm_installed() {
    # If the nvm command exists in PATH, report success immediately.
    if command -v nvm >/dev/null 2>&1; then
        return 0
    fi
    # Try the dedicated nvm detection function from lib/nvm.sh if loaded.
    if declare -f nvm_detect >/dev/null 2>&1; then
        nvm_detect && return 0
    fi
    # Fall back to generic detection function from env.sh
    detect_nvm && return 0
    return 1
}

# Check if Python Version Manager (pyenv) is installed.
# Returns: 0 if available, 1 otherwise.
check_pyenv_installed() {
    # Prefer direct command detection to avoid unnecessary logging.
    if command -v pyenv >/dev/null 2>&1; then
        return 0
    fi
    # Fallback to env.sh detection helper.
    detect_pyenv
}

# Check if NVM silent mode has been configured in the user shell.
# Returns: 0 if NVM_SILENT is set (in environment or rc files), 1 otherwise.
check_nvm_silent_configured() {
    # If environment variable is set to a truthy value, treat as configured.
    if [[ "${NVM_SILENT:-}" == "true" || "${NVM_SILENT:-}" == "1" ]]; then
        return 0
    fi
    # Search common shell initialization files for NVM_SILENT declarations.
    local rc_files=("$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile")
    for rc_file in "${rc_files[@]}"; do
        if [[ -f "$rc_file" ]] && grep -q "NVM_SILENT" "$rc_file" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# =============================================================================
# Environment Summary Functions
# =============================================================================

# Display environment summary
show_env_summary() {
    local shell_type os_type
    
    shell_type=$(detect_shell)
    os_type=$(detect_os)
    
    log_info "Environment Summary:"
    log_info "  Shell: $shell_type"
    log_info "  OS: $os_type"
    log_info "  NVM: $(detect_nvm && echo "available" || echo "not available")"
    log_info "  pyenv: $(detect_pyenv && echo "available" || echo "not available")"
    log_info "  NVM_SILENT: ${NVM_SILENT:-not set}"
}

# Export functions for use in other scripts
export -f detect_shell detect_os validate_env_var detect_nvm detect_pyenv
export -f setup_path_mod setup_nvm_silent show_env_summary
export -f check_nvm_installed check_pyenv_installed check_nvm_silent_configured
