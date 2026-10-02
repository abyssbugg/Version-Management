#!/usr/bin/env bash
# shellcheck disable=SC1091
# ============================================================================
# Global Node.js Symlink Updater
# Part of Professional Development Terminal Setup
# ============================================================================
# Updates global Node.js symlinks when switching NVM versions.
# Ensures desktop apps (like Electron apps) can access the current Node.js.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=true

# Source logging
source "$SCRIPT_DIR/lib/logger.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
}

# ============================================================================
# Safety Checks
# ============================================================================

describe_current_target() {
    local path="$1"

    if [[ -L "$path" ]]; then
        readlink "$path" 2>/dev/null || echo "unknown"
    elif [[ -e "$path" ]]; then
        echo "regular file"
    else
        echo "missing"
    fi
}

show_symlink_plan() {
    local node_path="$1"
    local npm_path="$2"
    local npx_path="$3"

    log_info "Plan for /usr/local/bin symlinks:"
    echo "  /usr/local/bin/node: $(describe_current_target /usr/local/bin/node) → $node_path"
    echo "  /usr/local/bin/npm:  $(describe_current_target /usr/local/bin/npm) → $npm_path"
    echo "  /usr/local/bin/npx:  $(describe_current_target /usr/local/bin/npx) → $npx_path"
}

backup_existing_symlinks() {
    local backup_dir="/tmp/node-symlinks-backup-$(date +%Y%m%d%H%M%S)"
    local backed_up=0

    mkdir -p "$backup_dir"

    for cmd in node npm npx; do
        if [[ -L "/usr/local/bin/$cmd" ]]; then
            # Backup symlink
            cp -P "/usr/local/bin/$cmd" "$backup_dir/"
            log_info "Backed up: /usr/local/bin/$cmd"
            backed_up=$(( backed_up + 1 ))
        elif [[ -f "/usr/local/bin/$cmd" ]]; then
            # Backup regular file
            cp "/usr/local/bin/$cmd" "$backup_dir/"
            log_warn "Backed up (non-symlink): /usr/local/bin/$cmd"
            backed_up=$(( backed_up + 1 ))
        fi
    done

    if [[ $backed_up -gt 0 ]]; then
        log_success "Backups saved to: $backup_dir"
        echo "$backup_dir"
    fi
}

verify_nvm_installation() {
    # Source nvm if not already available
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
        # shellcheck source=/dev/null
        source "$NVM_DIR/nvm.sh"
    fi

    if ! command -v nvm >/dev/null 2>&1; then
        log_error "NVM not found. Please install NVM first."
        exit 1
    fi
}

# ============================================================================
# Main Function
# ============================================================================

update_global_node_symlinks() {
    verify_nvm_installation

    local current_version
    current_version=$(nvm current 2>/dev/null || echo "N/A")

    if [[ "$current_version" == "system" || "$current_version" == "N/A" || "$current_version" == "none" ]]; then
        log_error "No NVM-managed Node.js version is active"
        log_info "Run: nvm use <version> or nvm use --lts"
        exit 1
    fi

    # Remove 'v' prefix if present
    current_version="${current_version#v}"

    local node_path="$NVM_DIR/versions/node/v$current_version/bin/node"
    local npm_path="$NVM_DIR/versions/node/v$current_version/bin/npm"
    local npx_path="$NVM_DIR/versions/node/v$current_version/bin/npx"

    # Verify paths exist
    if [[ ! -f "$node_path" ]]; then
        log_error "Node.js binary not found at: $node_path"
        exit 1
    fi

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║            Global Node.js Symlink Updater                  ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo
    log_info "Current NVM version: v$current_version"
    echo

    show_symlink_plan "$node_path" "$npm_path" "$npx_path"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo
        log_info "Dry run only. Re-run with --confirm to apply this plan."
        exit 0
    fi

    # Backup existing
    local backup_path
    backup_path=$(backup_existing_symlinks)

    # Create symlinks
    echo
    log_info "Creating symlinks..."

    if [[ -f "$node_path" ]]; then
        sudo ln -sf "$node_path" /usr/local/bin/node
        log_success "Created: /usr/local/bin/node -> $node_path"
    fi

    if [[ -f "$npm_path" ]]; then
        sudo ln -sf "$npm_path" /usr/local/bin/npm
        log_success "Created: /usr/local/bin/npm -> $npm_path"
    fi

    if [[ -f "$npx_path" ]]; then
        sudo ln -sf "$npx_path" /usr/local/bin/npx
        log_success "Created: /usr/local/bin/npx -> $npx_path"
    fi

    echo
    log_success "Global symlinks updated to Node.js v$current_version"
    echo
    echo "Desktop apps can now access:"
    echo "  node: $(which node 2>/dev/null || echo 'not found')"
    echo "  npm:  $(which npm 2>/dev/null || echo 'not found')"
    echo "  npx:  $(which npx 2>/dev/null || echo 'not found')"

    if [[ -n "${backup_path:-}" ]]; then
        echo
        echo "To restore previous symlinks:"
        echo "  sudo cp -P $backup_path/* /usr/local/bin/"
    fi
}

# ============================================================================
# Restore Function
# ============================================================================

restore_symlinks() {
    local backup_dir="$1"

    if [[ ! -d "$backup_dir" ]]; then
        log_error "Backup directory not found: $backup_dir"
        exit 1
    fi

    log_info "Restoring symlinks from: $backup_dir"

    for cmd in node npm npx; do
        if [[ -e "$backup_dir/$cmd" ]]; then
            sudo cp -P "$backup_dir/$cmd" /usr/local/bin/
            log_success "Restored: /usr/local/bin/$cmd"
        fi
    done

    log_success "Symlinks restored"
}

# ============================================================================
# Usage
# ============================================================================

show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Update global Node.js symlinks for desktop app compatibility.

Options:
    update          Update symlinks to current NVM version (default)
    restore PATH    Restore symlinks from backup directory
    status          Show current symlink status
    -n, --dry-run   Print the plan without changing anything (default)
    --confirm       Apply the planned privileged changes
    -h, --help      Show this help

Examples:
    $(basename "$0")                              # Show update plan
    $(basename "$0") --confirm                    # Apply update plan
    $(basename "$0") restore /tmp/backup-123      # Show restore plan
    $(basename "$0") --confirm restore /tmp/backup-123
    $(basename "$0") status                       # Check current status

Why use this?
    Desktop apps (Electron, VS Code extensions, etc.) often look for
    Node.js in /usr/local/bin/ instead of using NVM's version. This
    script creates symlinks so those apps use your NVM-managed Node.js.

Note:
    The dev auto-activate hook (lib/auto-activate.sh) keeps these
    symlinks in sync automatically whenever you switch Node versions
    via nvm use, nvm install, or by cd-ing into a project with
    .nvmrc / .node-version.  Run this script only for the initial
    setup or to force a manual update.

EOF
}

show_status() {
    echo "Current symlink status:"
    echo

    for cmd in node npm npx; do
        local path="/usr/local/bin/$cmd"
        if [[ -L "$path" ]]; then
            local target
            target=$(readlink "$path" 2>/dev/null || echo "unknown")
            echo "  $cmd: $path -> $target"
        elif [[ -f "$path" ]]; then
            echo "  $cmd: $path (regular file, not symlink)"
        else
            echo "  $cmd: not present in /usr/local/bin/"
        fi
    done
}

show_restore_plan() {
    local backup_dir="$1"

    if [[ ! -d "$backup_dir" ]]; then
        log_error "Backup directory not found: $backup_dir"
        exit 1
    fi

    log_info "Plan to restore symlinks from: $backup_dir"
    for cmd in node npm npx; do
        if [[ -e "$backup_dir/$cmd" ]]; then
            echo "  /usr/local/bin/$cmd: $(describe_current_target "/usr/local/bin/$cmd") → $backup_dir/$cmd"
        fi
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        echo
        log_info "Dry run only. Re-run with --confirm to apply this plan."
        exit 0
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    local command="update"
    local restore_path=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            --confirm)
                DRY_RUN=false
                shift
                ;;
            update|status)
                command="$1"
                shift
                ;;
            restore)
                command="restore"
                shift
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        -n|--dry-run)
                            DRY_RUN=true
                            shift
                            ;;
                        --confirm)
                            DRY_RUN=false
                            shift
                            ;;
                        --*)
                            log_error "Unknown option or command: $1"
                            show_usage
                            exit 1
                            ;;
                        *)
                            if [[ -z "$restore_path" ]]; then
                                restore_path="$1"
                                shift
                            else
                                log_error "Unknown option or command: $1"
                                show_usage
                                exit 1
                            fi
                            ;;
                    esac
                done
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option or command: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    case "$command" in
        update|"")
            update_global_node_symlinks
            ;;
        restore)
            if [[ -z "$restore_path" ]]; then
                log_error "Please specify backup directory"
                exit 1
            fi
            show_restore_plan "$restore_path"
            restore_symlinks "$restore_path"
            ;;
        status)
            show_status
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
