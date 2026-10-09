#!/usr/bin/env bash
# ============================================================================
# Dependency Update Utility
# Part of Professional Development Terminal Setup
# ============================================================================
# Updates all version managers and their installed packages/versions.
#
# Safety (AX-6g, P3-1):
#   --dry-run prints every planned mutating command (git pull, nvm install,
#   rustup update, npm update) and executes none of them. Read-only version
#   queries (nvm current / version-remote, pyenv/goenv/jenv version listings,
#   rustc --version, rustup toolchain list) still run so the plan reflects the
#   real state; `npm audit` is skipped under --dry-run (it uploads the
#   dependency tree to the registry and writes npm logs).
#   Version-manager self-updates use `git -C <dir> pull --ff-only`, so a
#   diverged local clone is never merged into — the update is skipped with a
#   warning instead.
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

# Set by --dry-run: 1 = plan only, never execute a mutating command.
DRY_RUN=0

# Under --dry-run, print the planned mutating command and return 0 (the caller
# then skips executing it); otherwise return 1 so the caller executes it.
plan_only() {
    if [[ "$DRY_RUN" != "1" ]]; then
        return 1
    fi
    local plan
    printf -v plan '%q ' "$@"
    log_info "[DRY RUN] Would run: ${plan% }"
    return 0
}

# Fast-forward-only self-update of a git-cloned version manager.
# Args: name dir. Never merges; on failure warns with git's reason and returns
# 0 so the remaining managers are still processed.
update_git_clone() {
    local name="$1" dir="$2"

    if [[ ! -e "$dir/.git" ]]; then
        log_info "$name at $dir is not a git clone; skipping self-update"
        return 0
    fi

    if plan_only git -C "$dir" pull --ff-only --quiet; then
        return 0
    fi

    local git_err="" line="" reason=""
    if git_err=$(git -C "$dir" pull --ff-only --quiet 2>&1); then
        return 0
    fi

    # Prefer git's fatal/error line (e.g. "fatal: Not possible to
    # fast-forward, aborting."); fall back to its first non-empty line.
    while IFS= read -r line; do
        case "$line" in
            fatal:*|error:*)
                reason="$line"
                break
                ;;
        esac
        if [[ -z "$reason" && -n "$line" ]]; then
            reason="$line"
        fi
    done <<< "$git_err"
    log_warn "$name self-update skipped: 'git pull --ff-only' failed in $dir (local clone diverged / not fast-forward?): ${reason:-unknown error}"
    return 0
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
                if [[ "$DRY_RUN" == "1" ]]; then
                    log_info "[DRY RUN] Would ask to upgrade to $latest_lts"
                    plan_only nvm install --lts --reinstall-packages-from=current
                else
                    # EOF / non-interactive stdin means "no" — never abort.
                    local response=""
                    if ! read -r -p "   Upgrade to $latest_lts? [y/N]: " response; then
                        response=""
                        log_info "No interactive input; Node.js upgrade to $latest_lts skipped"
                    fi
                    if [[ "$response" =~ ^[Yy] ]]; then
                        nvm install --lts --reinstall-packages-from=current
                        log_success "Node.js upgraded to LTS"
                    fi
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
            update_git_clone "pyenv" "$HOME/.pyenv"
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
            update_git_clone "goenv" "$HOME/.goenv"
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
        if ! plan_only rustup update; then
            rustup update 2>/dev/null || log_warn "rustup update failed"
        fi

        # Show installed toolchains
        log_info "Installed toolchains:"
        rustup toolchain list 2>/dev/null || true

        if [[ "$DRY_RUN" == "1" ]]; then
            log_success "Rust update planned (dry run)"
        else
            log_success "Rust update complete"
        fi
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
            update_git_clone "jenv" "$HOME/.jenv"
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
        if [[ "$DRY_RUN" == "1" ]]; then
            log_info "[DRY RUN] In $SCRIPT_DIR:"
            plan_only npm update
            log_info "Running security audit..."
            plan_only npm audit --audit-level moderate
            log_success "npm package update planned (dry run)"
            echo
            return 0
        fi
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
Usage: $(basename "$0") [--dry-run] [TARGET]

Update all version managers and their packages.

Targets (at most one):
    --all           Update all version managers (default)
    --nvm           Update Node.js via nvm
    --pyenv         Update Python via pyenv
    --goenv         Update Go via goenv
    --rustup        Update Rust via rustup
    --jenv          Update Java via jenv
    --npm           Update npm packages only

Options:
    --dry-run       Print each planned mutating command (git pull, nvm install,
                    rustup update, npm update/audit) without executing any of
                    them. Read-only version queries still run.
    -h, --help      Show this help

Examples:
    $(basename "$0")                    # Update all
    $(basename "$0") --nvm              # Update Node.js only
    $(basename "$0") --rustup           # Update Rust only
    $(basename "$0") --dry-run          # Show what an update of all would do
    $(basename "$0") --dry-run --pyenv  # Show what a pyenv update would do

EOF
}

main() {
    local target="" arg

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║            Dependency Update Utility                       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo

    for arg in "$@"; do
        case "$arg" in
            --dry-run)
                DRY_RUN=1
                ;;
            --all|--nvm|--pyenv|--goenv|--rustup|--jenv|--npm)
                if [[ -n "$target" && "$target" != "$arg" ]]; then
                    log_error "Only one target may be given (got $target and $arg)"
                    show_usage
                    exit 1
                fi
                target="$arg"
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $arg"
                show_usage
                exit 1
                ;;
        esac
    done
    target="${target:---all}"

    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "DRY RUN: planned mutating commands are printed, none are executed"
        echo
    fi

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
    esac

    if [[ "$DRY_RUN" == "1" ]]; then
        log_success "Dry run complete — no changes made"
    else
        log_success "Dependency update complete"
    fi
}

main "$@"
