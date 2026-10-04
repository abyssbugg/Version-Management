#!/usr/bin/env bash
# shellcheck disable=SC1091
# ============================================================================
# Global Node.js Symlink Updater
# Part of Professional Development Terminal Setup
# ============================================================================
# Updates global Node.js symlinks when switching NVM versions.
# Ensures desktop apps (like Electron apps) can access the current Node.js.
#
# M4 adoption (finding P3-1): the privileged mutation sequence runs under a
# lib/backup.sh transaction — hash-verified registration of every
# /usr/local/bin destination BEFORE mutation, audit-journal records via the
# primitive, commit on success, rollback + loud nonzero on failure — with a
# byte-compare skip so idempotent reruns do not churn /usr/local/bin.
# Plan-by-default, the --confirm gate, and the sudo invocation path itself
# are unchanged.
# ============================================================================

# Only set strict mode when executing directly (not when sourced for testing —
# the M4 test matrix drives the skip predicate by sourcing this file).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=true

# Source logging from a CLEAN function slate: inherited (export -f) logger
# functions reference color variables that do not travel with them — under
# direct-execution set -u that combination aborts every log call (M4 lesson).
unset -f log_info log_warn log_error log_success log_debug init_logger 2>/dev/null || true
source "$SCRIPT_DIR/lib/logger.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
}

# Transaction + audit-journal primitives (M4/P3-1). Sourced unconditionally:
# inherited exported functions defeat declare -f guards across process
# boundaries and crash under set -u (M4 lesson).
source "$SCRIPT_DIR/lib/backup.sh" || {
    log_error "Cannot load lib/backup.sh (transaction primitives)"
    exit 1
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
    local backup_dir="${TMPDIR:-/tmp}/node-symlinks-backup-$(date +%Y%m%d%H%M%S)"
    local backed_up=0

    # Explicit check, not set -e: this function is invoked via command
    # substitution, and set -e is suppressed inside those subshells — a bare
    # failing mkdir here would be silently swallowed (reproduced in the M4
    # matrix, case c1).
    if ! mkdir -p "$backup_dir"; then
        log_error "Cannot create backup directory: $backup_dir"
        return 1
    fi

    for cmd in node npm npx; do
        if [[ -L "/usr/local/bin/$cmd" ]]; then
            # Backup symlink
            if cp -P "/usr/local/bin/$cmd" "$backup_dir/"; then
                log_info "Backed up: /usr/local/bin/$cmd"
                backed_up=$(( backed_up + 1 ))
            else
                log_warn "Could not back up symlink: /usr/local/bin/$cmd (transaction pre-state remains authoritative)"
            fi
        elif [[ -f "/usr/local/bin/$cmd" ]]; then
            # Backup regular file
            if cp "/usr/local/bin/$cmd" "$backup_dir/"; then
                log_warn "Backed up (non-symlink): /usr/local/bin/$cmd"
                backed_up=$(( backed_up + 1 ))
            else
                log_warn "Could not back up file: /usr/local/bin/$cmd (transaction pre-state remains authoritative)"
            fi
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
# Transaction Adoption Helpers (M4, finding P3-1)
# ============================================================================

# Portable byte-identical check (M4 lesson): the Buildkite hosted Linux agent
# image does NOT ship `cmp` — a missing cmp would silently degrade the
# idempotent skip. cmp when present, sha256sum/shasum fallback otherwise.
symlink_bytes_identical() {
    local a="$1" b="$2"
    [[ -f "$a" && -f "$b" ]] || return 1
    if command -v cmp >/dev/null 2>&1 && cmp -s "$a" "$b"; then
        return 0
    fi
    local ha hb
    ha=$(_txn_sha256 "$a")
    hb=$(_txn_sha256 "$b")
    [[ -n "$ha" && "$ha" == "$hb" ]]
}

# Skip predicate (M4 idempotency): true when the destination already carries
# the desired content — either the link points at the exact desired binary or
# the resolved bytes are identical (stale-path link or regular-file dest).
symlink_dest_matches() {
    local dest="$1" src="$2"
    [[ -e "$src" ]] || return 1
    if [[ -L "$dest" ]] && [[ "$(readlink "$dest" 2>/dev/null)" == "$src" ]]; then
        return 0
    fi
    [[ -e "$dest" ]] && symlink_bytes_identical "$src" "$dest"
}

# Capture a destination's pre-mutation state as a rollback marker: the old
# symlink target, a regular-file marker, or absent.
_symlink_prestate() {
    local dest="$1"
    if [[ -L "$dest" ]]; then
        readlink "$dest" 2>/dev/null || echo "unknown"
    elif [[ -e "$dest" ]]; then
        printf '__REGULAR_FILE__'
    else
        printf '__ABSENT__'
    fi
}

# Best-effort privileged restore of every destination's pre-mutation state,
# through the same sudo channel as the mutation. The transaction primitive's
# own rollback is unprivileged and cannot write /usr/local/bin — its journal
# entry records the outcome either way. Never aborts: every step is logged,
# and success is never claimed for a failed restore.
rollback_node_symlink_targets() {
    local pre_node="$1" pre_npm="$2" pre_npx="$3" backup_dir="$4"
    local cmd prev dest
    for cmd in node npm npx; do
        dest="/usr/local/bin/$cmd"
        case "$cmd" in
            node) prev="$pre_node" ;;
            npm)  prev="$pre_npm" ;;
            npx)  prev="$pre_npx" ;;
            *)    prev="__ABSENT__" ;;
        esac
        case "$prev" in
            __ABSENT__)
                log_info "Rollback: removing $dest (absent before this run)"
                sudo rm -f "$dest" || log_error "Rollback: could not remove $dest"
                ;;
            __REGULAR_FILE__)
                if [[ -n "$backup_dir" && -e "$backup_dir/$cmd" ]]; then
                    log_info "Rollback: restoring regular file $dest from backup"
                    sudo cp "$backup_dir/$cmd" "$dest" || log_error "Rollback: could not restore $dest"
                else
                    log_error "Rollback: no backup available for regular file $dest — manual restore required"
                fi
                ;;
            *)
                log_info "Rollback: relinking $dest -> $prev"
                sudo ln -sf "$prev" "$dest" || log_error "Rollback: could not relink $dest"
                ;;
        esac
    done
}

# Failure path for the privileged mutation sequence: attempt the privileged
# restore, journal the rollback via the primitive, exit loud nonzero.
_symlink_apply_failed() {
    local pre_node="$1" pre_npm="$2" pre_npx="$3" backup_dir="$4" failed_cmd="$5"
    log_error "FAILED: privileged link update for /usr/local/bin/$failed_cmd"
    log_error "Rolling back symlink update..."
    rollback_node_symlink_targets "$pre_node" "$pre_npm" "$pre_npx" "$backup_dir"
    transaction_rollback >/dev/null 2>&1 || true
    log_error "Symlink update FAILED and was rolled back — see the audit journal"
    exit 1
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

    # ── Apply: transaction-wrapped privileged mutation (M4, finding P3-1) ────
    # Plan mode never reaches this point. With the lib's plan-only mode
    # (TRANSACTION_DRY_RUN=1) the whole apply path stays write-free: a dry-run
    # transaction record is journaled and nothing else happens.
    local backup_path=""
    if [[ "${TRANSACTION_DRY_RUN:-0}" != "1" ]]; then
        # Secondary backup kept for the human-facing restore hint below.
        # Explicit check, not set -e: a failing assignment from command
        # substitution must be surfaced here, not swallowed.
        if ! backup_path=$(backup_existing_symlinks); then
            log_error "Backup failed — refusing to mutate without a recovery point"
            exit 1
        fi
    fi

    transaction_start "update_node_symlinks" || exit 1

    # Capture + register the pre-mutation state of every destination BEFORE
    # any mutation. The transaction stores symlink targets / file bytes
    # hash-verified (the rollback source of truth); the shell variables drive
    # the privileged restore, which /usr/local/bin requires (the primitive's
    # own rollback is unprivileged and cannot write there).
    local pre_node pre_npm pre_npx
    pre_node=$(_symlink_prestate /usr/local/bin/node)
    pre_npm=$(_symlink_prestate /usr/local/bin/npm)
    pre_npx=$(_symlink_prestate /usr/local/bin/npx)

    local dest reg_fail=0
    for dest in /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx; do
        if ! transaction_add_file "$dest"; then
            log_error "Cannot register pre-state of $dest — refusing to mutate"
            reg_fail=1
        fi
    done
    if [[ $reg_fail -eq 1 ]]; then
        transaction_rollback >/dev/null 2>&1 || true
        log_error "Aborted before mutation — transaction rolled back"
        exit 1
    fi

    # Create symlinks. The privileged invocation is unchanged; it is now
    # guarded by the byte-compare skip (idempotent reruns) and the
    # transaction failure path.
    echo
    local mutated=0 skipped=0
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would update /usr/local/bin/{node,npm,npx} -> NVM v$current_version binaries (zero writes)"
    else
        log_info "Creating symlinks..."

        if [[ -f "$node_path" ]]; then
            if symlink_dest_matches /usr/local/bin/node "$node_path"; then
                log_info "already identical: /usr/local/bin/node -> $node_path"
                skipped=$(( skipped + 1 ))
            elif sudo ln -sf "$node_path" /usr/local/bin/node; then
                log_success "Created: /usr/local/bin/node -> $node_path"
                mutated=$(( mutated + 1 ))
            else
                _symlink_apply_failed "$pre_node" "$pre_npm" "$pre_npx" "$backup_path" "node"
            fi
        fi

        if [[ -f "$npm_path" ]]; then
            if symlink_dest_matches /usr/local/bin/npm "$npm_path"; then
                log_info "already identical: /usr/local/bin/npm -> $npm_path"
                skipped=$(( skipped + 1 ))
            elif sudo ln -sf "$npm_path" /usr/local/bin/npm; then
                log_success "Created: /usr/local/bin/npm -> $npm_path"
                mutated=$(( mutated + 1 ))
            else
                _symlink_apply_failed "$pre_node" "$pre_npm" "$pre_npx" "$backup_path" "npm"
            fi
        fi

        if [[ -f "$npx_path" ]]; then
            if symlink_dest_matches /usr/local/bin/npx "$npx_path"; then
                log_info "already identical: /usr/local/bin/npx -> $npx_path"
                skipped=$(( skipped + 1 ))
            elif sudo ln -sf "$npx_path" /usr/local/bin/npx; then
                log_success "Created: /usr/local/bin/npx -> $npx_path"
                mutated=$(( mutated + 1 ))
            else
                _symlink_apply_failed "$pre_node" "$pre_npm" "$pre_npx" "$backup_path" "npx"
            fi
        fi
    fi

    transaction_commit

    echo
    if [[ $skipped -eq 3 ]]; then
        log_success "All /usr/local/bin destinations already identical — no changes made"
    else
        log_success "Global symlinks updated to Node.js v$current_version ($mutated changed, $skipped already identical)"
    fi
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

    # M4/P3-1: the restore path is a privileged mutation too — same
    # transaction treatment as the update path.
    transaction_start "restore_node_symlinks" || exit 1

    local pre_node pre_npm pre_npx
    pre_node=$(_symlink_prestate /usr/local/bin/node)
    pre_npm=$(_symlink_prestate /usr/local/bin/npm)
    pre_npx=$(_symlink_prestate /usr/local/bin/npx)

    local dest reg_fail=0
    for dest in /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx; do
        if ! transaction_add_file "$dest"; then
            log_error "Cannot register pre-state of $dest — refusing to mutate"
            reg_fail=1
        fi
    done
    if [[ $reg_fail -eq 1 ]]; then
        transaction_rollback >/dev/null 2>&1 || true
        log_error "Aborted before mutation — transaction rolled back"
        exit 1
    fi

    local cmd
    for cmd in node npm npx; do
        if [[ -e "$backup_dir/$cmd" ]]; then
            if sudo cp -P "$backup_dir/$cmd" /usr/local/bin/; then
                log_success "Restored: /usr/local/bin/$cmd"
            else
                log_error "FAILED: privileged restore of /usr/local/bin/$cmd"
                rollback_node_symlink_targets "$pre_node" "$pre_npm" "$pre_npx" ""
                transaction_rollback >/dev/null 2>&1 || true
                log_error "Restore FAILED and was rolled back — see the audit journal"
                exit 1
            fi
        fi
    done

    transaction_commit
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

# Execute only when run directly — sourcing (the M4 test matrix) must not
# mutate anything; it exposes the helpers for predicate-level testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
