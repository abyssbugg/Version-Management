#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2086,SC2155,SC2005,SC2207,SC2016

# Professional Terminal Setup - Main Entry Point
# Interactive menu system for terminal theme and version manager setup

set -euo pipefail

# Source library utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/env.sh"
source "${SCRIPT_DIR}/lib/theme-ops.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

# Display banner
show_banner() {
    log_info " Professional Terminal Setup"
    log_info "================================"
    echo
}

# Display main menu
show_menu() {
    echo "Choose an option:"
    echo "1) Install & Apply Professional Theme"
    echo "2) Setup Version Managers Status"
    echo "3) Validate Current Setup"
    echo "4) Show Current Configuration"
    echo "5) Manage Nerd Fonts"
    echo "6) Fix Theme Icons (Replace Emojis)"
    echo "7) Customize Theme Icons"
    echo "8) Rollback / Restore Points"
    echo "9) Exit"
    echo
}

# Install and apply professional theme
install_theme() {
    log_info " Installing Professional Theme..."
    if "${SCRIPT_DIR}/setup-theme.sh" professional; then
        log_success "Professional theme installed successfully!"
    else
        log_error "Failed to install professional theme"
        return 1
    fi
}

# Setup version managers
setup_versions() {
    log_info "⚙️ Setting up Version Managers..."
    if "${SCRIPT_DIR}/setup-versions.sh" pro-status; then
        log_success "Version managers configured successfully!"
    else
        log_error "Failed to configure version managers"
        return 1
    fi
}

# Validate current setup
validate_setup() {
    log_info " Validating Current Setup..."
    if "${SCRIPT_DIR}/validate-setup.sh"; then
        log_success "Setup validation completed!"
    else
        log_error "Setup validation found issues"
        return 1
    fi
}

# Show current configuration
show_configuration() {
    log_info "📋 Current Configuration"
    log_info "========================"
    echo
    
    # Check PowerLevel10k
    if [[ -f "$HOME/.p10k.zsh" ]]; then
        log_info " PowerLevel10k configuration: ~/.p10k.zsh"
    else
        log_warn " PowerLevel10k configuration not found"
    fi
    
    # Check Node.js version
    if command -v node >/dev/null 2>&1; then
        local node_version
        node_version=$(node --version 2>/dev/null || echo "unknown")
        log_info " Node.js version: $node_version"
    else
        log_warn " Node.js not found"
    fi
    
    # Check Python version
    if command -v python3 >/dev/null 2>&1; then
        local python_version
        python_version=$(python3 --version 2>/dev/null || echo "unknown")
        log_info " Python version: $python_version"
    else
        log_warn " Python3 not found"
    fi
    
    # Check nvm
    if [[ -d "$HOME/.nvm" ]]; then
        log_info " NVM installed: ~/.nvm"
    else
        log_warn " NVM not found"
    fi
    
    # Check pyenv
    if command -v pyenv >/dev/null 2>&1; then
        log_info " pyenv available"
    else
        log_warn " pyenv not found"
    fi
    
    echo
}

# Manage fonts
manage_fonts() {
    log_info "🔤 Managing Nerd Fonts..."
    if [[ -x "${SCRIPT_DIR}/setup-fonts-enhanced.sh" ]]; then
        "${SCRIPT_DIR}/setup-fonts-enhanced.sh"
    else
        log_error "Font management script not found or not executable"
        return 1
    fi
}

# Fix theme icons (replace emojis with proper Nerd Font icons)
fix_theme_icons() {
    log_info " Fixing Theme Icons..."
    if [[ -x "${SCRIPT_DIR}/scripts/theme-icon-manager.sh" ]]; then
        "${SCRIPT_DIR}/scripts/theme-icon-manager.sh" --fix
    else
        log_error "Theme icon manager script not found or not executable"
        return 1
    fi
}

# Customize theme icons
customize_theme_icons() {
    log_info " Customizing Theme Icons..."
    if [[ -x "${SCRIPT_DIR}/scripts/theme-icon-manager.sh" ]]; then
        "${SCRIPT_DIR}/scripts/theme-icon-manager.sh" --customize
    else
        log_error "Theme icon manager script not found or not executable"
        return 1
    fi
}

# Rollback and restore point management
manage_rollback() {
    log_info " Rollback / Restore Points"
    log_info "============================"
    echo
    echo "Choose an option:"
    echo "1) List available restore points"
    echo "2) Create new restore point"
    echo "3) Restore from a restore point"
    echo "4) Delete a restore point"
    echo "5) Back to main menu"
    echo
    
    local choice
    read -r -p "Enter your choice (1-5): " choice
    
    case $choice in
        1)
            list_restore_points
            ;;
        2)
            echo
            read -r -p "Enter restore point name: " point_name
            if [[ -z "$point_name" ]]; then
                log_error "Name cannot be empty"
                return 1
            fi
            
            # Create restore point with common config files
            local config_files=(
                "$HOME/.zshrc"
                "$HOME/.p10k.zsh"
                "$HOME/.zsh_aliases"
            )
            create_restore_point "$point_name" "${config_files[@]}"
            ;;
        3)
            list_restore_points
            echo
            read -r -p "Enter restore point name to restore: " point_name
            if [[ -z "$point_name" ]]; then
                log_error "Name cannot be empty"
                return 1
            fi
            
            echo
            read -r -p "Are you sure you want to restore from '$point_name'? (y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                restore_from_point "$point_name"
            else
                log_info "Restore cancelled"
            fi
            ;;
        4)
            list_restore_points
            echo
            read -r -p "Enter restore point name to delete: " point_name
            if [[ -z "$point_name" ]]; then
                log_error "Name cannot be empty"
                return 1
            fi
            
            read -r -p "Are you sure you want to delete '$point_name'? (y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                delete_restore_point "$point_name"
            else
                log_info "Delete cancelled"
            fi
            ;;
        5)
            return 0
            ;;
        *)
            log_warn "Invalid choice"
            ;;
    esac
}

# Get user input with validation
get_user_choice() {
    local choice
    while true; do
        read -r -p "Enter your choice (1-9): " choice
        case $choice in
            [1-9])
                echo "$choice"
                return 0
                ;;
            *)
                log_warn "Invalid choice. Please enter 1-9."
                ;;
        esac
    done
}

# Main menu loop
main() {
    show_banner
    
    while true; do
        show_menu
        local choice
        choice=$(get_user_choice)
        echo
        
        case $choice in
            1)
                install_theme
                ;;
            2)
                setup_versions
                ;;
            3)
                validate_setup
                ;;
            4)
                show_configuration
                ;;
            5)
                manage_fonts
                ;;
            6)
                fix_theme_icons
                ;;
            7)
                customize_theme_icons
                ;;
            8)
                manage_rollback
                ;;
            9)
                log_info "👋 Goodbye!"
                exit 0
                ;;
        esac
        
        echo
        log_info "Press Enter to continue..."
        read -r
        echo
    done
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
