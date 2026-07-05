#!/usr/bin/env bash
# Consolidated Theme Icon Management Script
# Combines: fix-theme-icons.sh, customize-theme-icons.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/lib/logger.sh"
source "${REPO_ROOT}/lib/theme-ops.sh"

show_usage() {
    echo "Usage: $0 [OPTION]"
    echo "Manage PowerLevel10k theme icons"
    echo
    echo "Options:"
    echo "  --fix        Fix broken theme icons"
    echo "  --customize  Interactive icon customization"
    echo "  --reset      Reset to default icons"
    echo "  --preview    Preview available icons"
    echo "  --help       Show this help message"
}

fix_icons() {
    log_info "Fixing theme icons..."
    local p10k_config="$HOME/.p10k.zsh"
    if [[ ! -f "$p10k_config" ]]; then
        log_error "No .p10k.zsh configuration found. Run theme setup first."
        return 1
    fi

    # Backup before modifying
    if command -v create_backup >/dev/null 2>&1; then
        create_backup "$p10k_config"
    else
        cp "$p10k_config" "${p10k_config}.bak.$(date +%s)"
    fi

    # Replace common broken emoji sequences with Nerd Font icons
    local -A icon_replacements=(
        ['📁']=$'\uf07b'   # nf-fa-folder
        ['📂']=$'\uf115'   # nf-fa-folder_open
        ['🔧']=$'\uf0ad'   # nf-fa-wrench
        ['⚙️']=$'\ue615'   # nf-seti-config
        ['🐍']=$'\ue73c'   # nf-dev-python
        ['📦']=$'\uf487'   # nf-oct-package
        ['🟢']=$'\uf00c'   # nf-fa-check
        ['🔴']=$'\uf00d'   # nf-fa-times
        ['⚡']=$'\uf0e7'   # nf-fa-bolt
    )

    local count=0
    for emoji in "${!icon_replacements[@]}"; do
        if grep -q "$emoji" "$p10k_config" 2>/dev/null; then
            sed -i.tmp "s/$emoji/${icon_replacements[$emoji]}/g" "$p10k_config"
            count=$((count + 1))
        fi
    done
    rm -f "${p10k_config}.tmp"

    if (( count > 0 )); then
        log_success "Replaced $count emoji icon(s) with Nerd Font glyphs"
    else
        log_info "No broken emoji icons found — config looks clean"
    fi
}

customize_icons() {
    log_info "Starting interactive icon customization..."
    local p10k_config="$HOME/.p10k.zsh"
    if [[ ! -f "$p10k_config" ]]; then
        log_error "No .p10k.zsh configuration found. Run theme setup first."
        return 1
    fi

    echo "Customizable icon segments:"
    echo "  1) OS icon"
    echo "  2) Directory icon"
    echo "  3) Git branch icon"
    echo "  4) Prompt character"
    echo "  5) Cancel"
    echo
    local choice
    read -r -p "Select segment to customize (1-5): " choice

    case "$choice" in
        1)
            read -r -p "Enter new OS icon (paste glyph or hex code): " icon
            [[ -n "$icon" ]] && sed -i.tmp "s/POWERLEVEL9K_OS_ICON_CONTENT_EXPANSION=.*/POWERLEVEL9K_OS_ICON_CONTENT_EXPANSION='$icon'/" "$p10k_config" && rm -f "${p10k_config}.tmp"
            log_success "OS icon updated"
            ;;
        2)
            read -r -p "Enter new folder icon: " icon
            [[ -n "$icon" ]] && sed -i.tmp "s/POWERLEVEL9K_FOLDER_ICON=.*/POWERLEVEL9K_FOLDER_ICON='$icon'/" "$p10k_config" && rm -f "${p10k_config}.tmp"
            log_success "Directory icon updated"
            ;;
        3)
            read -r -p "Enter new git branch icon: " icon
            [[ -n "$icon" ]] && sed -i.tmp "s/POWERLEVEL9K_VCS_BRANCH_ICON=.*/POWERLEVEL9K_VCS_BRANCH_ICON='$icon '/" "$p10k_config" && rm -f "${p10k_config}.tmp"
            log_success "Git branch icon updated"
            ;;
        4)
            read -r -p "Enter new prompt char (e.g. ❯ ▶ λ): " icon
            [[ -n "$icon" ]] && sed -i.tmp "s/POWERLEVEL9K_PROMPT_CHAR_OK_.*_CONTENT_EXPANSION=.*/POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_CONTENT_EXPANSION='$icon'/" "$p10k_config" && rm -f "${p10k_config}.tmp"
            log_success "Prompt character updated"
            ;;
        5)
            log_info "Cancelled"
            return 0
            ;;
        *)
            log_warn "Invalid choice"
            return 1
            ;;
    esac
    log_info "Restart your terminal or run 'source ~/.p10k.zsh' to see changes"
}

reset_icons() {
    log_info "Resetting to default icons..."
    local p10k_config="$HOME/.p10k.zsh"
    local theme_dir="${REPO_ROOT}/config"

    if [[ ! -f "$p10k_config" ]]; then
        log_error "No .p10k.zsh configuration found."
        return 1
    fi

    # Detect current theme and re-apply it
    local current_theme="professional"
    if grep -q "Apple.*Monterey" "$p10k_config" 2>/dev/null; then
        current_theme="apple"
    elif grep -q "Minimal.*Theme" "$p10k_config" 2>/dev/null; then
        current_theme="minimal"
    elif grep -q "Rainbow" "$p10k_config" 2>/dev/null; then
        current_theme="rainbow"
    fi

    local theme_file=""
    case "$current_theme" in
        professional) theme_file="${theme_dir}/professional-dev-p10k.zsh" ;;
        apple)        theme_file="${theme_dir}/apple-style-p10k.zsh" ;;
        minimal)      theme_file="${theme_dir}/minimal-p10k.zsh" ;;
        rainbow)      theme_file="${theme_dir}/rainbow-p10k.zsh" ;;
    esac

    if [[ -f "$theme_file" ]]; then
        cp "$p10k_config" "${p10k_config}.bak.$(date +%s)"
        cp "$theme_file" "$p10k_config"
        log_success "Icons reset to '$current_theme' theme defaults"
        log_info "Restart your terminal or run 'source ~/.p10k.zsh' to apply"
    else
        log_error "Theme file not found: $theme_file"
        return 1
    fi
}

preview_icons() {
    log_info "👀 Available icon preview..."

    # Professional Development Theme Preview
    echo "Professional Development Theme Preview:"
    echo "======================================"
    echo
    echo "     ~/projects/my-app   main  20.19.2  3.12.8  ⌚ 10:30:25  ✓"
    echo
    log_info "This theme features:"
    log_info "  • Enhanced version management indicators (Go 1.23.4, Rust 1.82.0, Java 21.0.2)"
    log_info "  • Customizable OS, directory, and status icons"
    echo

    # Apple Style Theme Preview
    echo "Apple Style Theme Preview:"
    echo "=========================="
    echo
    echo "   ~/projects/my-app  main 20.19.2 3.12.8 ⌚ 10:30:25 ✘"
    echo

    # Minimal Theme Preview
    echo "Minimal Theme Preview:"
    echo "======================"
    echo
    echo "  ~/projects/my-app main N:20.19.2 P:3.12.8 10:30:25"
    echo
}

# Main execution
case "${1:-}" in
    --fix)       fix_icons ;;
    --customize) customize_icons ;;
    --reset)     reset_icons ;;
    --preview)   preview_icons ;;
    --help)      show_usage ;;
    *)           show_usage; exit 1 ;;
esac
