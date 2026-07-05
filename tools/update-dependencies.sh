#!/usr/bin/env bash
# ============================================================================
# Dependency Update Utility
# Part of Professional Development Terminal Setup
# ============================================================================
# Updates all version managers and their installed packages/versions.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source centralized logging
source "$SCRIPT_DIR/lib/logger.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
}

# ============================================================================
# Version Manager Updates
# ============================================================================

update_nvm() {
    log_info "Checking NVM..."

    # Source nvm if available
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
        # shellcheck source=/dev/null
        source "$NVM_DIR/nvm.sh"
    fi

    if command -v nvm >/dev/null 2>&1; then
        local current
        current=$(nvm current 2>/dev/null || echo "none")
        log_info "Current Node.js: $current"

        # Check for newer LTS version
        log_info "Checking for newer LTS version..."
        local latest_lts
        latest_lts=$(nvm version-remote --lts 2>/dev/null || echo "")

        if [[ -n "$latest_lts" ]]; then
            log_info "Latest LTS: $latest_lts"

            if [[ "$current" != "$latest_lts" ]]; then
                read -r -p "   Upgrade to $latest_lts? [y/N]: " response
                if [[ "$response" =~ ^[Yy] ]]; then
                    nvm install --lts --reinstall-packages-from=current
                    log_success "Node.js upgraded to LTS"
                fi
            else
                log_success "Already on latest LTS"
            fi
        fi
    else
        log_warn "NVM not installed or not loaded"
    fi
    echo
}

update_pyenv() {
    log_info "Checking pyenv..."

    if command -v pyenv >/dev/null 2>&1; then
        local current
        current=$(pyenv version-name 2>/dev/null || echo "system")
        log_info "Current Python: $current"

        # Update pyenv itself
        if [[ -d "$HOME/.pyenv" ]] && command -v git >/dev/null 2>&1; then
            log_info "Updating pyenv..."
            (cd "$HOME/.pyenv" && git pull --quiet 2>/dev/null) || true
        fi

        # Check for newer Python versions
        log_info "Latest Python versions available:"
        pyenv install --list 2>/dev/null | grep -E '^\s+3\.(11|12|13)\.[0-9]+$' | tail -5 || true

        log_success "pyenv check complete"
    else
        log_warn "pyenv not installed"
    fi
    echo
}

update_goenv() {
    log_info "Checking goenv..."

    if command -v goenv >/dev/null 2>&1; then
        local current
        current=$(goenv version-name 2>/dev/null || echo "system")
        log_info "Current Go: $current"

        # Update goenv itself
        if [[ -d "$HOME/.goenv" ]] && command -v git >/dev/null 2>&1; then
            log_info "Updating goenv..."
            (cd "$HOME/.goenv" && git pull --quiet 2>/dev/null) || true
        fi

        # Check for newer Go versions
        log_info "Latest Go versions available:"
        goenv install --list 2>/dev/null | grep -E '^\s+1\.(21|22|23)\.[0-9]+$' | tail -5 || true

        log_success "goenv check complete"
    else
        log_warn "goenv not installed"
    fi
    echo
}

update_rustup() {
    log_info "Checking Rust/rustup..."

    if command -v rustup >/dev/null 2>&1; then
        local current
        current=$(rustc --version 2>/dev/null || echo "unknown")
        log_info "Current Rust: $current"

        # Update rustup and toolchains
        log_info "Updating Rust toolchain..."
        rustup update 2>/dev/null || log_warn "rustup update failed"

        # Show installed toolchains
        log_info "Installed toolchains:"
        rustup toolchain list 2>/dev/null || true

        log_success "Rust update complete"
    else
        log_warn "rustup not installed"
    fi
    echo
}

update_jenv() {
    log_info "Checking jenv..."

    if command -v jenv >/dev/null 2>&1; then
        local current
        current=$(jenv version-name 2>/dev/null || echo "system")
        log_info "Current Java: $current"

        # Update jenv itself
        if [[ -d "$HOME/.jenv" ]] && command -v git >/dev/null 2>&1; then
            log_info "Updating jenv..."
            (cd "$HOME/.jenv" && git pull --quiet 2>/dev/null) || true
        fi

        # Show installed Java versions
        log_info "Installed Java versions:"
        jenv versions 2>/dev/null || true

        log_success "jenv check complete"
    else
        log_warn "jenv not installed"
    fi
    echo
}

update_npm_packages() {
    log_info "Checking npm packages..."

    if [[ -f "$SCRIPT_DIR/package.json" ]] && command -v npm >/dev/null 2>&1; then
        log_info "Updating npm packages in project..."
        (cd "$SCRIPT_DIR" && npm update 2>/dev/null) || log_warn "npm update failed"

        log_info "Running security audit..."
        (cd "$SCRIPT_DIR" && npm audit --audit-level moderate 2>/dev/null) || log_info "Audit complete"

        log_success "npm packages updated"
    else
        log_info "No package.json or npm not available"
    fi
    echo
}

# ============================================================================
# Main
# ============================================================================

show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Update all version managers and their packages.

Options:
    --all           Update all version managers (default)
    --nvm           Update Node.js via nvm
    --pyenv         Update Python via pyenv
    --goenv         Update Go via goenv
    --rustup        Update Rust via rustup
    --jenv          Update Java via jenv
    --npm           Update npm packages only
    -h, --help      Show this help

Examples:
    $(basename "$0")              # Update all
    $(basename "$0") --nvm        # Update Node.js only
    $(basename "$0") --rustup     # Update Rust only

EOF
}

main() {
    local target="${1:---all}"

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║            Dependency Update Utility                       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo

    case "$target" in
        --all)
            update_nvm
            update_pyenv
            update_goenv
            update_rustup
            update_jenv
            update_npm_packages
            ;;
        --nvm)
            update_nvm
            ;;
        --pyenv)
            update_pyenv
            ;;
        --goenv)
            update_goenv
            ;;
        --rustup)
            update_rustup
            ;;
        --jenv)
            update_jenv
            ;;
        --npm)
            update_npm_packages
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $target"
            show_usage
            exit 1
            ;;
    esac

    log_success "Dependency update complete"
}

main "$@"
