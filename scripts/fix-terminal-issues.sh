#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034

# Terminal Configuration Diagnostic and Fix Script
# Diagnoses and fixes shell, P10k, and font configuration issues
#
# M4 adopter (B2.1): the P10k whole-file replace and the font installs run
# under backup transactions (lib/backup.sh) — hash-verified rollback on
# failure, byte-compare idempotency (an unchanged source writes nothing, no
# mtime churn), and --dry-run planning with zero writes. The /etc/shells and
# chsh paths keep their existing confirmation gating and are untouched by
# this adoption.

# Only set strict mode when executing directly (not when sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
fi

# Resolve lib paths from THIS file's location (never an inherited SCRIPT_DIR,
# which test harnesses may point elsewhere).
_SCRIPT_FILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${_SCRIPT_FILE_DIR}/.." && pwd)"
source "${REPO_ROOT}/lib/logger.sh"
source "${REPO_ROOT}/lib/env.sh"
source "${REPO_ROOT}/lib/backup.sh"

# Configuration paths
ZSHRC="$HOME/.zshrc"
P10K_CONFIG="$HOME/.p10k.zsh"
PROJECT_P10K_CONFIG="${REPO_ROOT}/config/professional-dev-p10k.zsh"
CONFIRM_SYSTEM_CHANGES=false

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

confirm_etc_shells_append() {
    local zsh_path="$1"

    if [[ "$CONFIRM_SYSTEM_CHANGES" == "true" || "${VMS_CONFIRM:-}" == "1" ]]; then
        return 0
    fi

    local response=""
    if [[ -t 0 ]]; then
        read -r -p "Append $zsh_path to /etc/shells? [y/N]: " response
    else
        log_warn "Confirmation required to modify /etc/shells; re-run with --confirm or VMS_CONFIRM=1"
        return 1
    fi

    if [[ "$response" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
        return 0
    fi

    log_info "Skipped /etc/shells update"
    return 1
}

append_zsh_to_etc_shells() {
    local zsh_path="$1"

    if [[ "$zsh_path" != /* || ! -x "$zsh_path" ]]; then
        log_error "Invalid zsh path: $zsh_path"
        return 1
    fi

    if grep -Fxq "$zsh_path" /etc/shells 2>/dev/null; then
        return 0
    fi

    log_info "Adding zsh to /etc/shells..."

    local planned_shells
    planned_shells=$(mktemp)
    cp /etc/shells "$planned_shells"
    printf '%s\n' "$zsh_path" >> "$planned_shells"

    log_info "Planned /etc/shells change:"
    diff -u /etc/shells "$planned_shells" || true
    rm -f "$planned_shells"

    if ! confirm_etc_shells_append "$zsh_path"; then
        return 1
    fi

    local backup_path="${TMPDIR:-/tmp}/etc-shells.backup.$(date +%Y%m%d_%H%M%S)"
    cp /etc/shells "$backup_path"
    log_success "Backed up /etc/shells to $backup_path"

    printf '%s\n' "$zsh_path" | sudo tee -a /etc/shells >/dev/null
    log_success "Added $zsh_path to /etc/shells"
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
            append_zsh_to_etc_shells "$zsh_path"

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

# Apply the project P10k configuration as a whole-file replace under the
# caller's transaction. The target is registered BEFORE any mutation so a
# failure rolls back the pre-state byte-identically; an unchanged source
# writes nothing (idempotent, no mtime churn); the replace itself is
# atomic (temp file in the target directory + rename).
_files_identical() {
    local a="$1" b="$2"
    [[ -f "$a" && -f "$b" ]] || return 1
    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$a" "$b"
        return 0
    fi
    local ha hb
    ha=$(sha256sum "$a" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$a" 2>/dev/null | awk '{print $1}')
    hb=$(sha256sum "$b" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$b" 2>/dev/null | awk '{print $1}')
    [[ -n "$ha" && "$ha" == "$hb" ]]
}

_fix_terminal_apply_p10k() {
    transaction_add_file "$P10K_CONFIG" || return 1

    if [[ -f "$P10K_CONFIG" ]] && _files_identical "$PROJECT_P10K_CONFIG" "$P10K_CONFIG"; then
        log_info "P10k configuration already matches project source — no change"
        return 0
    fi

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would replace: $P10K_CONFIG (source: $PROJECT_P10K_CONFIG)"
        return 0
    fi

    local dir
    dir=$(dirname "$P10K_CONFIG")
    if [[ ! -d "$dir" ]]; then
        log_error "P10k target directory missing: $dir"
        return 1
    fi

    local tmp
    tmp=$(mktemp "$dir/.vms-p10k.XXXXXX") || { log_error "P10k: cannot create temp file in $dir"; return 1; }
    if ! cp "$PROJECT_P10K_CONFIG" "$tmp"; then
        rm -f "$tmp"
        log_error "P10k: cannot stage source: $PROJECT_P10K_CONFIG"
        return 1
    fi
    chmod 644 "$tmp"
    if ! mv "$tmp" "$P10K_CONFIG"; then
        rm -f "$tmp"
        log_error "P10k: atomic replace failed: $P10K_CONFIG"
        return 1
    fi
    log_info "Applied project PowerLevel10k configuration"
    return 0
}

# Fix PowerLevel10k configuration
fix_p10k_configuration() {
    log_info " Fixing PowerLevel10k Configuration"
    log_info "====================================="
    echo

    if [[ ! -f "$PROJECT_P10K_CONFIG" ]]; then
        log_error "Project P10k configuration not found at: $PROJECT_P10K_CONFIG"
        return 1
    fi

    transaction_start "fix_terminal_p10k" || return 1

    if _fix_terminal_apply_p10k; then
        transaction_commit
        log_success "PowerLevel10k configuration in place"
        echo
        return 0
    fi

    transaction_rollback || log_error "Rollback reported errors — inspect $HOME/.config-backups/transactions"
    log_error "P10k configuration FAILED — rolled back"
    echo
    return 1
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

    transaction_start "fix_terminal_fonts" || return 1

    local fonts_installed=0 failed=0
    local font target tmp
    for font in "${REPO_ROOT}"/MesloLGS*.ttf; do
        [[ -f "$font" ]] || continue
        target="$font_dir/$(basename "$font")"

        # Register BEFORE any mutation so rollback removes/restores the
        # pre-state (new installs are removed; replaced files are restored).
        if ! transaction_add_file "$target"; then
            failed=1
            break
        fi

        if [[ -f "$target" ]] && _files_identical "$font" "$target"; then
            log_debug "Font already identical, no change: $target"
            continue
        fi

        if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
            log_info "[dry-run] would install: $target (source: $font)"
            fonts_installed=$((fonts_installed + 1))
            continue
        fi

        tmp=$(mktemp "$font_dir/.vms-font.XXXXXX") || { failed=1; break; }
        if ! cp "$font" "$tmp"; then
            rm -f "$tmp"
            failed=1
            break
        fi
        if ! mv "$tmp" "$target"; then
            rm -f "$tmp"
            failed=1
            break
        fi
        fonts_installed=$((fonts_installed + 1))
    done

    if [[ "$failed" -ne 0 ]]; then
        transaction_rollback || log_error "Rollback reported errors — inspect $HOME/.config-backups/transactions"
        log_error "Font installation FAILED — rolled back"
        echo
        return 1
    fi

    transaction_commit

    if [[ "$fonts_installed" -eq 0 ]]; then
        log_warn "No MesloLGS font files found in project directory"
    elif [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_success "Dry-run complete — $fonts_installed font file(s) planned, zero writes"
    else
        log_success "Installed $fonts_installed MesloLGS font files"

        # Refresh font cache on Linux (apply mode only — a cache rewrite is
        # a filesystem side effect dry-run must not perform)
        if [[ "$OSTYPE" != "darwin"* ]] && command -v fc-cache >/dev/null 2>&1; then
            fc-cache -f -v
        fi
    fi
    echo
    return 0
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

Usage: $0 [--confirm] [--dry-run] [command]

Options:
    --confirm   Apply privileged system changes without prompting
    --dry-run   Plan P10k/font changes only — zero filesystem writes

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
  $0 --dry-run fix-p10k   # Plan P10k change without writing
  $0 test         # Test configuration
EOF
}

# Main function
main() {
    local command="diagnose"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --confirm)
                CONFIRM_SYSTEM_CHANGES=true
                shift
                ;;
            --dry-run)
                TRANSACTION_DRY_RUN=1
                export TRANSACTION_DRY_RUN
                shift
                ;;
            diagnose|fix-shell|fix-p10k|fix-fonts|fix-all|test)
                command="$1"
                shift
                ;;
            help|--help|-h)
                command="help"
                shift
                ;;
            *)
                log_error "Unknown command: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "DRY-RUN MODE — planning P10k/font changes only, zero filesystem writes"
        echo
    fi

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
