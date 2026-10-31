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
source "${SCRIPT_DIR}/lib/mutation.sh"

# Default theme
DEFAULT_THEME="professional"

# Usage information
usage() {
    log_info "Usage: $0 [options] [theme]"
    log_info "  theme: Theme to install (default: $DEFAULT_THEME)"
    log_info ""
    log_info "Options:"
    log_info "  --dry-run          Plan only — zero filesystem writes (INT-1)"
    log_info "  --zshrc-only       Wire the managed theme block in ~/.zshrc and enable"
    log_info "                     segments; do NOT overwrite the existing ~/.p10k.zsh"
    log_info "  --enable-segments  Enable the node_version and pyenv prompt segments in"
    log_info "                     ~/.p10k.zsh (transactional, idempotent)"
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

    # INT-1: a declared dry run writes nothing — plan and return.
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would install $theme preset to $target_file (backup, copy, verify)"
        return 0
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

# ============================================================================
# INT-1: ~/.zshrc theme adoption
#
# setup-theme.sh historically only wrote ~/.p10k.zsh; nothing in the project
# owned the .zshrc theme wiring, so it drifted (the live failure: theme gates
# keyed on stdout being a tty starve wrapped interactive shells — agent
# terminals — of the prompt entirely). These helpers make the managed block
# `setup-theme-p10k` the single owner of oh-my-zsh + Powerlevel10k wiring.
# ============================================================================

_THEME_BLOCK_NAME="setup-theme-p10k"
_THEME_OMZ_ANCHOR_START='# Oh My Zsh configuration'
_THEME_OMZ_ANCHOR_END='source "$ZSH/oh-my-zsh.sh"'
_THEME_P10K_SRC_LINE='[[ ! -t 1 || ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh'
_THEME_P10K_SRC_COMMENT='# Load Powerlevel10k config only for real terminal sessions.'
_THEME_INSTANT_GUARD_OLD='if [[ -t 1 && -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then'
_THEME_INSTANT_GUARD_NEW='if [[ -o interactive && -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then'

# Strip the exact legacy theme wiring this tool replaces. Anchor ranges and
# exact FULL-LINE matches only — never unknown user content. Runs INSIDE the
# caller's transaction (file already registered). Dry-run: plan only.
_theme_strip_legacy_zshrc() {
    local resolved="$1"
    [[ -f "$resolved" ]] || return 0
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would strip legacy theme wiring from $resolved (exact anchors, single range)"
        return 0
    fi

    # Validate the oh-my-zsh range anchors: each exactly once, start before end.
    # On any mismatch the range operation is skipped (never guess at user text);
    # the exact-line operations below remain safe.
    local a1_count a2_count a1_line a2_line range=1
    a1_count=$(grep -cFx "$_THEME_OMZ_ANCHOR_START" "$resolved" || true)
    a2_count=$(grep -cFx "$_THEME_OMZ_ANCHOR_END" "$resolved" || true)
    if [[ "$a1_count" == "1" && "$a2_count" == "1" ]]; then
        a1_line=$(grep -nFx "$_THEME_OMZ_ANCHOR_START" "$resolved" | cut -d: -f1)
        a2_line=$(grep -nFx "$_THEME_OMZ_ANCHOR_END" "$resolved" | cut -d: -f1)
        [[ "$a1_line" -lt "$a2_line" ]] || range=0
    else
        range=0
    fi
    [[ "$range" == "1" ]] || log_warn "oh-my-zsh wiring anchors not found uniquely — range strip skipped (exact-line ops still applied)"

    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/vms-theme-strip.XXXXXX") || return 1
    awk -v a1="$_THEME_OMZ_ANCHOR_START" \
        -v a2="$_THEME_OMZ_ANCHOR_END" \
        -v drop1="$_THEME_P10K_SRC_LINE" \
        -v drop2="$_THEME_P10K_SRC_COMMENT" \
        -v guard_old="$_THEME_INSTANT_GUARD_OLD" \
        -v guard_new="$_THEME_INSTANT_GUARD_NEW" \
        -v range="$range" '
        range == 1 && !skipping && $0 == a1 { skipping = 1; next }
        range == 1 && skipping && $0 == a2 { skipping = 0; next }
        skipping { next }
        $0 == drop1 || $0 == drop2 { next }
        $0 == guard_old { print guard_new; next }
        { print }
    ' "$resolved" > "$tmp" || { rm -f "$tmp"; log_error "Legacy theme strip failed"; return 1; }

    if mutation_files_identical "$tmp" "$resolved"; then
        rm -f "$tmp"
        log_info "No legacy theme wiring found — nothing to strip"
        return 0
    fi
    # AX-21: GNU-first mode probe via the shared helper; never ship a 0600 rc.
    if ! _mutation_preserve_mode "$resolved" "$tmp"; then
        rm -f "$tmp"
        log_error "Cannot preserve the mode of $resolved — legacy theme wiring left in place"
        return 1
    fi
    if ! mv "$tmp" "$resolved"; then
        rm -f "$tmp"
        log_error "Cannot replace $resolved — legacy theme wiring left in place"
        return 1
    fi
    log_success "Legacy theme wiring stripped (managed block is now the single owner)"
    return 0
}

# Write the canonical managed theme block (idempotent; replaces in place on
# rerun). Requires an active transaction. Content must stay zsh-parseable.
_theme_write_zshrc_block() {
    local file="$1"
    local content
    content=$(mktemp "${TMPDIR:-/tmp}/vms-theme-block.XXXXXX") || return 1
    # mutation_block_write adds the BEGIN/END markers itself — the payload
    # must be marker-free or the block ships with doubled markers.
    cat > "$content" << 'BLOCK'
# Theme machinery owned by version-management-setup (setup-theme.sh; INT-1).
# Gated on shell INTERACTIVITY, not on stdout being a tty: wrapped interactive
# shells (agent terminals) lost the theme silently under the old [[ -t 1 ]]
# guard, while pure command shells correctly stay themeless here.
if [[ -o interactive ]]; then
    export ZSH="$HOME/.oh-my-zsh"
    ZSH_THEME="powerlevel10k/powerlevel10k"
    plugins=(git)
    source "$ZSH/oh-my-zsh.sh"
    # Powerlevel10k configuration (presets via setup-theme.sh)
    [[ ! -f "$HOME/.p10k.zsh" ]] || source "$HOME/.p10k.zsh"
fi
BLOCK
    if ! mutation_block_write "$file" "$_THEME_BLOCK_NAME" "$content"; then
        rm -f "$content"
        return 1
    fi
    rm -f "$content"
    return 0
}

# Enable the node_version and pyenv prompt elements in a p10k config.
# Edits ONLY inside the POWERLEVEL9K_{LEFT,RIGHT}_PROMPT_ELEMENTS arrays:
# uncomment an existing commented element; if pyenv is absent from the right
# list, insert it after the enabled node_version line (or before the list's
# closing paren). Idempotent. Caller registers the file in a transaction.
_theme_enable_segments() {
    local resolved="$1"
    [[ -f "$resolved" ]] || { log_error "p10k configuration not found: $resolved"; return 1; }
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would enable node_version and pyenv prompt elements in $resolved"
        return 0
    fi
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/vms-theme-seg.XXXXXX") || return 1
    awk '
        /^[[:space:]]*typeset -g POWERLEVEL9K_(LEFT|RIGHT)_PROMPT_ELEMENTS=\(/ {
            inlist = 1
            list = $0
            sub(/.*POWERLEVEL9K_/, "", list); sub(/_PROMPT_ELEMENTS.*/, "", list)
            print; next
        }
        inlist && printed_node && !inserted && list == "RIGHT" && !pyenv_seen &&
        /^[[:space:]]*\)[[:space:]]*$/ {
            print "    pyenv"          # list ends right after node_version
            inserted = 1
            inlist = 0
            print
            next
        }
        inlist && /^[[:space:]]*\)[[:space:]]*$/ { inlist = 0; print; next }
        !inlist { print; next }
        # uncomment commented node_version / pyenv element lines
        /^[[:space:]]*# (node_version|pyenv)([[:space:]]+#.*)?[[:space:]]*$/ {
            line = $0
            sub(/^[[:space:]]*#[[:space:]]?/, "", line)
            print line
            if (line ~ /^pyenv([[:space:]]|$)/) inserted = 1
            if (line ~ /^node_version([[:space:]]|$)/) printed_node = 1
            next
        }
        /^[[:space:]]*node_version([[:space:]]|$)/ { printed_node = 1; print; next }
        /^[[:space:]]*pyenv([[:space:]]|$)/ { inserted = 1; print; next }
        # pyenv missing from the right list: insert before the first element
        # line that follows the enabled node_version (skipping separators).
        inlist && printed_node && !inserted && list == "RIGHT" && !pyenv_seen {
            if ($0 ~ /^[[:space:]]*#/) { print; next }
            print "    pyenv"
            inserted = 1
            print
            next
        }
        {
            if ($0 ~ /^[[:space:]]*# ?pyenv([[:space:]]|#|$)/ || $0 ~ /^[[:space:]]*pyenv([[:space:]]|$)/) pyenv_seen = 1
            print
        }
    ' "$resolved" > "$tmp" || { rm -f "$tmp"; log_error "Segment enablement failed"; return 1; }

    if mutation_files_identical "$tmp" "$resolved"; then
        rm -f "$tmp"
        log_info "Prompt segments already enabled — no change"
        return 0
    fi
    if ! _mutation_preserve_mode "$resolved" "$tmp"; then
        rm -f "$tmp"
        log_error "Cannot preserve the mode of $resolved — segments left unchanged"
        return 1
    fi
    if ! mv "$tmp" "$resolved"; then
        rm -f "$tmp"
        log_error "Cannot replace $resolved — segments left unchanged"
        return 1
    fi
    log_success "Prompt segments enabled: node_version, pyenv"
    return 0
}

# Adopt ~/.zshrc for the theme: register pre-state, take the shared
# workstation-config lock (same domain as the other rc writers; nested inside
# the main workstation-mutation lock, matching version-manager.sh's
# discipline), strip legacy wiring, write the managed block, verify parse.
_theme_adopt_zshrc() {
    local file="$1"
    [[ ! -e "$file" || -f "$file" ]] || { log_error "Not a regular shell configuration: $file"; return 1; }
    local resolved="$file"
    if [[ -L "$file" ]]; then
        mutation_resolve_content_target "$file" || return 1
        resolved="$_MUTATION_RESOLVED_TARGET"
    fi
    transaction_add_file "$file" || return 1
    if [[ "$resolved" != "$file" ]]; then
        transaction_add_file "$resolved" || return 1
    fi
    local locked=0 rc=0
    if ! lock_acquire workstation-config 30; then
        log_error "Could not acquire the workstation-config lock — another configuration writer is active"
        return 1
    fi
    locked=1
    _theme_strip_legacy_zshrc "$resolved" || rc=1
    if [[ "$rc" == 0 ]]; then
        _theme_write_zshrc_block "$file" || rc=1
    fi
    if [[ "$rc" == 0 && "${TRANSACTION_DRY_RUN:-0}" != "1" ]]; then
        if command -v zsh >/dev/null 2>&1; then
            zsh -n "$resolved" || { log_error "Post-adoption zsh parse failed"; rc=1; }
        else
            bash -n "$resolved" || { log_error "Post-adoption bash parse failed"; rc=1; }
        fi
    fi
    if [[ "$locked" == 1 ]]; then
        lock_release workstation-config || rc=1
    fi
    return $rc
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
    local theme="$DEFAULT_THEME"
    local zshrc_only=0 enable_segments=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                TRANSACTION_DRY_RUN=1
                export TRANSACTION_DRY_RUN
                ;;
            --zshrc-only) zshrc_only=1 ;;
            --enable-segments) enable_segments=1 ;;
            -h|--help) usage ;;
            -*)
                log_error "Unknown option: $1"
                usage
                ;;
            *) theme="$1" ;;
        esac
        shift
    done

    case "$theme" in
        professional) ;;
        *)
            log_error "Unknown theme: $theme"
            usage
            ;;
    esac

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "DRY-RUN MODE — planning theme changes only, zero filesystem writes"
        echo
    fi

    lock_with_trap "workstation-mutation" 30 || exit 1

    log_info " Installing $theme theme..."
    echo

    # Validate dependencies
    if ! validate_dependencies; then
        log_error "Dependency validation failed"
        exit 1
    fi

    # Create automatic restore point before making changes (a write itself:
    # skipped in dry-run; scoped to the files this run touches)
    if [[ "${TRANSACTION_DRY_RUN:-0}" != "1" ]]; then
        log_info "📍 Creating automatic restore point..."
        local restore_point_name="auto_before_theme_${theme}_$(date +%Y%m%d_%H%M%S)"
        local config_files=()
        [[ "$zshrc_only" == "1" ]] || config_files+=("$HOME/.p10k.zsh")
        config_files+=("$HOME/.zshrc")
        if create_restore_point "$restore_point_name" "${config_files[@]}"; then
            log_debug "Restore point created: $restore_point_name"
        else
            log_warn "Could not create restore point, proceeding anyway..."
        fi
    fi

    # One transaction covers the p10k preset copy and the ~/.zshrc adoption so
    # a failure anywhere restores both pre-states (INT-1).
    transaction_start "theme_install_${theme}"

    if [[ "$zshrc_only" != "1" ]]; then
        transaction_add_file "$HOME/.p10k.zsh" || { transaction_rollback; exit 1; }
        if ! install_theme_config "$theme"; then
            log_error "Theme installation failed"
            transaction_rollback
            exit 1
        fi
    elif [[ ! -f "$HOME/.p10k.zsh" && "$enable_segments" == "1" ]]; then
        log_error "--enable-segments requires an existing ~/.p10k.zsh (run without --zshrc-only to install a preset)"
        transaction_rollback
        exit 1
    fi

    local zshrc="$HOME/.zshrc"
    if ! _theme_adopt_zshrc "$zshrc"; then
        log_error "\$HOME/.zshrc theme adoption failed"
        transaction_rollback
        exit 1
    fi

    if [[ "$enable_segments" == "1" && -f "$HOME/.p10k.zsh" ]]; then
        transaction_add_file "$HOME/.p10k.zsh" || { transaction_rollback; exit 1; }
        if ! _theme_enable_segments "$HOME/.p10k.zsh"; then
            log_error "Prompt segment enablement failed"
            transaction_rollback
            exit 1
        fi
        if [[ "${TRANSACTION_DRY_RUN:-0}" != "1" ]] && command -v zsh >/dev/null 2>&1; then
            if ! zsh -n "$HOME/.p10k.zsh"; then
                log_error "Post-edit p10k config parse failed"
                transaction_rollback
                exit 1
            fi
        fi
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
