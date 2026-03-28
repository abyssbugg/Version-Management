#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2086,SC2155,SC2005,SC2207,SC2016

# Enhanced Font Setup with Oh My Posh and Nerd Fonts Integration
# Provides multiple font installation methods for personal use

set -euo pipefail

# Source library utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/env.sh"

# Font installation methods menu
show_font_menu() {
    log_info "🔤 Nerd Font Installation Options"
    log_info "=================================="
    echo
    echo "Choose installation method:"
    echo "1) Install MesloLGS from local files (current method)"
    echo "2) Install via Oh My Posh CLI (if available)"
    echo "3) Install via Homebrew Cask"
    echo "4) Patch a custom font with Nerd Font glyphs"
    echo "5) Browse Nerd Fonts catalog"
    echo "6) Check current font installation"
    echo "7) Exit"
    echo
}

# Check if Oh My Posh is installed
check_oh_my_posh() {
    if command -v oh-my-posh >/dev/null 2>&1; then
        log_success " Oh My Posh CLI detected"
        return 0
    else
        log_warn " Oh My Posh CLI not found"
        log_info " Install with: brew install jandedobbeleer/oh-my-posh/oh-my-posh"
        return 1
    fi
}

# Install fonts using Oh My Posh CLI
install_with_oh_my_posh() {
    if check_oh_my_posh; then
        log_info " Launching Oh My Posh font installer..."
        log_info " Recommended: Select 'Meslo' for consistency with your setup"
        oh-my-posh font install
    else
        log_error "Oh My Posh CLI is required for this method"
        return 1
    fi
}

# Install fonts using Homebrew
install_with_homebrew() {
    if command -v brew >/dev/null 2>&1; then
        log_info "🍺 Available Nerd Fonts via Homebrew:"
        brew search nerd-font | head -20
        echo
        read -rp "Enter font name to install (e.g., font-meslo-lg-nerd-font): " font_name
        if [[ -n "$font_name" ]]; then
            brew install --cask "$font_name"
        fi
    else
        log_error "Homebrew is required for this method"
        return 1
    fi
}

# Install from local files (existing method)
install_local_fonts() {
    log_info " Installing MesloLGS NF from local files..."
    
    local font_files=(
        "MesloLGS NF Regular.ttf"
        "MesloLGS NF Bold.ttf"
        "MesloLGS NF Italic.ttf"
        "MesloLGS NF Bold Italic.ttf"
    )
    
    local installed=0
    for font in "${font_files[@]}"; do
        if [[ -f "$SCRIPT_DIR/$font" ]]; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                # macOS installation
                cp "$SCRIPT_DIR/$font" ~/Library/Fonts/
                log_success " Installed: $font"
                ((installed++))
            elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
                # Linux installation
                mkdir -p ~/.local/share/fonts
                cp "$SCRIPT_DIR/$font" ~/.local/share/fonts/
                ((installed++))
            fi
        else
            log_warn " Font file not found: $font"
        fi
    done
    
    if [[ $installed -gt 0 ]]; then
        if [[ "$OSTYPE" == "linux-gnu"* ]]; then
            fc-cache -f -v >/dev/null 2>&1 || true
        fi
        log_success " Installed $installed font files"
        log_info " Restart your terminal to use the new fonts"
    fi
}

# Check current font installation status
check_font_status() {
    log_info " Checking font installation status..."
    echo
    
    # Check for MesloLGS fonts
    if [[ "$OSTYPE" == "darwin"* ]]; then
        local font_dir=~/Library/Fonts
        log_info "Checking macOS font directory: $font_dir"
    else
        local font_dir=~/.local/share/fonts
        log_info "Checking Linux font directory: $font_dir"
    fi
    
    if ls "$font_dir"/MesloLGS*.ttf >/dev/null 2>&1; then
        log_success " MesloLGS NF fonts are installed:"
        ls -la "$font_dir"/MesloLGS*.ttf 2>/dev/null | awk '{print "   " $NF}'
    else
        log_warn " MesloLGS NF fonts not found in $font_dir"
    fi
    
    # Check if font is available to system
    if command -v fc-list >/dev/null 2>&1; then
        echo
        log_info "System font check:"
        if fc-list | grep -i "meslo" >/dev/null 2>&1; then
            log_success " Meslo fonts registered with system"
            fc-list | grep -i "meslo" | head -5
        else
            log_warn " Meslo fonts not found in system font cache"
        fi
    fi
    
    # Check VS Code settings
    echo
    if [[ -f "$SCRIPT_DIR/vscode-settings.json" ]]; then
        log_info "VS Code configuration:"
        if grep -q "MesloLGS" "$SCRIPT_DIR/vscode-settings.json"; then
            log_success " VS Code configured to use MesloLGS NF"
        else
            log_warn " VS Code not configured for MesloLGS NF"
        fi
    fi
}

# Browse Nerd Fonts catalog
browse_nerd_fonts() {
    log_info " Nerd Fonts Resources:"
    echo
    echo "  📖 Official Website: https://www.nerdfonts.com/"
    echo "  🐙 GitHub Repository: https://github.com/ryanoasis/nerd-fonts"
    echo "   Downloads: https://github.com/ryanoasis/nerd-fonts/releases"
    echo "  🔤 Font Previews: https://www.programmingfonts.org/"
    echo
    log_info " Popular fonts for development:"
    echo "  • MesloLGS NF (your current choice - excellent!)"
    echo "  • Hack Nerd Font"
    echo "  • Fira Code Nerd Font" 
    echo "  • JetBrains Mono Nerd Font"
    echo "  • Cascadia Code Nerd Font"
    echo
    log_info " To patch your own font:"
    echo "  Run: ./scripts/patch-font.sh <your-font.ttf>"
    echo "  (Uses the bundled Nerd Fonts font-patcher v3.4.0)"
}

# Patch a custom font with Nerd Font glyphs
patch_custom_font() {
    local patcher="$SCRIPT_DIR/scripts/patch-font.sh"

    if [[ ! -f "$patcher" ]]; then
        log_error "Font patcher script not found at: $patcher"
        return 1
    fi

    echo
    log_info "Patch any font with 9000+ Nerd Font glyphs"
    log_info "(Powerline, Devicons, Font Awesome, Material Design, etc.)"
    echo
    read -r -p "Enter path to your font file (TTF/OTF): " font_path
    font_path="${font_path/#\~/$HOME}"

    if [[ -z "$font_path" ]]; then
        log_warn "No file specified"
        return 1
    fi

    if [[ ! -f "$font_path" ]]; then
        log_error "File not found: $font_path"
        return 1
    fi

    echo
    read -r -p "Force monospace (single-width) glyphs? [y/N]: " mono_answer
    local mono_flag=""
    case "${mono_answer:-n}" in
        [Yy]*) mono_flag="--mono" ;;
    esac

    read -r -p "Install patched font automatically? [Y/n]: " install_answer
    local install_flag=""
    case "${install_answer:-y}" in
        [Yy]*) install_flag="--install" ;;
    esac

    echo
    bash "$patcher" $mono_flag $install_flag "$font_path"
}

# Main execution
main() {
    log_info " Enhanced Font Setup for Development Environment"
    log_info "================================================="
    echo
    
    while true; do
        show_font_menu
        read -r -p "Enter your choice (1-7): " choice
        echo
        
        case $choice in
            1)
                install_local_fonts
                ;;
            2)
                install_with_oh_my_posh
                ;;
            3)
                install_with_homebrew
                ;;
            4)
                patch_custom_font
                ;;
            5)
                browse_nerd_fonts
                ;;
            6)
                check_font_status
                ;;
            7)
                log_info "👋 Goodbye!"
                exit 0
                ;;
            *)
                log_warn "Invalid choice. Please enter 1-7."
                ;;
        esac
        
        echo
        log_info "Press Enter to continue..."
        read -r
        echo
    done
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
