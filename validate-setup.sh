#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2086,SC2155,SC2005,SC2207,SC2016

# Professional Terminal Setup - Setup Validation Script
# Comprehensive validation of entire setup using all library utilities

set -euo pipefail

# Source library utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/env.sh"
source "${SCRIPT_DIR}/lib/theme-ops.sh"
source "${SCRIPT_DIR}/lib/backup.sh"

# Validation results tracking
VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0

# Track validation result
track_result() {
    local result="$1"
    case "$result" in
        "error")
            ((VALIDATION_ERRORS++))
            ;;
        "warning")
            ((VALIDATION_WARNINGS++))
            ;;
    esac
}

# Validate PowerLevel10k installation
validate_powerlevel10k() {
    log_info " Validating PowerLevel10k Installation"
    log_info "======================================"
    
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
            log_success " PowerLevel10k found: $path"
            break
        fi
    done
    
    if [[ "$p10k_found" == "false" ]]; then
        log_error " PowerLevel10k not found in common locations"
        track_result "error"
        return 1
    fi
    
    # Check PowerLevel10k configuration
    if [[ -f "$HOME/.p10k.zsh" ]]; then
        log_success " PowerLevel10k configuration exists: ~/.p10k.zsh"
        
        # Check if it's our professional configuration
        if grep -q "Professional Terminal Setup" "$HOME/.p10k.zsh" 2>/dev/null; then
            log_success " Professional theme configuration detected"
        else
            log_warn "  Custom PowerLevel10k configuration (not professional theme)"
            track_result "warning"
        fi
    else
        log_error " PowerLevel10k configuration missing: ~/.p10k.zsh"
        track_result "error"
    fi
    
    # Check zsh configuration for PowerLevel10k
    if [[ -f "$HOME/.zshrc" ]]; then
        if grep -q "powerlevel10k" "$HOME/.zshrc" || grep -q "p10k" "$HOME/.zshrc"; then
            log_success " PowerLevel10k configured in ~/.zshrc"
        else
            log_error " PowerLevel10k not configured in ~/.zshrc"
            track_result "error"
        fi
    else
        log_error " ~/.zshrc not found"
        track_result "error"
    fi
    
    echo
}

# Validate Nerd Font availability
validate_nerd_font() {
    log_info "🔤 Validating Nerd Font Availability"
    log_info "==================================="
    
    # Check for MesloLGS NF files in project
    local font_files=(
        "MesloLGS NF Regular.ttf"
        "MesloLGS NF Bold.ttf"
        "MesloLGS NF Italic.ttf"
        "MesloLGS NF Bold Italic.ttf"
    )
    
    local fonts_found=0
    for font in "${font_files[@]}"; do
        if [[ -f "$font" ]]; then
            log_success " Font file available: $font"
            ((fonts_found++))
        else
            log_warn "  Font file missing: $font"
            track_result "warning"
        fi
    done
    
    if [[ $fonts_found -eq 4 ]]; then
        log_success " All MesloLGS NF font files available"
    elif [[ $fonts_found -gt 0 ]]; then
        log_warn "  Some MesloLGS NF font files missing"
        track_result "warning"
    else
        log_error " No MesloLGS NF font files found"
        track_result "error"
    fi
    
    # Basic font installation check (macOS)
    if command -v fc-list >/dev/null 2>&1; then
        if fc-list | grep -i "meslo" >/dev/null 2>&1; then
            log_success " Nerd Font appears to be installed (system)"
        else
            log_warn "  Nerd Font may not be installed (system)"
            track_result "warning"
        fi
    else
        log_info " Cannot verify system font installation (fc-list not available)"
    fi
    
    echo
}

# Validate zsh configuration
validate_zsh_config() {
    log_info "🐚 Validating Zsh Configuration"
    log_info "=============================="
    
    # Check if zsh is available
    if command -v zsh >/dev/null 2>&1; then
        log_success " zsh is available"
        local zsh_version
        zsh_version=$(zsh --version 2>/dev/null || echo "unknown")
        log_info " zsh version: $zsh_version"
    else
        log_error " zsh not found"
        track_result "error"
        return 1
    fi
    
    # Check if zsh is the default shell
    if [[ "$SHELL" == *"zsh"* ]]; then
        log_success " zsh is the default shell"
    else
        log_warn "  zsh is not the default shell: $SHELL"
        track_result "warning"
    fi
    
    # Check .zshrc
    if [[ -f "$HOME/.zshrc" ]]; then
        log_success " ~/.zshrc exists"
        
        # Check for Oh My Zsh
        if grep -q "oh-my-zsh" "$HOME/.zshrc" 2>/dev/null; then
            log_success " Oh My Zsh configuration detected"
        else
            log_info " Oh My Zsh not detected (manual zsh setup)"
        fi
    else
        log_error " ~/.zshrc not found"
        track_result "error"
    fi
    
    echo
}

# Validate NVM functionality
validate_nvm() {
    log_info " Validating NVM Functionality"
    log_info "==============================="
    
    if check_nvm_installed; then
        log_success " NVM is installed"
        
        # Check .nvmrc
        if [[ -f ".nvmrc" ]]; then
            local nvmrc_version
            nvmrc_version=$(cat .nvmrc)
            log_success " .nvmrc exists with version: v$nvmrc_version"
            
            # Check if Node.js is available
            if command -v node >/dev/null 2>&1; then
                local current_node
                current_node=$(node --version 2>/dev/null | sed 's/^v//')
                log_success " Node.js is available: v$current_node"
                
                # Check version match
                if [[ "$current_node" == "$nvmrc_version" ]]; then
                    log_success " Node.js version matches .nvmrc"
                else
                    log_warn "  Node.js version mismatch (current: v$current_node, expected: v$nvmrc_version)"
                    track_result "warning"
                fi
            else
                log_error " Node.js not available"
                track_result "error"
            fi
        else
            log_warn "  .nvmrc not found"
            track_result "warning"
        fi
        
        # Check NVM silent configuration
        if check_nvm_silent_configured; then
            log_success " NVM silent mode configured"
        else
            log_warn "  NVM verbose mode (consider configuring silent mode)"
            track_result "warning"
        fi
    else
        log_error " NVM not installed"
        track_result "error"
    fi
    
    echo
}

# Validate pyenv functionality
validate_pyenv() {
    log_info "🐍 Validating pyenv Functionality"
    log_info "================================="
    
    if check_pyenv_installed; then
        log_success " pyenv is installed"
        
        # Check .python-version
        if [[ -f ".python-version" ]]; then
            local python_version
            python_version=$(cat .python-version)
            log_success " .python-version exists with version: $python_version"
            
            # Check if Python is available
            if command -v python3 >/dev/null 2>&1; then
                local current_python
                current_python=$(python3 --version 2>/dev/null)
                log_success " Python3 is available: $current_python"
                
                # Check pyenv version
                if command -v pyenv >/dev/null 2>&1; then
                    local pyenv_version
                    pyenv_version=$(pyenv version 2>/dev/null | cut -d' ' -f1)
                    if [[ "$pyenv_version" == "$python_version" ]]; then
                        log_success " pyenv version matches .python-version"
                    else
                        log_warn "  pyenv version mismatch (current: $pyenv_version, expected: $python_version)"
                        track_result "warning"
                    fi
                fi
            else
                log_error " Python3 not available"
                track_result "error"
            fi
        else
            log_warn "  .python-version not found"
            track_result "warning"
        fi
    else
        log_error " pyenv not installed"
        track_result "error"
    fi
    
    echo
}

# Validate theme display correctness
validate_theme_display() {
    log_info "🎭 Validating Theme Display"
    log_info "==========================="
    
    # Check terminal capabilities
    if [[ -n "${TERM:-}" ]]; then
        log_success " TERM environment variable set: $TERM"
        
        # Check color support
        if [[ "$TERM" == *"256color"* ]] || [[ "$TERM" == *"truecolor"* ]]; then
            log_success " Terminal supports colors"
        else
            log_warn "  Terminal may have limited color support"
            track_result "warning"
        fi
    else
        log_warn "  TERM environment variable not set"
        track_result "warning"
    fi
    
    # Check locale settings
    if [[ -n "${LC_ALL:-}" ]] || [[ -n "${LANG:-}" ]]; then
        local locale="${LC_ALL:-${LANG:-}}"
        log_success " Locale set: $locale"
        
        if [[ "$locale" == *"UTF-8"* ]]; then
            log_success " UTF-8 encoding supported"
        else
            log_warn "  UTF-8 encoding may not be supported"
            track_result "warning"
        fi
    else
        log_warn "  Locale not properly configured"
        track_result "warning"
    fi
    
    # Test basic Unicode support
    log_info " Unicode test: ✓ ✗ ⚠   🐍"
    log_info " If you see boxes or question marks, check your font configuration"
    
    echo
}

# Display validation summary
show_validation_summary() {
    log_info " Validation Summary"
    log_info "===================="
    
    if [[ $VALIDATION_ERRORS -eq 0 ]] && [[ $VALIDATION_WARNINGS -eq 0 ]]; then
        log_success " Perfect! All validations passed successfully!"
        log_info "Your professional terminal setup is fully configured and ready to use."
    elif [[ $VALIDATION_ERRORS -eq 0 ]]; then
        log_success " Setup is functional with $VALIDATION_WARNINGS warning(s)"
        log_info "Your setup works but could be improved. Check warnings above."
    else
        log_error " Setup has $VALIDATION_ERRORS error(s) and $VALIDATION_WARNINGS warning(s)"
        log_info "Please address the errors above for full functionality."
    fi
    
    echo
    log_info " For help with any issues:"
    log_info "   • Check the README.md for troubleshooting tips"
    log_info "   • Run individual setup scripts to fix specific issues"
    log_info "   • Ensure all dependencies are properly installed"
    echo
}

# Main function
main() {
    log_info " Professional Terminal Setup Validation"
    log_info "=========================================="
    echo
    
    # Run all validations
    validate_powerlevel10k
    validate_nerd_font
    validate_zsh_config
    validate_nvm
    validate_pyenv
    validate_theme_display
    
    # Show summary
    show_validation_summary
    
    # Exit with appropriate code
    if [[ $VALIDATION_ERRORS -eq 0 ]]; then
        exit 0
    else
        exit 1
    fi
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
