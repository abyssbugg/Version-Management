#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2086,SC2155,SC2005,SC2207,SC2016

# Enhanced Font Setup with Oh My Posh and Nerd Fonts Integration
# Provides multiple font installation methods for personal use
#
# M4 adopter (P3-1): the local font FILE copies (macOS ~/Library/Fonts,
# Linux ~/.local/share/fonts) run under backup transactions (lib/backup.sh)
# — hash-verified rollback on failure, byte-compare idempotency (an unchanged
# source writes nothing, no mtime churn), and --dry-run planning with zero
# writes. The oh-my-posh and Homebrew cask paths are EXTERNAL network
# installers and are NOT wrapped in transactions; under --dry-run they are
# reported plan-only. Menu option 4 delegates to scripts/patch-font.sh
# (separate registry entry).

set -euo pipefail

# Resolve lib paths from THIS file's location under a PRIVATE name — the
# transaction/mutation libs (validation.sh et al.) clobber the global
# SCRIPT_DIR when sourced, so an adopter must never rely on it (M4 lesson).
_VMS_FONTS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_VMS_FONTS_SCRIPT_DIR}/lib/logger.sh"
source "${_VMS_FONTS_SCRIPT_DIR}/lib/env.sh"
source "${_VMS_FONTS_SCRIPT_DIR}/lib/backup.sh"
source "${_VMS_FONTS_SCRIPT_DIR}/lib/mutation.sh"

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
# Network installer: NOT wrapped in a transaction; under dry-run it is
# reported plan-only and never executed.
install_with_oh_my_posh() {
    if check_oh_my_posh; then
        if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
            log_info "[dry-run] would launch: oh-my-posh font install (recommended: Meslo) — plan-only"
            return 0
        fi
        log_info " Launching Oh My Posh font installer..."
        log_info " Recommended: Select 'Meslo' for consistency with your setup"
        oh-my-posh font install
    else
        log_error "Oh My Posh CLI is required for this method"
        return 1
    fi
}

# Install fonts using Homebrew
# Network installer: NOT wrapped in a transaction; under dry-run the search
# and the cask install are reported plan-only and never executed.
install_with_homebrew() {
    if command -v brew >/dev/null 2>&1; then
        if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
            log_info "[dry-run] would search: brew search nerd-font — plan-only"
            log_info "[dry-run] would prompt for a cask name and run: brew install --cask <name>"
            return 0
        fi
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

# Install from local files — the FILE mutations of this script.
# Adoption (P3-1): one transaction ("fonts_enhanced"); each target font is
# registered with the transaction BEFORE any mutation so rollback restores
# (or removes) the pre-state byte-identically; an unchanged source writes
# nothing (byte-compare idempotency, no mtime churn); the copy itself is
# atomic (temp file in the target directory + rename, source mode preserved).
install_local_fonts() {
    log_info " Installing MesloLGS NF from local files..."

    local font_files=(
        "MesloLGS NF Regular.ttf"
        "MesloLGS NF Bold.ttf"
        "MesloLGS NF Italic.ttf"
        "MesloLGS NF Bold Italic.ttf"
    )

    local font_dir
    if [[ "$OSTYPE" == "darwin"* ]]; then
        font_dir="$HOME/Library/Fonts"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        font_dir="$HOME/.local/share/fonts"
    else
        log_warn "Unsupported platform: $OSTYPE — no local font install"
        return 0
    fi

    # Target directory is idempotent infrastructure; created only in apply
    # mode — dry-run plans it instead (zero writes).
    if [[ ! -d "$font_dir" ]]; then
        if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
            log_info "[dry-run] would create font directory: $font_dir"
        else
            if ! mkdir -p "$font_dir"; then
                log_error "Cannot create font directory: $font_dir"
                return 1
            fi
        fi
    fi

    transaction_start "fonts_enhanced" || return 1

    local installed=0 failed=0 font target tmp mode
    for font in "${font_files[@]}"; do
        if [[ ! -f "$_VMS_FONTS_SCRIPT_DIR/$font" ]]; then
            log_warn " Font file not found: $font"
            continue
        fi
        target="$font_dir/$font"

        # Register BEFORE any mutation so rollback removes/restores the
        # pre-state (new installs are removed; replaced files are restored).
        if ! transaction_add_file "$target"; then
            failed=1
            break
        fi

        # Idempotency: an unchanged source writes nothing (portable
        # byte-compare — degrades to sha256 on hosts without cmp).
        if [[ -f "$target" ]] && mutation_files_identical "$_VMS_FONTS_SCRIPT_DIR/$font" "$target"; then
            log_debug "Font already identical, no change: $target"
            continue
        fi

        if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
            log_info "[dry-run] would install: $target (source: $_VMS_FONTS_SCRIPT_DIR/$font)"
            installed=$(( installed + 1 ))
            continue
        fi

        # Atomic: same-directory temp + rename; the source font's mode is
        # preserved (GNU-first stat probing — on Linux, BSD stat -f means
        # filesystem info and exits 0 with wrong data).
        tmp=$(mktemp "$font_dir/.vms-font.XXXXXX") || { failed=1; break; }
        if ! cp "$_VMS_FONTS_SCRIPT_DIR/$font" "$tmp"; then
            rm -f "$tmp"
            failed=1
            break
        fi
        mode=$(stat -c '%a' "$_VMS_FONTS_SCRIPT_DIR/$font" 2>/dev/null || stat -f '%Lp' "$_VMS_FONTS_SCRIPT_DIR/$font" 2>/dev/null || echo 644)
        chmod "$mode" "$tmp" 2>/dev/null || true
        if ! mv "$tmp" "$target"; then
            rm -f "$tmp"
            failed=1
            break
        fi
        installed=$(( installed + 1 ))
    done

    if [[ "$failed" -ne 0 ]]; then
        transaction_rollback || log_error "Rollback reported errors — inspect $HOME/.config-backups/transactions"
        log_error "Font installation FAILED — rolled back"
        return 1
    fi

    transaction_commit

    if [[ "$installed" -eq 0 ]]; then
        log_warn "No local font files needed installing"
    elif [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_success "Dry-run complete — $installed font file(s) planned, zero writes"
    else
        log_success " Installed $installed font files"
        log_info " Restart your terminal to use the new fonts"

        # Refresh font cache on Linux (apply mode only — a cache rewrite is
        # a filesystem side effect dry-run must not perform)
        if [[ "$OSTYPE" == "linux-gnu"* ]] && command -v fc-cache >/dev/null 2>&1; then
            fc-cache -f >/dev/null 2>&1 || true
        fi
    fi
    return 0
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
    if [[ -f "$_VMS_FONTS_SCRIPT_DIR/vscode-settings.json" ]]; then
        log_info "VS Code configuration:"
        if grep -q "MesloLGS" "$_VMS_FONTS_SCRIPT_DIR/vscode-settings.json"; then
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
    local patcher="$_VMS_FONTS_SCRIPT_DIR/scripts/patch-font.sh"

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

# Show usage
show_usage() {
    cat << EOF
Enhanced Font Setup — Nerd Fonts / Oh My Posh integration

Usage: $0 [--dry-run] [command]

Options:
    --dry-run   Plan file changes only — zero filesystem writes
                (network installers are reported, not run)

Commands:
    fonts       Install MesloLGS NF from local files (menu option 1)
    status      Check current font installation (menu option 6)
    (no command) Interactive menu

Examples:
    $0                  # Interactive menu
    $0 fonts            # Install local fonts (transactional, idempotent)
    $0 --dry-run fonts  # Plan the font install without writing
EOF
}

# Main execution
main() {
    local command=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                TRANSACTION_DRY_RUN=1
                export TRANSACTION_DRY_RUN
                shift
                ;;
            fonts)
                command="fonts"
                shift
                ;;
            status)
                command="status"
                shift
                ;;
            help|--help|-h)
                show_usage
                exit 0
                ;;
            *)
                log_warn "Unknown argument: $1 (ignoring — falling back to interactive menu)"
                shift
                ;;
        esac
    done

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "DRY-RUN MODE — planning font changes only, zero filesystem writes"
        echo
    fi

    if [[ -n "$command" ]]; then
        case "$command" in
            fonts) install_local_fonts ;;
            status) check_font_status ;;
        esac
        return $?
    fi

    log_info " Enhanced Font Setup for Development Environment"
    log_info "================================================="
    echo

    while true; do
        show_font_menu
        read -r -p "Enter your choice (1-7): " choice
        echo

        case $choice in
            1)
                install_local_fonts || log_error "Font installation failed"
                ;;
            2)
                install_with_oh_my_posh || log_error "Oh My Posh installation failed"
                ;;
            3)
                install_with_homebrew || log_error "Homebrew installation failed"
                ;;
            4)
                patch_custom_font || log_error "Font patching failed"
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
