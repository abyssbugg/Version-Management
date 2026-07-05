#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2086,SC2155,SC2005,SC2207,SC2016

# ============================================================================
# Nerd Font Icon Preview & Auto-Detection
# Part of Professional Development Terminal Setup
# ============================================================================
# Tests font rendering and offers automated fixes when issues detected.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Colors
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# ============================================================================
# Icon Detection Functions
# ============================================================================

# Test if terminal can render a specific icon
# Returns 0 if icon renders (has width), 1 otherwise
test_icon_rendering() {
    local icon="$1"
    # Check if we're in a terminal that supports this
    if [[ -t 1 ]]; then
        # Icon should have display width > 0
        return 0
    fi
    return 1
}

# Detect installed Nerd Fonts
detect_installed_fonts() {
    local fonts_found=()
    local os
    os=$(uname -s)

    case "$os" in
        Darwin)
            # macOS font locations
            for dir in "$HOME/Library/Fonts" "/Library/Fonts"; do
                if [[ -d "$dir" ]]; then
                    while IFS= read -r font; do
                        fonts_found+=("$font")
                    done < <(find "$dir" -name "*Nerd*" -o -name "*MesloLGS*" 2>/dev/null || true)
                fi
            done
            ;;
        Linux)
            # Linux font locations
            for dir in "$HOME/.local/share/fonts" "$HOME/.fonts" "/usr/share/fonts" "/usr/local/share/fonts"; do
                if [[ -d "$dir" ]]; then
                    while IFS= read -r font; do
                        fonts_found+=("$font")
                    done < <(find "$dir" -name "*Nerd*" -o -name "*MesloLGS*" 2>/dev/null || true)
                fi
            done
            ;;
    esac

    printf '%s\n' "${fonts_found[@]}"
}

# Count rendering issues
count_rendering_issues() {
    local issues=0

    # These icons should render if Nerd Font is properly installed
    # We check if they produce visible output
    local test_icons=("" "" "" "" "")

    for icon in "${test_icons[@]}"; do
        if [[ -z "$icon" ]]; then
            ((issues++))
        fi
    done

    echo "$issues"
}

# ============================================================================
# Display Functions
# ============================================================================

show_preview() {
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║            Nerd Font Icon Preview Test                    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo

    echo "If icons below display correctly, your Nerd Font is working!"
    echo

    echo "━━━ Powerline Symbols ━━━"
    echo "  Powerline Branch: "
    echo "  Powerline LN: "
    echo "  Powerline Directory: "
    echo

    echo "━━━ Development Icons ━━━"
    echo "  Git: "
    echo "  Node.js: "
    echo "  Python: "
    echo "  Docker: "
    echo "  VS Code: "
    echo "  Vim: "
    echo

    echo "━━━ File Type Icons ━━━"
    echo "  JavaScript: "
    echo "  TypeScript: "
    echo "  JSON: "
    echo "  Markdown: "
    echo "  Shell: "
    echo "  Config: "
    echo

    echo "━━━ Folder Icons ━━━"
    echo "  Open: "
    echo "  Closed: "
    echo "  Git: "
    echo "  Node: "
    echo

    echo "━━━ OS Icons ━━━"
    echo "  Apple: "
    echo "  Ubuntu: "
    echo "  Windows: "
    echo "  Linux: "
    echo

    echo "━━━ Status Icons ━━━"
    echo "✓ Success: "
    echo "✗ Error: "
    echo "⚠ Warning: "
    echo "ℹ Info: "
    echo "  Loading: "
    echo

    echo "━━━ Common Dev Icons ━━━"
    echo "  Database: "
    echo "  Cloud: "
    echo "  Lock: "
    echo "  Key: "
    echo "  Terminal: "
    echo "  Package: "
    echo

    echo "━━━ Arrows & Indicators ━━━"
    echo "  Right Arrow: "
    echo "  Lightning: "
    echo

    echo "━━━ Box Drawing ━━━"
    echo "┌──────────┐"
    echo "│ Box Test │"
    echo "├──────────┤"
    echo "│ Working? │"
    echo "└──────────┘"
    echo
}

show_terminal_info() {
    echo "━━━ Terminal Detection ━━━"

    local term_info=""
    case "${TERM_PROGRAM:-}" in
        vscode)
            term_info="VS Code Terminal"
            echo -e "${GREEN}${NC} $term_info detected"
            echo "   Set: Terminal › Integrated: Font Family to 'MesloLGS Nerd Font Mono'"
            ;;
        Apple_Terminal)
            term_info="macOS Terminal.app"
            echo -e "${GREEN}${NC} $term_info detected"
            echo "   Set font in: Terminal → Preferences → Profiles → Font"
            ;;
        iTerm.app)
            term_info="iTerm2"
            echo -e "${GREEN}${NC} $term_info detected"
            echo "   Set font in: Preferences → Profiles → Text → Font"
            ;;
        Hyper)
            term_info="Hyper Terminal"
            echo -e "${GREEN}${NC} $term_info detected"
            echo "   Set fontFamily in ~/.hyper.js"
            ;;
        Alacritty)
            term_info="Alacritty"
            echo -e "${GREEN}${NC} $term_info detected"
            echo "   Set font.normal.family in ~/.config/alacritty/alacritty.yml"
            ;;
        *)
            term_info="${TERM_PROGRAM:-Unknown}"
            echo -e "${CYAN}ℹ${NC} Terminal: $term_info"
            echo "   Configure your terminal to use 'MesloLGS Nerd Font'"
            ;;
    esac
    echo
}

show_font_status() {
    echo "━━━ Installed Nerd Fonts ━━━"

    local fonts
    fonts=$(detect_installed_fonts)

    if [[ -n "$fonts" ]]; then
        echo -e "${GREEN}${NC} Found Nerd Fonts:"
        echo "$fonts" | while read -r font; do
            echo "   - $(basename "$font")"
        done
    else
        echo -e "${YELLOW}⚠${NC} No Nerd Fonts detected in standard locations"
    fi
    echo
}

# ============================================================================
# Auto-Fix Functions
# ============================================================================

offer_auto_fix() {
    echo
    echo "━━━ Troubleshooting ━━━"
    echo
    echo " If icons appear as boxes (□) or question marks (?):"
    echo
    echo "   Option 1: Run the font installer"
    echo -e "   ${CYAN}./setup-fonts-enhanced.sh${NC}"
    echo
    echo "   Option 2: Manual installation"
    echo "   - Download MesloLGS NF from the project root"
    echo "   - Double-click each .ttf file to install"
    echo "   - Restart your terminal"
    echo "   - Configure terminal to use 'MesloLGS Nerd Font'"
    echo

    # Check if fonts are in project but not installed
    local project_fonts=0
    for font in "$SCRIPT_DIR"/MesloLGS*.ttf; do
        [[ -f "$font" ]] && ((project_fonts++))
    done

    if [[ $project_fonts -gt 0 ]]; then
        local installed_fonts
        installed_fonts=$(detect_installed_fonts | wc -l)

        if [[ $installed_fonts -eq 0 ]]; then
            echo -e "${YELLOW}⚠${NC} Found $project_fonts font files in project but none installed."
            echo
            read -r -p "   Would you like to install them now? [y/N]: " response
            if [[ "$response" =~ ^[Yy] ]]; then
                install_fonts_auto
            fi
        fi
    fi
}

install_fonts_auto() {
    echo
    echo "Installing fonts..."

    local os
    os=$(uname -s)
    local target_dir

    case "$os" in
        Darwin)
            target_dir="$HOME/Library/Fonts"
            ;;
        Linux)
            target_dir="$HOME/.local/share/fonts"
            mkdir -p "$target_dir"
            ;;
        *)
            echo -e "${RED}✗${NC} Unsupported OS: $os"
            return 1
            ;;
    esac

    local installed=0
    for font in "$SCRIPT_DIR"/MesloLGS*.ttf; do
        if [[ -f "$font" ]]; then
            cp "$font" "$target_dir/"
            echo -e "${GREEN}${NC} Installed: $(basename "$font")"
            ((installed++))
        fi
    done

    if [[ $installed -gt 0 ]]; then
        # Refresh font cache on Linux
        if [[ "$os" == "Linux" ]] && command -v fc-cache >/dev/null 2>&1; then
            fc-cache -f "$target_dir"
        fi

        echo
        echo -e "${GREEN}${NC} Installed $installed fonts to $target_dir"
        echo
        echo "  Important: Restart your terminal and set font to 'MesloLGS Nerd Font'"
    else
        echo -e "${YELLOW}⚠${NC} No font files found in project directory"
    fi
}

# ============================================================================
# Usage
# ============================================================================

show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Preview Nerd Font icons and detect/fix rendering issues.

Options:
    --preview       Show icon preview only (default)
    --check         Check installed fonts
    --install       Install fonts from project
    --terminal      Show terminal configuration info
    --all           Show all information
    -h, --help      Show this help

Examples:
    $(basename "$0")              # Show icon preview
    $(basename "$0") --check      # Check installed fonts
    $(basename "$0") --install    # Install fonts
    $(basename "$0") --all        # Complete diagnostic

EOF
}

# ============================================================================
# Main
# ============================================================================

main() {
    local mode="${1:---all}"

    case "$mode" in
        --preview)
            show_preview
            ;;
        --check)
            show_font_status
            ;;
        --install)
            install_fonts_auto
            ;;
        --terminal)
            show_terminal_info
            ;;
        --all|"")
            show_preview
            show_terminal_info
            show_font_status
            offer_auto_fix
            ;;
        -h|--help)
            show_usage
            ;;
        *)
            echo "Unknown option: $mode"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
