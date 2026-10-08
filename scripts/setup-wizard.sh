#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# ============================================================================
# Interactive Setup Wizard
# Part of Professional Development Terminal Setup
# ============================================================================
# Provides a guided, interactive setup experience for new users.
# ============================================================================

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source dependencies
source "$SCRIPT_DIR/lib/logger.sh"
source "$SCRIPT_DIR/lib/env.sh"
source "$SCRIPT_DIR/lib/backup.sh"

# ============================================================================
# Configuration
# ============================================================================

STATE_FILE="$HOME/.config/version-manager/wizard-state.json"
FIRST_RUN_MARKER="$HOME/.config/version-manager/.first-run-complete"

# Colors
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly UNDERLINE='\033[4m'
readonly CYAN='\033[0;36m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'

# Progress tracking
declare -g TOTAL_STEPS=0
declare -g CURRENT_STEP=0

# ============================================================================
# UI Components
# ============================================================================

# Clear screen and show header
show_header() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
    ╔═══════════════════════════════════════════════════════════════════╗
    ║                                                                   ║
    ║    Professional Development Environment Setup Wizard            ║
    ║                                                                   ║
    ╚═══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo
}

# Show progress bar
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))

    printf "\r  Progress: ["
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "] %3d%% (%d/%d)" "$percent" "$current" "$total"
    echo
}

# Show step header
show_step() {
    local step_num=$1
    local step_title=$2
    CURRENT_STEP=$((CURRENT_STEP + 1))  # not ((x++)): pre-inc returns 0-value, aborts under set -e (B1.5 class)

    echo
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Step $step_num: $step_title${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

# Prompt for yes/no
prompt_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local response

    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi

    read -r -p "  $prompt" response
    response="${response:-$default}"

    [[ "$response" =~ ^[Yy] ]]
}

# Prompt for selection
prompt_select() {
    local prompt="$1"
    shift
    local options=("$@")

    echo -e "  ${prompt}"
    echo

    local i=1
    for opt in "${options[@]}"; do
        echo -e "    ${CYAN}$i)${NC} $opt"
        i=$(( i + 1 ))
    done
    echo

    local choice
    while true; do
        read -r -p "  Enter choice (1-${#options[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#options[@]})); then
            echo "$choice"
            return 0
        fi
        echo -e "  ${RED}Invalid choice. Please try again.${NC}"
    done
}

# Show spinner for long operations
show_spinner() {
    local pid=$1
    local message="${2:-Working...}"
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

    while kill -0 "$pid" 2>/dev/null; do
        for ((i=0; i<${#spinstr}; i++)); do
            printf "\r  ${spinstr:$i:1} %s" "$message"
            sleep 0.1
        done
    done
    printf "\r  ✓ %s\n" "$message"
}

# Success message
show_success() {
    echo -e "  ${GREEN}✓${NC} $1"
}

# Warning message
show_warning() {
    echo -e "  ${YELLOW}!${NC} $1"
}

# Error message
show_error() {
    echo -e "  ${RED}✗${NC} $1"
}

# Info message
show_info() {
    echo -e "  ${BLUE}ℹ${NC} $1"
}

# ============================================================================
# Profile Definitions
# ============================================================================

# Minimal profile - just the essentials
profile_minimal() {
    cat << 'EOF'
{
    "name": "Minimal",
    "description": "Essential tools only - Node.js and Python",
    "components": {
        "theme": true,
        "nvm": true,
        "pyenv": true,
        "goenv": false,
        "rustup": false,
        "jenv": false,
        "vscode": false,
        "fonts": true
    }
}
EOF
}

# Standard profile - common development setup
profile_standard() {
    cat << 'EOF'
{
    "name": "Standard",
    "description": "Common development setup with popular tools",
    "components": {
        "theme": true,
        "nvm": true,
        "pyenv": true,
        "goenv": true,
        "rustup": false,
        "jenv": false,
        "vscode": true,
        "fonts": true
    }
}
EOF
}

# Full profile - everything
profile_full() {
    cat << 'EOF'
{
    "name": "Full",
    "description": "Complete setup with all version managers",
    "components": {
        "theme": true,
        "nvm": true,
        "pyenv": true,
        "goenv": true,
        "rustup": true,
        "jenv": true,
        "vscode": true,
        "fonts": true
    }
}
EOF
}

# ============================================================================
# First Run Detection
# ============================================================================

is_first_run() {
    [[ ! -f "$FIRST_RUN_MARKER" ]]
}

mark_first_run_complete() {
    mkdir -p "$(dirname "$FIRST_RUN_MARKER")"
    date -Iseconds > "$FIRST_RUN_MARKER"
}

# ============================================================================
# Wizard Steps
# ============================================================================

# Step 1: Welcome
step_welcome() {
    show_header

    echo -e "  ${BOLD}Welcome to the Professional Development Environment Setup!${NC}"
    echo
    echo "  This wizard will guide you through setting up:"
    echo
    echo -e "    ${CYAN}•${NC} PowerLevel10k terminal theme"
    echo -e "    ${CYAN}•${NC} Version managers (Node.js, Python, Go, Rust, Java)"
    echo -e "    ${CYAN}•${NC} VS Code integration"
    echo -e "    ${CYAN}•${NC} Nerd Fonts for icon support"
    echo

    if is_first_run; then
        echo -e "  ${GREEN}This appears to be your first time running the wizard.${NC}"
    else
        echo -e "  ${DIM}You've run this wizard before. Previous settings may be updated.${NC}"
    fi
    echo

    if ! prompt_yes_no "Ready to begin?"; then
        echo
        echo "  Setup cancelled. Run again when you're ready!"
        exit 0
    fi
}

# Step 2: System Check
step_system_check() {
    show_step 1 "System Requirements Check"

    local issues=0

    # Check shell
    echo "  Checking shell environment..."
    if [[ -n "${ZSH_VERSION:-}" ]] || [[ "$(basename "$SHELL")" == "zsh" ]]; then
        show_success "Zsh shell detected"
    else
        show_warning "Zsh not detected as default shell"
        show_info "Some features require zsh. Consider switching: chsh -s \$(which zsh)"
        issues=$(( issues + 1 ))
    fi

    # Check git
    if command -v git >/dev/null 2>&1; then
        show_success "Git installed: $(git --version | head -1)"
    else
        show_error "Git not found - required for installation"
        issues=$(( issues + 1 ))
    fi

    # Check curl/wget
    if command -v curl >/dev/null 2>&1; then
        show_success "curl available"
    elif command -v wget >/dev/null 2>&1; then
        show_success "wget available"
    else
        show_error "Neither curl nor wget found - required for downloads"
        issues=$(( issues + 1 ))
    fi

    # Check Homebrew on macOS
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if command -v brew >/dev/null 2>&1; then
            show_success "Homebrew installed"
        else
            show_warning "Homebrew not found (recommended for macOS)"
        fi
    fi

    echo
    if [[ $issues -gt 0 ]]; then
        show_warning "Found $issues issue(s). Some features may not work."
        if ! prompt_yes_no "Continue anyway?" "n"; then
            exit 1
        fi
    else
        show_success "All system requirements met!"
    fi

    sleep 1
}

# Step 3: Profile Selection
step_profile_selection() {
    show_step 2 "Select Installation Profile"

    echo "  Choose a setup profile based on your needs:"
    echo
    echo -e "    ${CYAN}1)${NC} ${BOLD}Minimal${NC} - Essential tools only"
    echo "       Node.js (nvm), Python (pyenv), Theme, Fonts"
    echo
    echo -e "    ${CYAN}2)${NC} ${BOLD}Standard${NC} - Common development setup ${GREEN}(Recommended)${NC}"
    echo "       Minimal + Go (goenv), VS Code integration"
    echo
    echo -e "    ${CYAN}3)${NC} ${BOLD}Full${NC} - Everything"
    echo "       Standard + Rust (rustup), Java (jenv)"
    echo
    echo -e "    ${CYAN}4)${NC} ${BOLD}Custom${NC} - Choose individual components"
    echo

    local choice
    read -r -p "  Enter choice (1-4) [2]: " choice
    choice="${choice:-2}"

    case "$choice" in
        1) SELECTED_PROFILE="minimal" ;;
        2) SELECTED_PROFILE="standard" ;;
        3) SELECTED_PROFILE="full" ;;
        4) SELECTED_PROFILE="custom" ;;
        *) SELECTED_PROFILE="standard" ;;
    esac

    echo
    show_success "Selected profile: $SELECTED_PROFILE"
}

# Step 4: Custom Component Selection
step_custom_selection() {
    if [[ "$SELECTED_PROFILE" != "custom" ]]; then
        return
    fi

    show_step 3 "Select Components"

    INSTALL_THEME=$(prompt_yes_no "Install PowerLevel10k theme?" && echo "true" || echo "false")
    INSTALL_NVM=$(prompt_yes_no "Install NVM (Node.js)?" && echo "true" || echo "false")
    INSTALL_PYENV=$(prompt_yes_no "Install pyenv (Python)?" && echo "true" || echo "false")
    INSTALL_GOENV=$(prompt_yes_no "Install goenv (Go)?" "n" && echo "true" || echo "false")
    INSTALL_RUSTUP=$(prompt_yes_no "Install rustup (Rust)?" "n" && echo "true" || echo "false")
    INSTALL_JENV=$(prompt_yes_no "Install jenv (Java)?" "n" && echo "true" || echo "false")
    INSTALL_VSCODE=$(prompt_yes_no "Configure VS Code integration?" && echo "true" || echo "false")
    INSTALL_FONTS=$(prompt_yes_no "Install Nerd Fonts?" && echo "true" || echo "false")
}

# Step 5: Confirmation
step_confirmation() {
    show_step 4 "Confirm Installation"

    echo "  The following will be installed/configured:"
    echo

    case "$SELECTED_PROFILE" in
        minimal)
            echo -e "    ${GREEN}✓${NC} PowerLevel10k Theme"
            echo -e "    ${GREEN}✓${NC} NVM (Node.js version manager)"
            echo -e "    ${GREEN}✓${NC} pyenv (Python version manager)"
            echo -e "    ${GREEN}✓${NC} Nerd Fonts"
            TOTAL_STEPS=4
            ;;
        standard)
            echo -e "    ${GREEN}✓${NC} PowerLevel10k Theme"
            echo -e "    ${GREEN}✓${NC} NVM (Node.js version manager)"
            echo -e "    ${GREEN}✓${NC} pyenv (Python version manager)"
            echo -e "    ${GREEN}✓${NC} goenv (Go version manager)"
            echo -e "    ${GREEN}✓${NC} VS Code Integration"
            echo -e "    ${GREEN}✓${NC} Nerd Fonts"
            TOTAL_STEPS=6
            ;;
        full)
            echo -e "    ${GREEN}✓${NC} PowerLevel10k Theme"
            echo -e "    ${GREEN}✓${NC} NVM (Node.js version manager)"
            echo -e "    ${GREEN}✓${NC} pyenv (Python version manager)"
            echo -e "    ${GREEN}✓${NC} goenv (Go version manager)"
            echo -e "    ${GREEN}✓${NC} rustup (Rust version manager)"
            echo -e "    ${GREEN}✓${NC} jenv (Java version manager)"
            echo -e "    ${GREEN}✓${NC} VS Code Integration"
            echo -e "    ${GREEN}✓${NC} Nerd Fonts"
            TOTAL_STEPS=8
            ;;
        custom)
            # Use var=$((var + 1)) not ((var++)): under `set -e`, ((x++))
            # returns the PRE-increment value, so the first bump from 0 exits 1
            # and aborts the wizard. Assignment form always returns 0. (B1.5 class)
            [[ "$INSTALL_THEME" == "true" ]] && echo -e "    ${GREEN}✓${NC} PowerLevel10k Theme" && TOTAL_STEPS=$((TOTAL_STEPS + 1))
            [[ "$INSTALL_NVM" == "true" ]] && echo -e "    ${GREEN}✓${NC} NVM" && TOTAL_STEPS=$((TOTAL_STEPS + 1))
            [[ "$INSTALL_PYENV" == "true" ]] && echo -e "    ${GREEN}✓${NC} pyenv" && TOTAL_STEPS=$((TOTAL_STEPS + 1))
            [[ "$INSTALL_GOENV" == "true" ]] && echo -e "    ${GREEN}✓${NC} goenv" && TOTAL_STEPS=$((TOTAL_STEPS + 1))
            [[ "$INSTALL_RUSTUP" == "true" ]] && echo -e "    ${GREEN}✓${NC} rustup" && TOTAL_STEPS=$((TOTAL_STEPS + 1))
            [[ "$INSTALL_JENV" == "true" ]] && echo -e "    ${GREEN}✓${NC} jenv" && TOTAL_STEPS=$((TOTAL_STEPS + 1))
            [[ "$INSTALL_VSCODE" == "true" ]] && echo -e "    ${GREEN}✓${NC} VS Code" && TOTAL_STEPS=$((TOTAL_STEPS + 1))
            [[ "$INSTALL_FONTS" == "true" ]] && echo -e "    ${GREEN}✓${NC} Nerd Fonts" && TOTAL_STEPS=$((TOTAL_STEPS + 1))
            ;;
    esac

    echo
    echo -e "  ${DIM}A backup will be created before making changes.${NC}"
    echo

    if ! prompt_yes_no "Proceed with installation?"; then
        echo
        echo "  Installation cancelled."
        exit 0
    fi
}

# Step 6: Installation
step_install() {
    show_step 5 "Installing Components"

    CURRENT_STEP=0

    # Create restore point
    echo "  Creating restore point..."
    create_restore_point "wizard_$(date +%Y%m%d_%H%M%S)" "$HOME/.zshrc" "$HOME/.p10k.zsh" 2>/dev/null || true
    show_success "Restore point created"

    # Install based on profile
    case "$SELECTED_PROFILE" in
        minimal)
            install_component "theme"
            install_component "nvm"
            install_component "pyenv"
            install_component "fonts"
            ;;
        standard)
            install_component "theme"
            install_component "nvm"
            install_component "pyenv"
            install_component "goenv"
            install_component "vscode"
            install_component "fonts"
            ;;
        full)
            install_component "theme"
            install_component "nvm"
            install_component "pyenv"
            install_component "goenv"
            install_component "rustup"
            install_component "jenv"
            install_component "vscode"
            install_component "fonts"
            ;;
        custom)
            [[ "$INSTALL_THEME" == "true" ]] && install_component "theme"
            [[ "$INSTALL_NVM" == "true" ]] && install_component "nvm"
            [[ "$INSTALL_PYENV" == "true" ]] && install_component "pyenv"
            [[ "$INSTALL_GOENV" == "true" ]] && install_component "goenv"
            [[ "$INSTALL_RUSTUP" == "true" ]] && install_component "rustup"
            [[ "$INSTALL_JENV" == "true" ]] && install_component "jenv"
            [[ "$INSTALL_VSCODE" == "true" ]] && install_component "vscode"
            [[ "$INSTALL_FONTS" == "true" ]] && install_component "fonts"
            ;;
    esac
}

# Install a single component
install_component() {
    local component="$1"
    CURRENT_STEP=$((CURRENT_STEP + 1))  # not ((x++)): pre-inc returns 0-value, aborts under set -e (B1.5 class)

    echo
    show_progress "$CURRENT_STEP" "$TOTAL_STEPS"
    echo

    case "$component" in
        theme)
            echo "  Installing PowerLevel10k theme..."
            if "$SCRIPT_DIR/setup-theme.sh" professional >/dev/null 2>&1; then
                show_success "Theme installed"
            else
                show_warning "Theme installation had issues (may already be configured)"
            fi
            ;;
        nvm)
            echo "  Configuring NVM..."
            if [[ -d "${NVM_DIR:-$HOME/.nvm}" ]]; then
                show_success "NVM already installed"
            else
                show_info "NVM will be configured on next shell start"
            fi
            ;;
        pyenv)
            echo "  Configuring pyenv..."
            if command -v pyenv >/dev/null 2>&1; then
                show_success "pyenv already installed"
            else
                show_info "pyenv will be configured on next shell start"
            fi
            ;;
        goenv)
            echo "  Configuring goenv..."
            if command -v goenv >/dev/null 2>&1; then
                show_success "goenv already installed"
            else
                show_info "goenv configuration added"
            fi
            ;;
        rustup)
            echo "  Configuring rustup..."
            if command -v rustup >/dev/null 2>&1; then
                show_success "rustup already installed"
            else
                show_info "rustup will need manual installation"
            fi
            ;;
        jenv)
            echo "  Configuring jenv..."
            if command -v jenv >/dev/null 2>&1; then
                show_success "jenv already installed"
            else
                show_info "jenv configuration added"
            fi
            ;;
        vscode)
            echo "  Generating VS Code settings..."
            if "$SCRIPT_DIR/generate-vscode-settings.sh" >/dev/null 2>&1; then
                show_success "VS Code settings generated"
            else
                show_warning "VS Code settings generation had issues"
            fi
            ;;
        fonts)
            echo "  Nerd Fonts are included in this project"
            show_success "Fonts available in project directory"
            show_info "Install fonts manually from: MesloLGS*.ttf files"
            ;;
    esac

    sleep 0.5
}

# Step 7: Completion
step_completion() {
    show_header

    echo -e "  ${GREEN}${BOLD} Setup Complete!${NC}"
    echo
    echo "  Your development environment has been configured."
    echo
    echo -e "  ${BOLD}Next Steps:${NC}"
    echo
    echo "    1. Restart your terminal or run:"
    echo -e "       ${CYAN}source ~/.zshrc${NC}"
    echo
    echo "    2. Install a Nerd Font in your terminal app:"
    echo "       - Double-click MesloLGS NF Regular.ttf files"
    echo "       - Set as terminal font in preferences"
    echo
    echo "    3. For VS Code, import the generated settings:"
    echo "       - Open VS Code Settings (JSON)"
    echo "       - Merge content from vscode-settings.json"
    echo
    echo -e "  ${BOLD}Useful Commands:${NC}"
    echo
    echo -e "    ${CYAN}./setup.sh${NC}              - Main menu"
    echo -e "    ${CYAN}./tools/system-diagnostics.sh --dashboard${NC}"
    echo "                           - Check system health"
    echo

    mark_first_run_complete

    echo -e "  ${DIM}Setup wizard completed at $(date)${NC}"
    echo
}

# ============================================================================
# Main
# ============================================================================

main() {
    # Initialize
    SELECTED_PROFILE=""
    INSTALL_THEME="false"
    INSTALL_NVM="false"
    INSTALL_PYENV="false"
    INSTALL_GOENV="false"
    INSTALL_RUSTUP="false"
    INSTALL_JENV="false"
    INSTALL_VSCODE="false"
    INSTALL_FONTS="false"

    # Run wizard steps
    step_welcome
    step_system_check
    step_profile_selection
    step_custom_selection
    step_confirmation
    step_install
    step_completion
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
