#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034

# Terminal Configuration Diagnostic and Fix Script
# Diagnoses and fixes shell, P10k, and font configuration issues

set -euo pipefail

# Source library utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/env.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

# Configuration paths
ZSHRC="$HOME/.zshrc"
P10K_CONFIG="$HOME/.p10k.zsh"
PROJECT_P10K_CONFIG="${SCRIPT_DIR}/config/professional-dev-p10k.zsh"

# Main diagnostic function
run_terminal_diagnostics() {
    log_info " Running Terminal Configuration Diagnostics"
    log_info "=============================================="
    echo
    
    # Check current shell
    log_info "📋 Current Shell Information:"
    echo "  Default Shell: ${SHELL:-'Not set'}"
    echo "  Current Shell: ${0##*/}"
    echo "  Terminal: ${TERM:-'Not set'}"
    echo "  ZSH Version: $(zsh --version 2>/dev/null || echo 'Not available')"
    echo
    
    # Check fonts
    log_info "🔤 Font Configuration:"
    if fc-list | grep -c "MesloLGS" >/dev/null 2>&1; then
        log_success "MesloLGS Nerd Font is installed"
    else
        log_warn "MesloLGS Nerd Font not found in system fonts"
    fi
    echo
    
    # Check P10k configuration
    log_info " PowerLevel10k Configuration:"
    if [[ -f "$P10K_CONFIG" ]]; then
        log_success "P10k configuration file exists"
        if [[ -f "$PROJECT_P10K_CONFIG" ]]; then
            if diff "$P10K_CONFIG" "$PROJECT_P10K_CONFIG" >/dev/null 2>&1; then
                log_success "P10k config matches project configuration"
            else
                log_warn "P10k config differs from project configuration"
            fi
        fi
    else
        log_warn "P10k configuration file not found"
    fi
    echo
    
    # Check zsh configuration
    log_info "⚙️  ZSH Configuration:"
    if [[ -f "$ZSHRC" ]]; then
        if grep -q "powerlevel10k" "$ZSHRC"; then
            log_success "PowerLevel10k theme configured in .zshrc"
        else
            log_warn "PowerLevel10k theme not found in .zshrc"
        fi
        
        if grep -q "MesloLGS" "$ZSHRC"; then
            log_info "Font configuration found in .zshrc"
        else
            log_info "No specific font configuration in .zshrc"
        fi
    else
        log_warn ".zshrc file not found"
    fi
    echo
}

# Fix shell configuration
fix_shell_configuration() {
    log_info " Fixing Shell Configuration"
    log_info "=============================="
    echo
    
    # Change default shell to zsh if it's not already
    if [[ "$SHELL" != *"zsh"* ]]; then
        log_info "Setting default shell to zsh..."
        if command -v zsh >/dev/null 2>&1; then
            local zsh_path
            zsh_path=$(command -v zsh)
            
            # Add zsh to /etc/shells if not already there
            if ! grep -q "$zsh_path" /etc/shells 2>/dev/null; then
                log_info "Adding zsh to /etc/shells..."
                echo "$zsh_path" | sudo tee -a /etc/shells
            fi
            
            # Change shell
            chsh -s "$zsh_path"
            log_success "Default shell changed to zsh"
            log_info "📢 Please restart your terminal for changes to take effect"
        else
            log_error "zsh not found. Please install zsh first."
            return 1
        fi
    else
        log_success "Default shell is already zsh"
    fi
    echo
}

# Fix PowerLevel10k configuration
fix_p10k_configuration() {
    log_info " Fixing PowerLevel10k Configuration"
    log_info "====================================="
    echo
    
    if [[ -f "$PROJECT_P10K_CONFIG" ]]; then
        # Backup existing config
        if [[ -f "$P10K_CONFIG" ]]; then
            if ! create_backup "$P10K_CONFIG"; then
                log_error "Failed to backup existing P10k configuration"
                return 1
            fi
        fi
        
        # Copy project configuration
        cp "$PROJECT_P10K_CONFIG" "$P10K_CONFIG"
        log_success "Applied project PowerLevel10k configuration"
        
        # Ensure proper permissions
        chmod 644 "$P10K_CONFIG"
    else
        log_error "Project P10k configuration not found at: $PROJECT_P10K_CONFIG"
        return 1
    fi
    echo
}

# Install fonts
install_fonts() {
    log_info "🔤 Installing MesloLGS Nerd Fonts"
    log_info "================================="
    echo
    
    local font_dir
    if [[ "$OSTYPE" == "darwin"* ]]; then
        font_dir="$HOME/Library/Fonts"
    else
        font_dir="$HOME/.local/share/fonts"
        mkdir -p "$font_dir"
    fi
    
    local fonts_installed=0
    for font in "${SCRIPT_DIR}"/MesloLGS*.ttf; do
        if [[ -f "$font" ]]; then
            cp "$font" "$font_dir/"
            ((fonts_installed++))
        fi
    done
    
    if [[ $fonts_installed -gt 0 ]]; then
        log_success "Installed $fonts_installed MesloLGS font files"
        
        # Refresh font cache on Linux
        if [[ "$OSTYPE" != "darwin"* ]] && command -v fc-cache >/dev/null 2>&1; then
            fc-cache -f -v
        fi
    else
        log_warn "No MesloLGS font files found in project directory"
    fi
    echo
}

# Test configuration
test_configuration() {
    log_info " Testing Configuration"
    log_info "========================"
    echo
    
    # Test icons
    log_info "Icon Display Test:"
    echo "  Folder:   "
    echo "  Git:      "
    echo "  Node:     "
    echo "  Python:   "
    echo "  Success:  ✔"
    echo "  Error:    ✘"
    echo
    
    # Test P10k
    if command -v p10k >/dev/null 2>&1; then
        log_success "PowerLevel10k command available"
    else
        log_warn "PowerLevel10k command not found"
    fi
    
    # Test font
    if fc-list | grep -c "MesloLGS" >/dev/null 2>&1; then
        log_success "MesloLGS fonts are available"
    else
        log_warn "MesloLGS fonts not found"
    fi
    echo
}

# Show usage
show_usage() {
    cat << EOF
Terminal Configuration Diagnostic and Fix Tool

Usage: $0 [command]

Commands:
  diagnose    Run full diagnostic (default)
  fix-shell   Fix shell configuration
  fix-p10k    Fix PowerLevel10k configuration
  fix-fonts   Install MesloLGS fonts
  fix-all     Apply all fixes
  test        Test current configuration
  help        Show this help

Examples:
  $0              # Run diagnostics
  $0 fix-all      # Fix all issues
  $0 test         # Test configuration
EOF
}

# Main function
main() {
    local command="${1:-diagnose}"
    
    case "$command" in
        diagnose)
            run_terminal_diagnostics
            ;;
        fix-shell)
            fix_shell_configuration
            ;;
        fix-p10k)
            fix_p10k_configuration
            ;;
        fix-fonts)
            install_fonts
            ;;
        fix-all)
            log_info " Applying All Terminal Fixes"
            log_info "==============================="
            echo
            fix_shell_configuration
            fix_p10k_configuration
            install_fonts
            test_configuration
            log_success "All fixes applied!"
            log_info "📢 Please restart your terminal to see all changes"
            ;;
        test)
            test_configuration
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi