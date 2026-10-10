#!/usr/bin/env bash
# shellcheck disable=SC1091
# ============================================================================
# Emergency Recovery Script
# Part of Professional Development Terminal Setup
# ============================================================================
# Restores system to a known-good state when things go wrong.
#
# M4 adopter (P3-1): restore_file and reset_to_defaults mutations run under
# backup transactions (lib/backup.sh) — hash-verified rollback restoring the
# pre-operation state byte-identically on any failure, byte-compare
# verification of every restored file, and --dry-run planning with zero
# writes. Every target is registered with the transaction BEFORE mutation.
# Preserved by design: the menu flow, the typed-RESET confirm, and the
# .emergency-<ts> backup convention (belt-and-braces archaeology alongside
# the transaction guarantee).
# ============================================================================

# Only set strict mode when executing directly (not when sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
fi

# Resolve lib paths from THIS file's location (never an inherited SCRIPT_DIR,
# which lib sources and test harnesses may clobber).
_EMERGENCY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source dependencies UNCONDITIONALLY (inherited exported logger functions
# defeat the fallback definitions across process boundaries).
if [[ -f "${_EMERGENCY_ROOT}/lib/logger.sh" ]]; then
    source "${_EMERGENCY_ROOT}/lib/logger.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo "[DEBUG] $*"; return 0; }
fi

if ! source "${_EMERGENCY_ROOT}/lib/backup.sh"; then
    log_error "Cannot load lib/backup.sh (transaction framework)"
    exit 1
fi

# ============================================================================
# Configuration
# ============================================================================

BACKUP_DIR="${BACKUP_DIR:-$HOME/.config/version-manager/backups}"
RESTORE_POINTS_DIR="${RESTORE_POINTS_DIR:-$HOME/.config/version-manager/restore-points}"

# Files we can recover
readonly RECOVERABLE_FILES=(
    "$HOME/.zshrc"
    "$HOME/.p10k.zsh"
    "$HOME/.bashrc"
    "$HOME/.config/Code/User/settings.json"
)

# ============================================================================
# Transaction helpers (P3-1)
# ============================================================================

# Byte-identical verdict for two files (cmp when present, hash fallback).
# The verdict must propagate — a swallowed comparison result would make every
# verification pass unconditionally.
_er_files_identical() {
    local a="$1" b="$2"
    [[ -f "$a" && -f "$b" ]] || return 1
    if command -v cmp >/dev/null 2>&1; then
        if cmp -s "$a" "$b"; then
            return 0
        else
            return 1
        fi
    fi
    local ha hb
    ha=$(sha256sum "$a" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$a" 2>/dev/null | awk '{print $1}')
    hb=$(sha256sum "$b" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$b" 2>/dev/null | awk '{print $1}')
    [[ -n "$ha" && "$ha" == "$hb" ]]
}

# Copy <reference>'s permission bits onto <file>; a missing reference means
# a new file (0644). GNU stat is probed first: on Linux a BSD-first
# `stat -f '%Lp'` prints file-system data (GNU -f means --file-system), the
# probed mode was garbage and the restored file kept mktemp's 0600 (AX-21).
# Fails closed on an unreadable mode.
_er_copy_mode() {
    local ref="$1" file="$2" mode
    if [[ ! -e "$ref" ]]; then
        chmod 644 "$file"
        return
    fi
    if ! mode=$(stat -c '%a' "$ref" 2>/dev/null); then
        mode=$(stat -f '%Lp' "$ref" 2>/dev/null) || return 1
    fi
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    chmod "$mode" "$file"
}

# Shared failure path: roll the active transaction back (hash-verified,
# byte-identical) and surface rollback errors loudly.
_er_rollback() {
    if ! transaction_rollback; then
        log_error "Rollback reported errors — inspect $HOME/.config-backups/transactions"
    fi
}

# ============================================================================
# UI Functions
# ============================================================================

show_header() {
    echo
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║            Emergency Recovery System                       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo
}

show_menu() {
    echo "Available recovery options:"
    echo
    echo "  1) Restore .zshrc from latest backup"
    echo "  2) Restore .p10k.zsh from latest backup"
    echo "  3) Restore VS Code settings from backup"
    echo "  4) Restore ALL configuration files"
    echo "  5) List available backups"
    echo "  6) List restore points"
    echo "  7) Restore from specific backup"
    echo "  8) Restore from restore point"
    echo "  9) Reset to factory defaults"
    echo "  10) Diagnose current state"
    echo "  0) Exit"
    echo
}

# ============================================================================
# Backup Discovery
# ============================================================================

find_latest_backup() {
    local file_pattern="$1"

    if [[ -d "$BACKUP_DIR" ]]; then
        find "$BACKUP_DIR" -name "*${file_pattern}*" -type f 2>/dev/null | \
            sort -r | head -1
    fi
}

list_all_backups() {
    echo "Available Backups:"
    echo "=================="
    echo

    if [[ -d "$BACKUP_DIR" ]]; then
        local count=0
        while IFS= read -r backup; do
            count=$(( count + 1 ))
            local basename
            basename=$(basename "$backup")
            local mtime
            mtime=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$backup" 2>/dev/null || \
                    stat -c "%y" "$backup" 2>/dev/null | cut -d'.' -f1 || echo "unknown")
            echo "  $count) $basename"
            echo "     Modified: $mtime"
            echo "     Path: $backup"
            echo
        done < <(find "$BACKUP_DIR" -type f -name "*.backup" -o -name "*.bak" 2>/dev/null | sort -r | head -20)

        if [[ $count -eq 0 ]]; then
            echo "  No backups found in $BACKUP_DIR"
        fi
    else
        echo "  Backup directory does not exist: $BACKUP_DIR"
    fi
}

list_restore_points() {
    echo "Available Restore Points:"
    echo "========================="
    echo

    if [[ -d "$RESTORE_POINTS_DIR" ]]; then
        local count=0
        for point_dir in "$RESTORE_POINTS_DIR"/*/; do
            [[ -d "$point_dir" ]] || continue
            count=$(( count + 1 ))
            local point_name
            point_name=$(basename "$point_dir")
            local metadata="$point_dir/metadata.txt"

            echo "  $count) $point_name"
            if [[ -f "$metadata" ]]; then
                echo "     $(head -2 "$metadata" | tail -1)"
            fi
            echo "     Files: $(find "$point_dir" -type f ! -name "metadata.txt" | wc -l | tr -d ' ')"
            echo
        done

        if [[ $count -eq 0 ]]; then
            echo "  No restore points found"
        fi
    else
        echo "  No restore points directory exists"
    fi
}

# ============================================================================
# Recovery Functions
# ============================================================================

# Restore a single file from a backup under a transaction (P3-1): the target
# is registered BEFORE any mutation so a failure rolls back the pre-restore
# state byte-identically (or removes the file entirely if the restore created
# it). The .emergency-<ts> backup is kept as belt-and-braces. Dry-run plans
# with zero writes.
restore_file() {
    local backup_path="$1"
    local target_path="$2"

    if [[ ! -f "$backup_path" ]]; then
        log_error "Backup file not found: $backup_path"
        return 1
    fi

    # Dry-run: plan only — journal the plan, list the targets, zero writes.
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        transaction_start "emergency_restore" || return 1
        transaction_add_file "$target_path" || { _er_rollback; return 1; }
        log_info "[dry-run] would restore: $target_path (from: $backup_path)"
        if [[ -f "$target_path" ]]; then
            log_info "[dry-run] would create emergency backup: ${target_path}.emergency-<timestamp>"
        fi
        transaction_commit || return 1
        return 0
    fi

    transaction_start "emergency_restore" || return 1

    if ! transaction_add_file "$target_path"; then
        _er_rollback
        return 1
    fi

    # Belt-and-braces emergency backup (convention preserved alongside the
    # transaction — the rollback is the guarantee, this is the archaeology).
    if [[ -f "$target_path" ]]; then
        local emergency_backup="${target_path}.emergency-$(date +%Y%m%d%H%M%S)"
        if ! cp "$target_path" "$emergency_backup"; then
            log_error "Cannot create emergency backup: $emergency_backup"
            _er_rollback
            return 1
        fi
        log_info "Created emergency backup: $emergency_backup"
    fi

    local target_dir
    target_dir=$(dirname "$target_path")
    if [[ ! -d "$target_dir" ]]; then
        log_error "Target directory missing: $target_dir"
        _er_rollback
        return 1
    fi

    # Stage in the target directory and rename (atomic replace). The rename
    # is the failure point for hostile targets — an immutable target fails
    # LOUD here and the rollback below restores the pre-state.
    local tmp
    tmp=$(mktemp "$target_dir/.vms-restore.XXXXXX") || {
        log_error "Cannot stage restore in $target_dir"
        _er_rollback
        return 1
    }
    if ! cp "$backup_path" "$tmp"; then
        rm -f "$tmp" 2>/dev/null || true
        log_error "Cannot stage backup content: $backup_path"
        _er_rollback
        return 1
    fi
    # Preserve the target's existing mode (mktemp creates 0600); a new
    # target gets 0644. AX-21: GNU-first probe, fail closed.
    if ! _er_copy_mode "$target_path" "$tmp"; then
        rm -f "$tmp" 2>/dev/null || true
        log_error "Cannot preserve the mode of $target_path"
        _er_rollback
        return 1
    fi
    if ! mv "$tmp" "$target_path"; then
        rm -f "$tmp" 2>/dev/null || true
        log_error "Restore FAILED for: $target_path"
        _er_rollback
        return 1
    fi

    # Verify: the restored bytes must match the backup source.
    if ! _er_files_identical "$backup_path" "$target_path"; then
        log_error "Post-restore verification FAILED: $target_path differs from $backup_path"
        _er_rollback
        return 1
    fi

    if ! transaction_commit; then
        log_error "Transaction commit failed for: $target_path"
        return 1
    fi
    log_success "Restored: $target_path"
    return 0
}

restore_zshrc() {
    local backup
    backup=$(find_latest_backup "zshrc")

    if [[ -n "$backup" ]]; then
        restore_file "$backup" "$HOME/.zshrc"
    else
        log_error "No .zshrc backup found"
        return 1
    fi
}

restore_p10k() {
    local backup
    backup=$(find_latest_backup "p10k")

    if [[ -n "$backup" ]]; then
        restore_file "$backup" "$HOME/.p10k.zsh"
    else
        log_error "No .p10k.zsh backup found"
        return 1
    fi
}

restore_vscode() {
    local backup
    backup=$(find_latest_backup "settings.json")

    if [[ -z "$backup" ]]; then
        backup=$(find_latest_backup "vscode")
    fi

    if [[ -z "$backup" ]]; then
        log_error "No VS Code settings backup found"
        return 1
    fi

    local vscode_dir="$HOME/.config/Code/User"
    # Dry-run: zero writes — plan the directory creation instead.
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would create (if missing): $vscode_dir"
    else
        mkdir -p "$vscode_dir"
    fi
    restore_file "$backup" "$vscode_dir/settings.json"
}

restore_all() {
    log_info "Restoring all configuration files..."

    local restored=0
    local failed=0

    if restore_zshrc 2>/dev/null; then
        restored=$(( restored + 1 ))
    else
        failed=$(( failed + 1 ))
    fi

    if restore_p10k 2>/dev/null; then
        restored=$(( restored + 1 ))
    else
        failed=$(( failed + 1 ))
    fi

    if restore_vscode 2>/dev/null; then
        restored=$(( restored + 1 ))
    else
        failed=$(( failed + 1 ))
    fi

    echo
    log_success "Restored $restored file(s), $failed failed"
}

restore_from_specific_backup() {
    list_all_backups
    echo
    read -r -p "Enter full backup path: " backup_path

    if [[ ! -f "$backup_path" ]]; then
        log_error "File not found: $backup_path"
        return 1
    fi

    echo
    echo "Where should this file be restored?"
    echo "  1) ~/.zshrc"
    echo "  2) ~/.p10k.zsh"
    echo "  3) VS Code settings"
    echo "  4) Custom path"
    echo
    read -r -p "Enter choice [1-4]: " target_choice

    local target_path
    case "$target_choice" in
        1) target_path="$HOME/.zshrc" ;;
        2) target_path="$HOME/.p10k.zsh" ;;
        3) target_path="$HOME/.config/Code/User/settings.json" ;;
        4)
            read -r -p "Enter target path: " target_path
            ;;
        *)
            log_error "Invalid choice"
            return 1
            ;;
    esac

    restore_file "$backup_path" "$target_path"
}

restore_from_point() {
    list_restore_points
    echo
    read -r -p "Enter restore point name: " point_name

    local point_dir="$RESTORE_POINTS_DIR/$point_name"

    if [[ ! -d "$point_dir" ]]; then
        log_error "Restore point not found: $point_name"
        return 1
    fi

    log_info "Restoring from point: $point_name"

    # Restore each file in the point
    while IFS= read -r backup_file; do
        [[ "$backup_file" == *"metadata.txt" ]] && continue

        # Determine original path from backup filename
        local basename
        basename=$(basename "$backup_file")

        # Try to restore based on filename patterns
        if [[ "$basename" == *"zshrc"* ]]; then
            restore_file "$backup_file" "$HOME/.zshrc"
        elif [[ "$basename" == *"p10k"* ]]; then
            restore_file "$backup_file" "$HOME/.p10k.zsh"
        else
            log_info "Unknown file type: $basename (skipped)"
        fi
    done < <(find "$point_dir" -type f)

    log_success "Restore from point complete"
}

# ============================================================================
# Reset to Defaults
# ============================================================================

# Reset ~/.p10k.zsh to the factory theme under a transaction (P3-1): the
# target is registered BEFORE mutation, the .emergency backups in
# $BACKUP_DIR/emergency are preserved as belt-and-braces, the applied theme
# is byte-verified against the factory source, and any failure rolls the
# pre-reset state back byte-identically. The typed-RESET confirm gates
# everything (including dry-run planning).
reset_to_defaults() {
    echo
    log_warn "  This will reset ALL customizations!"
    echo
    echo "This will:"
    echo "  - Reset ~/.p10k.zsh to the default professional theme"
    echo "  - Remove custom configurations"
    echo "  - NOT delete your backup files"
    echo
    read -r -p "Type 'RESET' to confirm: " confirm

    if [[ "$confirm" != "RESET" ]]; then
        log_info "Reset cancelled"
        return 0
    fi

    local factory="${_EMERGENCY_ROOT}/config/professional-dev-p10k.zsh"
    if [[ ! -f "$factory" ]]; then
        log_error "Default config not found: $factory"
        return 1
    fi

    transaction_start "emergency_reset" || return 1

    # Register BEFORE any mutation so a failure rolls back the pre-reset
    # state byte-identically (or removes the file if the reset created it).
    if ! transaction_add_file "$HOME/.p10k.zsh"; then
        _er_rollback
        return 1
    fi

    # Dry-run: plan only — zero writes (no transaction dir, no emergency
    # backups, no factory copy).
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would reset $HOME/.p10k.zsh to factory default (source: $factory)"
        log_info "[dry-run] would save emergency backups to $BACKUP_DIR/emergency/"
        transaction_commit || return 1
        return 0
    fi

    # Belt-and-braces emergency backups first (convention preserved).
    mkdir -p "$BACKUP_DIR/emergency"
    local timestamp
    timestamp=$(date +%Y%m%d%H%M%S)

    if [[ -f "$HOME/.p10k.zsh" ]]; then
        if ! cp "$HOME/.p10k.zsh" "$BACKUP_DIR/emergency/p10k-${timestamp}.zsh"; then
            log_error "Cannot save emergency backup of $HOME/.p10k.zsh"
            _er_rollback
            return 1
        fi
    fi

    if [[ -f "$HOME/.zshrc" ]]; then
        if ! cp "$HOME/.zshrc" "$BACKUP_DIR/emergency/zshrc-${timestamp}"; then
            log_error "Cannot save emergency backup of $HOME/.zshrc"
            _er_rollback
            return 1
        fi
    fi

    log_info "Emergency backups saved to $BACKUP_DIR/emergency/"

    # Reset p10k to default (atomic replace of the registered target).
    local tmp
    tmp=$(mktemp "$(dirname "$HOME/.p10k.zsh")/.vms-reset.XXXXXX") || {
        log_error "Cannot stage reset in $HOME"
        _er_rollback
        return 1
    }
    if ! cp "$factory" "$tmp"; then
        rm -f "$tmp" 2>/dev/null || true
        log_error "Cannot stage factory theme: $factory"
        _er_rollback
        return 1
    fi
    if ! _er_copy_mode "$HOME/.p10k.zsh" "$tmp"; then
        rm -f "$tmp" 2>/dev/null || true
        log_error "Cannot preserve the mode of $HOME/.p10k.zsh"
        _er_rollback
        return 1
    fi
    if ! mv "$tmp" "$HOME/.p10k.zsh"; then
        rm -f "$tmp" 2>/dev/null || true
        log_error "Reset FAILED for: $HOME/.p10k.zsh"
        _er_rollback
        return 1
    fi

    # Verify: the applied theme must match the factory source byte-for-byte.
    if ! _er_files_identical "$factory" "$HOME/.p10k.zsh"; then
        log_error "Post-reset verification FAILED: $HOME/.p10k.zsh differs from $factory"
        _er_rollback
        return 1
    fi

    if ! transaction_commit; then
        log_error "Transaction commit failed for reset"
        return 1
    fi
    log_success "Reset ~/.p10k.zsh to factory default"

    echo
    log_success "Reset complete. Restart your terminal to apply changes."
    return 0
}

# ============================================================================
# Diagnostics
# ============================================================================

diagnose_state() {
    echo "System Diagnostic"
    echo "================="
    echo

    echo "Configuration Files:"
    for file in "${RECOVERABLE_FILES[@]}"; do
        if [[ -f "$file" ]]; then
            local size
            size=$(wc -c < "$file" 2>/dev/null || echo "0")
            echo "   $file ($size bytes)"
        else
            echo "   $file (missing)"
        fi
    done
    echo

    echo "Shell Configuration:"
    echo "  Current shell: $SHELL"
    echo "  TERM_PROGRAM: ${TERM_PROGRAM:-not set}"
    echo "  P10K loaded: $([[ -n "${POWERLEVEL9K_MODE:-}" ]] && echo "yes" || echo "no")"
    echo

    echo "Backup Status:"
    if [[ -d "$BACKUP_DIR" ]]; then
        local backup_count
        backup_count=$(find "$BACKUP_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
        echo "  Backup directory: $BACKUP_DIR"
        echo "  Total backups: $backup_count"
    else
        echo "   Backup directory not found"
    fi
    echo

    echo "Restore Points:"
    if [[ -d "$RESTORE_POINTS_DIR" ]]; then
        local point_count
        point_count=$(find "$RESTORE_POINTS_DIR" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        echo "  Restore points: $((point_count - 1))"
    else
        echo "   No restore points"
    fi
    echo

    echo "Quick Actions:"
    echo "  - Run './setup.sh' to access main menu"
    echo "  - Run './tools/system-diagnostics.sh --full' for detailed scan"
    echo "  - Source your shell config: 'source ~/.zshrc'"
}

# ============================================================================
# Main
# ============================================================================

main() {
    local dry_run=0

    if [[ "${1:-}" == "--dry-run" ]]; then
        dry_run=1
        export TRANSACTION_DRY_RUN=1
        shift
    fi

    show_header

    if [[ "$dry_run" -eq 1 ]]; then
        log_info "DRY-RUN MODE — plan only, zero writes to your configuration"
        echo
    fi

    while true; do
        show_menu
        read -r -p "Select option [0-10]: " choice
        echo

        case "$choice" in
            1) restore_zshrc || log_warn "Option $choice did not complete" ;;
            2) restore_p10k || log_warn "Option $choice did not complete" ;;
            3) restore_vscode || log_warn "Option $choice did not complete" ;;
            4) restore_all || log_warn "Option $choice did not complete" ;;
            5) list_all_backups ;;
            6) list_restore_points ;;
            7) restore_from_specific_backup || log_warn "Option $choice did not complete" ;;
            8) restore_from_point "" || log_warn "Option $choice did not complete" ;;
            9) reset_to_defaults || log_warn "Option $choice did not complete" ;;
            10) diagnose_state ;;
            0)
                log_info "Exiting recovery system"
                exit 0
                ;;
            *)
                log_error "Invalid option: $choice"
                ;;
        esac

        echo
        read -r -p "Press Enter to continue..."
        echo
    done
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
