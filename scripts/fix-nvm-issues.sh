#!/usr/bin/env bash
# Consolidated NVM Issue Fix Script
# Combines: fix-nvm-silent.sh, fix-nvm-verbose.sh, silence-nvm-permanently.sh

# Only set strict mode when executing directly (not when sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
fi

# Get script directory - handle both sourced and direct execution
if [[ -n "${SCRIPT_DIR:-}" ]]; then
    # Already set by sourcing script
    :
elif [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    # Being sourced, try to find lib relative to this file
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Source logger if available and not already sourced
if ! declare -f log_info >/dev/null 2>&1; then
    if [[ -f "${SCRIPT_DIR}/lib/logger.sh" ]]; then
        source "${SCRIPT_DIR}/lib/logger.sh"
    else
        # Fallback minimal logging if logger not available
        log_info() { echo "[INFO] $*"; }
        log_success() { echo "[SUCCESS] $*"; }
        log_warn() { echo "[WARN] $*" >&2; }
        log_error() { echo "[ERROR] $*" >&2; }
    fi
fi

show_usage() {
    echo "Usage: $0 [OPTION]"
    echo "Fix various NVM-related issues"
    echo
    echo "Options:"
    echo "  --silent     Enable silent mode (reduce verbose output)"
    echo "  --verbose    Fix verbose output issues"
    echo "  --permanent  Permanently silence NVM directory messages"
    echo "  --all        Apply all fixes"
    echo "  --help       Show this help message"
}

fix_silent_mode() {
    log_info "🔇 Configuring NVM silent mode..."
    local zshrc="$HOME/.zshrc"

    if [[ -f "$zshrc" ]]; then
        if ! grep -q "export NVM_SILENT=1" "$zshrc"; then
            echo "export NVM_SILENT=1" >> "$zshrc"
            log_success "NVM silent mode enabled"
            return 0
        else
            log_info "NVM silent mode already configured"
            return 0
        fi
    else
        log_warn "$HOME/.zshrc not found"
        return 1
    fi
}

fix_verbose_issues() {
    log_info " Fixing NVM verbose output issues..."
    local zshrc="$HOME/.zshrc"

    if [[ ! -f "$zshrc" ]]; then
        log_warn "$HOME/.zshrc not found"
        return 1
    fi

    # Add NVM_SILENT=true to suppress verbose messages
    if ! grep -q "NVM_SILENT=true" "$zshrc"; then
        {
            echo ""
            echo "# Silence NVM verbose messages"
            echo "export NVM_SILENT=true"
        } >> "$zshrc"
    fi

    # Add function to suppress 'Now using node' messages
    if ! grep -q "nvm_auto_use_silent" "$zshrc"; then
        {
            echo ""
            echo "# Silent auto-use for nvm"
            echo "nvm_auto_use_silent() {"
            echo "    if [[ -f .nvmrc ]]; then"
            echo "        nvm use >/dev/null 2>&1"
            echo "    fi"
            echo "}"
        } >> "$zshrc"
    fi

    log_success "Verbose issues fixed"
    return 0
}

permanent_silence() {
    log_info "🔕 Permanently silencing NVM directory messages..."
    local zshrc="$HOME/.zshrc"

    if [[ ! -f "$zshrc" ]]; then
        log_warn "$HOME/.zshrc not found"
        return 1
    fi

    # Create wrapper function that silences all NVM output
    if ! grep -q "# NVM Permanent Silence Configuration" "$zshrc"; then
        {
            echo ""
            echo "# NVM Permanent Silence Configuration"
            echo "export NVM_SILENT=true"
            echo "export NVM_DIR=\"\${NVM_DIR:-\$HOME/.nvm}\""
            echo ""
            echo "# Silent NVM loader"
            echo "[ -s \"\$NVM_DIR/nvm.sh\" ] && \\. \"\$NVM_DIR/nvm.sh\" --no-use >/dev/null 2>&1"
            echo ""
            echo "# Auto-switch node version silently when entering directories"
            echo "autoload -U add-zsh-hook 2>/dev/null"
            echo "load-nvmrc() {"
            echo "    local node_version=\"\$(nvm version 2>/dev/null)\""
            echo "    local nvmrc_path=\"\$(nvm_find_nvmrc 2>/dev/null)\""
            echo "    if [ -n \"\$nvmrc_path\" ]; then"
            echo "        local nvmrc_node_version=\$(nvm version \"\$(cat \"\${nvmrc_path}\")\" 2>/dev/null)"
            echo "        if [ \"\$nvmrc_node_version\" = \"N/A\" ]; then"
            echo "            nvm install >/dev/null 2>&1"
            echo "        elif [ \"\$nvmrc_node_version\" != \"\$node_version\" ]; then"
            echo "            nvm use >/dev/null 2>&1"
            echo "        fi"
            echo "    fi"
            echo "}"
            echo "add-zsh-hook chpwd load-nvmrc 2>/dev/null"
            echo "load-nvmrc"
        } >> "$zshrc"
    fi

    log_success "NVM permanently silenced"
    return 0
}

# Main function that applies all fixes (for testing and programmatic use)
fix_nvm_issues() {
    log_info " Running all NVM fixes..."
    local success=true

    fix_silent_mode || success=false
    fix_verbose_issues || success=false
    permanent_silence || success=false

    if [[ "$success" == "true" ]]; then
        log_success "All NVM fixes applied successfully"
        return 0
    else
        log_warn "Some NVM fixes may not have been applied"
        return 1
    fi
}

# Main execution - only run when script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --silent)    fix_silent_mode ;;
        --verbose)   fix_verbose_issues ;;
        --permanent) permanent_silence ;;
        --all)       fix_nvm_issues ;;
        --help)      show_usage ;;
        *)           show_usage; exit 1 ;;
    esac
fi
