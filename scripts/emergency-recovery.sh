#!/usr/bin/env bash
# shellcheck disable=SC1091
# ============================================================================
# Emergency Recovery Script
# Part of Professional Development Terminal Setup
# ============================================================================
# Restores system to a known-good state when things go wrong.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source dependencies
source "$SCRIPT_DIR/lib/logger.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
}

source "$SCRIPT_DIR/lib/backup.sh" 2>/dev/null || true

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
            ((count++))
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
            ((count++))
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

restore_file() {
    local backup_path="$1"
    local target_path="$2"

    if [[ ! -f "$backup_path" ]]; then
        log_error "Backup file not found: $backup_path"
        return 1
    fi

    # Create backup of current file
    if [[ -f "$target_path" ]]; then
        local emergency_backup="${target_path}.emergency-$(date +%Y%m%d%H%M%S)"
        cp "$target_path" "$emergency_backup"
        log_info "Created emergency backup: $emergency_backup"
    fi

    # Restore from backup
    cp "$backup_path" "$target_path"
    log_success "Restored: $target_path"
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

    if [[ -n "$backup" ]]; then
        local vscode_dir="$HOME/.config/Code/User"
        mkdir -p "$vscode_dir"
        restore_file "$backup" "$vscode_dir/settings.json"
    else
        log_error "No VS Code settings backup found"
        return 1
    fi
}

restore_all() {
    log_info "Restoring all configuration files..."

    local restored=0
    local failed=0

    if restore_zshrc 2>/dev/null; then
        ((restored++))
    else
        ((failed++))
    fi

    if restore_p10k 2>/dev/null; then
        ((restored++))
    else
        ((failed++))
    fi

    if restore_vscode 2>/dev/null; then
        ((restored++))
    else
        ((failed++))
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

    # Create emergency backup first
    mkdir -p "$BACKUP_DIR/emergency"
    local timestamp
    timestamp=$(date +%Y%m%d%H%M%S)

    if [[ -f "$HOME/.p10k.zsh" ]]; then
        cp "$HOME/.p10k.zsh" "$BACKUP_DIR/emergency/p10k-${timestamp}.zsh"
    fi

    if [[ -f "$HOME/.zshrc" ]]; then
        cp "$HOME/.zshrc" "$BACKUP_DIR/emergency/zshrc-${timestamp}"
    fi

    log_info "Emergency backups saved to $BACKUP_DIR/emergency/"

    # Reset p10k to default
    if [[ -f "$SCRIPT_DIR/config/professional-dev-p10k.zsh" ]]; then
        cp "$SCRIPT_DIR/config/professional-dev-p10k.zsh" "$HOME/.p10k.zsh"
        log_success "Reset ~/.p10k.zsh to factory default"
    else
        log_error "Default config not found"
    fi

    echo
    log_success "Reset complete. Restart your terminal to apply changes."
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
    show_header

    while true; do
        show_menu
        read -r -p "Select option [0-10]: " choice
        echo

        case "$choice" in
            1) restore_zshrc ;;
            2) restore_p10k ;;
            3) restore_vscode ;;
            4) restore_all ;;
            5) list_all_backups ;;
            6) list_restore_points ;;
            7) restore_from_specific_backup ;;
            8) restore_from_point "" ;;
            9) reset_to_defaults ;;
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
