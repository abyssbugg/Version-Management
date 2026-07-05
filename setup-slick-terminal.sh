#!/usr/bin/env bash
# Enhanced Terminal Icon Setup - Get Official Nerd Font Icons Working
# Specifically optimized for VS Code integrated terminal

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logger.sh"

# Color definitions for beautiful output
TERM_BLUE='\033[0;34m'
TERM_GREEN='\033[0;32m'
TERM_YELLOW='\033[1;33m'
TERM_CYAN='\033[0;36m'
TERM_NC='\033[0m'

show_banner() {
    echo -e "${TERM_CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                 SLICK TERMINAL ICON SETUP                 ║"
    echo "║              Get Official Nerd Font Icons Working           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${TERM_NC}"
}

# Install fonts to system
install_fonts_to_system() {
    log_info "📥 Installing MesloLGS Nerd Font to system..."

    # Create fonts directory if it doesn't exist
    local fonts_dir="$HOME/Library/Fonts"
    mkdir -p "$fonts_dir"

    # Copy font files
    for font_file in "$SCRIPT_DIR"/*.ttf; do
        if [[ -f "$font_file" ]]; then
            cp "$font_file" "$fonts_dir/"
            log_success "Installed: $(basename "$font_file")"
        fi
    done

    # Refresh font cache
    if command -v fc-cache >/dev/null 2>&1; then
        fc-cache -f -v >/dev/null 2>&1
        log_success "Font cache refreshed"
    fi
}

# Configure VS Code settings for optimal font display
configure_vscode_fonts() {
    log_info " Configuring VS Code for optimal Nerd Font display..."

    # Generate optimized VS Code settings
    cat > "$SCRIPT_DIR/vscode-terminal-fonts.json" << 'EOF'
{
  "terminal.integrated.fontFamily": "MesloLGS NF",
  "terminal.integrated.fontSize": 14,
  "terminal.integrated.lineHeight": 1.2,
  "terminal.integrated.letterSpacing": 0,
  "terminal.integrated.fontWeight": "normal",
  "terminal.integrated.fontWeightBold": "bold",
  "terminal.integrated.allowChords": false,
  "terminal.integrated.cursorBlinking": true,
  "terminal.integrated.cursorStyle": "line",
  "terminal.integrated.drawBoldTextInBrightColors": false,
  "terminal.integrated.minimumContrastRatio": 4.5,
  "terminal.integrated.tabStopWidth": 4,
  "workbench.colorTheme": "Default Dark Modern",
  "editor.fontFamily": "MesloLGS NF, 'Courier New', monospace",
  "editor.fontSize": 14,
  "editor.fontLigatures": true,
  "debug.console.fontFamily": "MesloLGS NF"
}
EOF

    log_success "VS Code font configuration created: vscode-terminal-fonts.json"
    log_info " Copy these settings to your VS Code settings.json"
}

# Create font test script
create_font_test() {
    log_info " Creating font test script..."

    cat > "$SCRIPT_DIR/test-nerd-font-icons.sh" << 'EOF'
#!/usr/bin/env bash
# Test Nerd Font Icons Display

echo " Testing Nerd Font Icons Display..."
echo "=================================="
echo

echo " Directory Icons:"
echo "   Home:  "
echo "   Folder:  "
echo "   File:  "
echo

echo "🔀 Git Icons:"
echo "   Branch:  "
echo "   Modified:  "
echo "   Added:  "
echo "   Deleted:  "
echo "   Renamed:  "
echo "   Untracked:  "
echo

echo "⚙️  System Icons:"
echo "   Terminal:  "
echo "   Clock:  "
echo "   CPU:  "
echo "   Memory:  "
echo

echo " Language Icons:"
echo "   Node.js:  "
echo "   Python:  "
echo "   JavaScript:  "
echo "   TypeScript:  "
echo "   React:  "
echo "   Vue:  "
echo

echo " Status Icons:"
echo "   Success:  "
echo "   Error:  "
echo "   Warning:  "
echo "   Info:  "
echo

echo " Tool Icons:"
echo "   Settings:  "
echo "   Package:  "
echo "   Download:  "
echo "   Upload:  "
echo

echo "If you see proper icons above (not squares/question marks),"
echo "your Nerd Font is working correctly! "
EOF

    chmod +x "$SCRIPT_DIR/test-nerd-font-icons.sh"
    log_success "Font test script created: test-nerd-font-icons.sh"
}

# Main execution
main() {
    show_banner

    log_info "🎯 Setting up slick terminal with official Nerd Font icons..."
    echo

    install_fonts_to_system
    configure_vscode_fonts
    create_font_test

    echo
    log_success " Slick terminal setup completed!"
    echo
    log_info "📋 Next Steps:"
    echo "   1. Copy settings from vscode-terminal-fonts.json to your VS Code settings"
    echo "   2. Restart VS Code to apply font changes"
    echo "   3. Run ./test-nerd-font-icons.sh to verify icons are working"
    echo "   4. Open a new terminal to see your enhanced theme"
    echo
    log_info " Pro Tips:"
    echo "   • If icons don't show, restart VS Code completely"
    echo "   • Make sure MesloLGS NF is selected in terminal preferences"
    echo "   • Use scripts/theme-icon-manager.sh --customize for more options"
    echo
}

# Execute main function
main "$@"
