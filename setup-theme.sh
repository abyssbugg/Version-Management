#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2086,SC2155,SC2005,SC2207,SC2016

# Professional Terminal Setup - Theme Installation Script
# Installs PowerLevel10k configuration with professional theme

set -euo pipefail

# Source library utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/theme-ops.sh"
source "${SCRIPT_DIR}/lib/backup.sh"
source "${SCRIPT_DIR}/lib/lock.sh"

# Default theme
DEFAULT_THEME="professional"

# Usage information
usage() {
    log_info "Usage: $0 [theme]"
    log_info "  theme: Theme to install (default: $DEFAULT_THEME)"
    log_info ""
    log_info "Available themes:"
    log_info "  professional - Clean, professional PowerLevel10k configuration"
    exit 1
}

# Validate dependencies
validate_dependencies() {
    log_info " Validating dependencies..."
    
    # Check if zsh is available
    if ! command -v zsh >/dev/null 2>&1; then
        log_error "zsh is required but not installed"
        log_info "Please install zsh first: brew install zsh"
        return 1
    fi
    
    # Check if PowerLevel10k is installed
    local p10k_paths=(
        "$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
        "$HOME/.oh-my-zsh/themes/powerlevel10k"
        "/usr/local/share/powerlevel10k"
        "/opt/homebrew/share/powerlevel10k"
    )
    
    local p10k_found=false
    for path in "${p10k_paths[@]}"; do
        if [[ -d "$path" ]]; then
            p10k_found=true
            log_success "PowerLevel10k found at: $path"
            break
        fi
    done
    
    if [[ "$p10k_found" == "false" ]]; then
        log_error "PowerLevel10k not found in common locations"
        log_info "Please install PowerLevel10k first:"
        log_info "  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ~/.oh-my-zsh/custom/themes/powerlevel10k"
        return 1
    fi
    
    # Check for Nerd Font (basic check)
    log_info " Ensure you have a Nerd Font installed for proper icon display"
    log_info "   Recommended: MesloLGS NF (included in this project)"
    
    return 0
}

# Install theme configuration
install_theme_config() {
    local theme="$1"
    local config_file="${SCRIPT_DIR}/config/${theme}-dev-p10k.zsh"
    local target_file="$HOME/.p10k.zsh"
    
    log_info " Installing $theme theme configuration..."
    
    # Check if config file exists
    if [[ ! -f "$config_file" ]]; then
        log_error "Theme configuration not found: $config_file"
        return 1
    fi
    
    # Backup existing configuration
    if [[ -f "$target_file" ]]; then
        log_info " Backing up existing PowerLevel10k configuration..."
        if ! create_backup "$target_file"; then
            log_error "Failed to backup existing configuration"
            return 1
        fi
    fi
    
    # Copy new configuration
    log_info "📋 Installing new PowerLevel10k configuration..."
    if cp "$config_file" "$target_file"; then
        log_success "Theme configuration installed: $target_file"
    else
        log_error "Failed to install theme configuration"
        return 1
    fi
    
    return 0
}

# Verify zsh configuration
verify_zsh_config() {
    log_info " Verifying zsh configuration..."
    
    local zshrc="$HOME/.zshrc"
    
    if [[ ! -f "$zshrc" ]]; then
        log_error "$HOME/.zshrc not found"
        log_info "Please ensure zsh is properly configured"
        return 1
    fi
    
    # Check if PowerLevel10k is sourced
    if grep -q "powerlevel10k" "$zshrc" || grep -q "p10k" "$zshrc"; then
        log_success "PowerLevel10k appears to be configured in ~/.zshrc"
    else
        log_warn "PowerLevel10k may not be configured in ~/.zshrc"
        log_info "You may need to add PowerLevel10k to your zsh theme configuration"
    fi
    
    return 0
}

# Display post-installation instructions
show_post_install_instructions() {
    local theme="$1"
    
    log_info ""
    log_success " $theme theme installation completed!"
    log_info ""
    log_info "📋 Next steps:"
    log_info "1. Restart your terminal or run: source ~/.zshrc"
    log_info "2. Ensure your terminal uses a Nerd Font (MesloLGS NF recommended)"
    log_info "3. If icons don't display properly, check your font settings"
    log_info ""
    log_info " For VS Code integration:"
    log_info "   Import settings from: config/vscode-settings.json"
    log_info ""
}

# Main function
main() {
    local theme="${1:-$DEFAULT_THEME}"
    
    # Validate theme parameter
    case "$theme" in
        professional)
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown theme: $theme"
            usage
            ;;
    esac

    lock_with_trap "workstation-mutation" 30 || exit 1
    
    log_info " Installing $theme theme..."
    echo
    
    # Validate dependencies
    if ! validate_dependencies; then
        log_error "Dependency validation failed"
        exit 1
    fi
    
    # Create automatic restore point before making changes
    log_info "📍 Creating automatic restore point..."
    local restore_point_name="auto_before_theme_${theme}_$(date +%Y%m%d_%H%M%S)"
    local config_files=("$HOME/.p10k.zsh" "$HOME/.zshrc")
    if create_restore_point "$restore_point_name" "${config_files[@]}"; then
        log_debug "Restore point created: $restore_point_name"
    else
        log_warn "Could not create restore point, proceeding anyway..."
    fi
    
    # Install theme configuration (with transaction)
    transaction_start "theme_install_${theme}"
    transaction_add_file "$HOME/.p10k.zsh"
    
    if ! install_theme_config "$theme"; then
        log_error "Theme installation failed"
        transaction_rollback
        exit 1
    fi
    
    transaction_commit
    
    # Verify zsh configuration
    if ! verify_zsh_config; then
        log_warn "zsh configuration verification had warnings"
    fi
    
    # Show post-installation instructions
    show_post_install_instructions "$theme"
    
    exit 0
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
