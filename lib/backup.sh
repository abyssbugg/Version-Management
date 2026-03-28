#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source paths; SC2034: intentionally exported vars

# =============================================================================
# Backup Management Utilities for Version Management Setup
# =============================================================================
# Provides comprehensive backup and restore functionality for configuration files
# 
# Functions:
#   - create_backup                    : Create timestamped backup of a file
#   - create_zshrc_backup             : Backup .zshrc configuration
#   - create_p10k_backup              : Backup .p10k.zsh configuration
#   - create_vscode_backup            : Backup VS Code settings
#   - restore_backup                  : Restore from a specific backup
#   - list_backups                    : List available backups
#   - cleanup_old_backups             : Remove old backup files
#   - validate_backup                 : Verify backup integrity
#
# Usage:
#   source lib/backup.sh
#   create_backup "$HOME/.zshrc"
#   list_backups
#   restore_backup "$HOME/.zshrc" "20240101_120000"
# =============================================================================

set -euo pipefail

# Source logger utilities if available
LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"
if [[ -f "$LIB_DIR/logger.sh" ]]; then
    # shellcheck source=lib/logger.sh
    source "$LIB_DIR/logger.sh"
else
    # Fallback logging functions
    log_info() { echo "[INFO] $1"; }
    log_warn() { echo "[WARN] $1" >&2; }
    log_error() { echo "[ERROR] $1" >&2; }
    log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo "[DEBUG] $1"; }
fi

# =============================================================================
# Configuration and Constants
# =============================================================================

# Default backup directory
readonly DEFAULT_BACKUP_DIR="$HOME/.config-backups"

# Maximum number of backups to keep per file
readonly MAX_BACKUPS_PER_FILE="${BACKUP_MAX_FILES:-10}"

# Maximum age of backups in days
readonly MAX_BACKUP_AGE_DAYS="${BACKUP_MAX_AGE:-30}"

# =============================================================================
# Core Backup Functions
# =============================================================================

# Create timestamped backup of a file
create_backup() {
    local source_file="$1"
    local backup_dir="${2:-$DEFAULT_BACKUP_DIR}"
    local backup_name="${3:-}"
    local timestamp
    
    # Validate input parameters
    if [[ -z "$source_file" ]]; then
        log_error "Source file path is required"
        return 1
    fi
    
    if [[ ! -f "$source_file" ]]; then
        log_error "Source file does not exist: $source_file"
        return 1
    fi
    
    # Create backup directory if it doesn't exist
    if [[ ! -d "$backup_dir" ]]; then
        if ! mkdir -p "$backup_dir"; then
            log_error "Failed to create backup directory: $backup_dir"
            return 1
        fi
        log_debug "Created backup directory: $backup_dir"
    fi
    
    # Generate timestamp and backup filename
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local base_name
    base_name=$(basename "$source_file")
    
    if [[ -n "$backup_name" ]]; then
        local backup_file="$backup_dir/${backup_name}.${base_name}.backup.$timestamp"
    else
        local backup_file="$backup_dir/${base_name}.backup.$timestamp"
    fi
    
    log_info "Creating backup of: $source_file"
    log_debug "Backup destination: $backup_file"
    
    # Create the backup
    if cp "$source_file" "$backup_file"; then
        log_info "Backup created successfully: $backup_file"
        
        # Validate the backup
        if validate_backup "$source_file" "$backup_file"; then
            log_debug "Backup validation successful"
            echo "$backup_file"  # Return backup file path
            return 0
        else
            log_error "Backup validation failed"
            rm -f "$backup_file" 2>/dev/null || true
            return 1
        fi
    else
        log_error "Failed to create backup"
        return 1
    fi
}

# =============================================================================
# Specialized Backup Functions
# =============================================================================

# Backup .zshrc configuration
create_zshrc_backup() {
    local zshrc_file="${1:-$HOME/.zshrc}"
    local backup_dir="${2:-$DEFAULT_BACKUP_DIR}"
    
    log_info "Creating .zshrc backup..."
    
    if [[ ! -f "$zshrc_file" ]]; then
        log_warn ".zshrc file not found: $zshrc_file"
        return 1
    fi
    
    create_backup "$zshrc_file" "$backup_dir" "zshrc"
}

# Backup .p10k.zsh configuration
create_p10k_backup() {
    local p10k_file="${1:-$HOME/.p10k.zsh}"
    local backup_dir="${2:-$DEFAULT_BACKUP_DIR}"
    
    log_info "Creating PowerLevel10k configuration backup..."
    
    if [[ ! -f "$p10k_file" ]]; then
        log_warn "PowerLevel10k configuration not found: $p10k_file"
        return 1
    fi
    
    create_backup "$p10k_file" "$backup_dir" "p10k"
}

# Backup VS Code settings
create_vscode_backup() {
    local backup_dir="${1:-$DEFAULT_BACKUP_DIR}"
    local vscode_settings_dir
    local os_type
    
    log_info "Creating VS Code settings backup..."
    
    # Detect OS and set VS Code settings directory
    os_type=$(uname -s)
    case "$os_type" in
        Darwin)
            vscode_settings_dir="$HOME/Library/Application Support/Code/User"
            ;;
        Linux)
            vscode_settings_dir="$HOME/.config/Code/User"
            ;;
        CYGWIN*|MINGW*|MSYS*)
            vscode_settings_dir="$HOME/AppData/Roaming/Code/User"
            ;;
        *)
            log_error "Unsupported operating system: $os_type"
            return 1
            ;;
    esac
    
    if [[ ! -d "$vscode_settings_dir" ]]; then
        log_warn "VS Code settings directory not found: $vscode_settings_dir"
        return 1
    fi
    
    # Backup key VS Code configuration files
    local files_to_backup=(
        "settings.json"
        "keybindings.json"
        "snippets"
        "extensions.json"
    )
    
    local backup_success=true
    for file in "${files_to_backup[@]}"; do
        local full_path="$vscode_settings_dir/$file"
        if [[ -f "$full_path" ]]; then
            if ! create_backup "$full_path" "$backup_dir" "vscode"; then
                log_warn "Failed to backup VS Code file: $file"
                backup_success=false
            fi
        elif [[ -d "$full_path" ]]; then
            # Handle directories (like snippets)
            local archive_path="$backup_dir/vscode.${file}.$(date '+%Y%m%d_%H%M%S').tar.gz"
            if tar -czf "$archive_path" -C "$vscode_settings_dir" "$file" 2>/dev/null; then
                log_info "VS Code directory backed up: $archive_path"
            else
                log_warn "Failed to backup VS Code directory: $file"
                backup_success=false
            fi
        fi
    done
    
    if [[ "$backup_success" == "true" ]]; then
        log_info "VS Code settings backup completed successfully"
        return 0
    else
        log_warn "VS Code settings backup completed with some failures"
        return 1
    fi
}

# =============================================================================
# Restore Functions
# =============================================================================

# Restore from a specific backup
restore_backup() {
    local target_file="$1"
    local backup_identifier="$2"  # Can be timestamp or full backup path
    local backup_dir="${3:-$DEFAULT_BACKUP_DIR}"
    local backup_file=""
    
    # Validate input parameters
    if [[ -z "$target_file" || -z "$backup_identifier" ]]; then
        log_error "Target file and backup identifier are required"
        return 1
    fi
    
    # Determine backup file path
    if [[ -f "$backup_identifier" ]]; then
        # Full path provided
        backup_file="$backup_identifier"
    else
        # Search for backup by timestamp or pattern
        local base_name
        base_name=$(basename "$target_file")
        
        # Try different backup naming patterns
        local patterns=(
            "$backup_dir/${base_name}.backup.${backup_identifier}"
            "$backup_dir/*.${base_name}.backup.${backup_identifier}"
            "$backup_dir/${base_name}.backup.*${backup_identifier}*"
        )
        
        for pattern in "${patterns[@]}"; do
            # Use array to handle glob expansion safely
            local matches=()
            while IFS= read -r -d '' file; do
                matches+=("$file")
            done < <(find "$backup_dir" -name "$(basename "$pattern")" -print0 2>/dev/null)
            
            if [[ ${#matches[@]} -gt 0 ]]; then
                backup_file="${matches[0]}"  # Use first match
                break
            fi
        done
    fi
    
    if [[ -z "$backup_file" || ! -f "$backup_file" ]]; then
        log_error "Backup file not found for identifier: $backup_identifier"
        return 1
    fi
    
    log_info "Restoring from backup: $backup_file"
    log_info "Target file: $target_file"
    
    # Create backup of current file before restore
    if [[ -f "$target_file" ]]; then
        local pre_restore_backup
        pre_restore_backup=$(create_backup "$target_file" "$backup_dir" "pre-restore")
        if [[ $? -eq 0 ]]; then
            log_info "Current file backed up before restore: $pre_restore_backup"
        else
            log_warn "Failed to backup current file before restore"
        fi
    fi
    
    # Perform the restore
    if cp "$backup_file" "$target_file"; then
        log_info "File restored successfully from backup"
        return 0
    else
        log_error "Failed to restore file from backup"
        return 1
    fi
}

# =============================================================================
# Backup Management Functions
# =============================================================================

# List available backups
list_backups() {
    local backup_dir="${1:-$DEFAULT_BACKUP_DIR}"
    local file_pattern="${2:-*}"
    
    if [[ ! -d "$backup_dir" ]]; then
        log_warn "Backup directory does not exist: $backup_dir"
        return 1
    fi
    
    log_info "Available backups in: $backup_dir"
    echo ""
    
    # Find and sort backup files (portable: avoid -print0 + sort -z which is GNU-only)
    local backup_files=()
    while IFS= read -r file; do
        backup_files+=("$file")
    done < <(find "$backup_dir" -name "*${file_pattern}*.backup.*" -type f 2>/dev/null | sort)
    
    if [[ ${#backup_files[@]} -eq 0 ]]; then
        log_info "No backup files found matching pattern: $file_pattern"
        return 0
    fi
    
    # Display backup information
    printf "%-50s %-20s %-10s\n" "Backup File" "Timestamp" "Size"
    printf "%-50s %-20s %-10s\n" "$(printf '%s' '...................................................')" "$(printf '%s' '--------------------')" "$(printf '%s' '----------')"
    
    for backup_file in "${backup_files[@]}"; do
        local basename_file
        basename_file=$(basename "$backup_file")
        local timestamp=""
        local size=""
        
        # Extract timestamp from filename
        if [[ "$basename_file" =~ \.backup\.([0-9]{8}_[0-9]{6})$ ]]; then
            timestamp="${BASH_REMATCH[1]}"
        fi
        
        # Get file size
        if [[ -f "$backup_file" ]]; then
            size=$(du -h "$backup_file" 2>/dev/null | cut -f1)
        fi
        
        printf "%-50s %-20s %-10s\n" "$basename_file" "$timestamp" "$size"
    done
    
    echo ""
    log_info "Total backups found: ${#backup_files[@]}"
}

# Cleanup old backups
cleanup_old_backups() {
    local backup_dir="${1:-$DEFAULT_BACKUP_DIR}"
    local max_age_days="${2:-$MAX_BACKUP_AGE_DAYS}"
    local max_files_per_type="${3:-$MAX_BACKUPS_PER_FILE}"
    
    if [[ ! -d "$backup_dir" ]]; then
        log_warn "Backup directory does not exist: $backup_dir"
        return 0
    fi
    
    log_info "Cleaning up old backups..."
    log_debug "Max age: $max_age_days days, Max files per type: $max_files_per_type"
    
    local cleanup_count=0
    
    # Remove backups older than specified days
    while IFS= read -r -d '' old_file; do
        if rm "$old_file" 2>/dev/null; then
            log_debug "Removed old backup: $(basename "$old_file")"
                    cleanup_count=$((cleanup_count + 1))  # portable: avoids exit-1 from ((n++)) when n=0 under set -e
        fi
    done < <(find "$backup_dir" -name "*.backup.*" -type f -mtime "+$max_age_days" -print0 2>/dev/null)
    
    # Limit number of backups per file type
    local file_types=()
    while IFS= read -r -d '' backup_file; do
        local basename_file
        basename_file=$(basename "$backup_file")
        local file_type=""
        
        # Extract file type from backup name
        if [[ "$basename_file" =~ ^(.+)\.backup\.[0-9]{8}_[0-9]{6}$ ]]; then
            file_type="${BASH_REMATCH[1]}"
            file_types+=("$file_type")
        fi
    done < <(find "$backup_dir" -name "*.backup.*" -type f -print0 2>/dev/null)
    
    # Remove duplicates from file_types array
    local unique_types=()
    for type in "${file_types[@]}"; do
        if [[ ! " ${unique_types[*]} " =~ \ $type\  ]]; then
            unique_types+=("$type")
        fi
    done
    
    # For each file type, keep only the most recent backups
    for file_type in "${unique_types[@]}"; do
        local type_backups=()
        while IFS= read -r backup_file; do
            type_backups+=("$backup_file")
        done < <(find "$backup_dir" -name "${file_type}.backup.*" -type f 2>/dev/null | sort)  # portable: sort instead of -print0|sort -z
        
        # Remove excess backups (keep most recent)
        local excess_count=$((${#type_backups[@]} - max_files_per_type))
        if [[ $excess_count -gt 0 ]]; then
            for ((i=0; i<excess_count; i++)); do
                if rm "${type_backups[i]}" 2>/dev/null; then
                    log_debug "Removed excess backup: $(basename "${type_backups[i]}")"
                    cleanup_count=$((cleanup_count + 1))  # portable: avoids exit-1 from ((n++)) when n=0 under set -e
                fi
            done
        fi
    done
    
    if [[ $cleanup_count -gt 0 ]]; then
        log_info "Cleanup completed: $cleanup_count old backups removed"
    else
        log_info "No old backups found to clean up"
    fi
    
    return 0
}

# =============================================================================
# Validation Functions
# =============================================================================

# Validate backup integrity
validate_backup() {
    local original_file="$1"
    local backup_file="$2"
    
    if [[ ! -f "$original_file" ]]; then
        log_error "Original file does not exist: $original_file"
        return 1
    fi
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file does not exist: $backup_file"
        return 1
    fi
    
    # Compare file sizes
    local original_size backup_size
    original_size=$(stat -f%z "$original_file" 2>/dev/null || stat -c%s "$original_file" 2>/dev/null)
    backup_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null)
    
    if [[ "$original_size" != "$backup_size" ]]; then
        log_error "Backup validation failed: file sizes differ"
        log_debug "Original: $original_size bytes, Backup: $backup_size bytes"
        return 1
    fi
    
    # Compare checksums if available
    if command -v shasum >/dev/null 2>&1; then
        local original_hash backup_hash
        original_hash=$(shasum -a 256 "$original_file" 2>/dev/null | cut -d' ' -f1)
        backup_hash=$(shasum -a 256 "$backup_file" 2>/dev/null | cut -d' ' -f1)
        
        if [[ "$original_hash" != "$backup_hash" ]]; then
            log_error "Backup validation failed: checksums differ"
            return 1
        fi
    fi
    
    log_debug "Backup validation successful"
    return 0
}

# =============================================================================
# Transactional Update System
# =============================================================================
# Provides atomic operations with automatic rollback on failure.
# Usage:
#   transaction_start "operation_name"
#   transaction_add_file "/path/to/file"
#   # ... make changes ...
#   transaction_commit   # or transaction_rollback on failure

# Transaction state
_TRANSACTION_ACTIVE=""
_TRANSACTION_NAME=""
_TRANSACTION_DIR=""
_TRANSACTION_FILES=()

# Start a new transaction
# Usage: transaction_start "theme_installation"
transaction_start() {
    local name="${1:-transaction}"
    
    if [[ -n "$_TRANSACTION_ACTIVE" ]]; then
        log_error "Transaction already active: $_TRANSACTION_NAME"
        return 1
    fi
    
    _TRANSACTION_NAME="$name"
    _TRANSACTION_DIR="$DEFAULT_BACKUP_DIR/transactions/${name}_$(date +%Y%m%d_%H%M%S)"
    _TRANSACTION_FILES=()
    _TRANSACTION_ACTIVE="true"
    
    mkdir -p "$_TRANSACTION_DIR"
    
    # Write transaction metadata
    cat > "$_TRANSACTION_DIR/metadata.json" << EOF
{
    "name": "$name",
    "started_at": "$(date -Iseconds)",
    "status": "active",
    "files": []
}
EOF
    
    log_info "Transaction started: $name"
    log_debug "Transaction directory: $_TRANSACTION_DIR"
    return 0
}

# Add a file to the current transaction (creates backup)
# Usage: transaction_add_file "/path/to/file"
transaction_add_file() {
    local file="$1"
    
    if [[ -z "$_TRANSACTION_ACTIVE" ]]; then
        log_error "No active transaction"
        return 1
    fi
    
    if [[ ! -f "$file" ]]; then
        log_debug "File does not exist yet, marking as new: $file"
        echo "$file" >> "$_TRANSACTION_DIR/new_files.txt"
        _TRANSACTION_FILES+=("NEW:$file")
        return 0
    fi
    
    # Create backup of existing file
    local backup_name
    backup_name=$(basename "$file")
    cp "$file" "$_TRANSACTION_DIR/${backup_name}.backup"
    
    # Store original path mapping
    echo "$file" >> "$_TRANSACTION_DIR/file_list.txt"
    echo "$file|$_TRANSACTION_DIR/${backup_name}.backup" >> "$_TRANSACTION_DIR/mappings.txt"
    
    _TRANSACTION_FILES+=("$file")
    log_debug "Added to transaction: $file"
    return 0
}

# Commit the transaction (cleanup backups, mark complete)
# Usage: transaction_commit
transaction_commit() {
    if [[ -z "$_TRANSACTION_ACTIVE" ]]; then
        log_error "No active transaction to commit"
        return 1
    fi
    
    # Update metadata
    cat > "$_TRANSACTION_DIR/metadata.json" << EOF
{
    "name": "$_TRANSACTION_NAME",
    "started_at": "$(date -Iseconds)",
    "completed_at": "$(date -Iseconds)",
    "status": "committed",
    "files_count": ${#_TRANSACTION_FILES[@]}
}
EOF
    
    log_success "Transaction committed: $_TRANSACTION_NAME (${#_TRANSACTION_FILES[@]} files)"
    
    # Clear transaction state
    _TRANSACTION_ACTIVE=""
    _TRANSACTION_NAME=""
    _TRANSACTION_DIR=""
    _TRANSACTION_FILES=()
    
    return 0
}

# Rollback the transaction (restore all files)
# Usage: transaction_rollback
transaction_rollback() {
    if [[ -z "$_TRANSACTION_ACTIVE" ]]; then
        log_error "No active transaction to rollback"
        return 1
    fi
    
    log_warn "Rolling back transaction: $_TRANSACTION_NAME"
    
    local rollback_errors=0
    
    # Restore backed up files
    if [[ -f "$_TRANSACTION_DIR/mappings.txt" ]]; then
        while IFS='|' read -r original backup; do
            if [[ -f "$backup" ]]; then
                if cp "$backup" "$original"; then
                    log_debug "Restored: $original"
                else
                    log_error "Failed to restore: $original"
                    rollback_errors=$((rollback_errors + 1))  # portable: avoids exit-1 from ((n++)) when n=0 under set -e
                fi
            fi
        done < "$_TRANSACTION_DIR/mappings.txt"
    fi
    
    # Remove newly created files
    if [[ -f "$_TRANSACTION_DIR/new_files.txt" ]]; then
        while read -r new_file; do
            if [[ -f "$new_file" ]]; then
                rm -f "$new_file"
                log_debug "Removed new file: $new_file"
            fi
        done < "$_TRANSACTION_DIR/new_files.txt"
    fi
    
    # Update metadata
    cat > "$_TRANSACTION_DIR/metadata.json" << EOF
{
    "name": "$_TRANSACTION_NAME",
    "rolled_back_at": "$(date -Iseconds)",
    "status": "rolled_back",
    "errors": $rollback_errors
}
EOF
    
    if [[ $rollback_errors -gt 0 ]]; then
        log_error "Rollback completed with $rollback_errors errors"
    else
        log_info "Rollback completed successfully"
    fi
    
    # Clear transaction state
    _TRANSACTION_ACTIVE=""
    _TRANSACTION_NAME=""
    _TRANSACTION_DIR=""
    _TRANSACTION_FILES=()
    
    return $rollback_errors
}

# Check if a transaction is active
# Usage: transaction_is_active && echo "Active"
transaction_is_active() {
    [[ -n "$_TRANSACTION_ACTIVE" ]]
}

# Get current transaction name
# Usage: name=$(transaction_get_name)
transaction_get_name() {
    echo "$_TRANSACTION_NAME"
}

# =============================================================================
# Restore Point System
# =============================================================================
# Creates named restore points that can be rolled back to later.

# Create a named restore point
# Usage: create_restore_point "before_theme_change" "/path/to/file1" "/path/to/file2"
create_restore_point() {
    local name="$1"
    shift
    local files=("$@")
    
    if [[ -z "$name" ]]; then
        log_error "Restore point name required"
        return 1
    fi
    
    local restore_dir="$DEFAULT_BACKUP_DIR/restore_points/$name"
    
    # Remove existing restore point with same name
    if [[ -d "$restore_dir" ]]; then
        rm -rf "$restore_dir"
    fi
    
    mkdir -p "$restore_dir"
    
    log_info "Creating restore point: $name"
    
    local file_count=0
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            local backup_name
            backup_name=$(echo "$file" | tr '/' '_')
            cp "$file" "$restore_dir/$backup_name"
            echo "$file|$restore_dir/$backup_name" >> "$restore_dir/mappings.txt"
            file_count=$((file_count + 1))  # portable: avoids exit-1 from ((n++)) when n=0 under set -e
        else
            log_debug "File not found, skipping: $file"
        fi
    done
    
    # Write metadata
    cat > "$restore_dir/metadata.json" << EOF
{
    "name": "$name",
    "created_at": "$(date -Iseconds)",
    "files_count": $file_count
}
EOF
    
    log_success "Restore point created: $name ($file_count files)"
    return 0
}

# Restore from a named restore point
# Usage: restore_from_point "before_theme_change"
restore_from_point() {
    local name="$1"
    
    if [[ -z "$name" ]]; then
        log_error "Restore point name required"
        return 1
    fi
    
    local restore_dir="$DEFAULT_BACKUP_DIR/restore_points/$name"
    
    if [[ ! -d "$restore_dir" ]]; then
        log_error "Restore point not found: $name"
        return 1
    fi
    
    if [[ ! -f "$restore_dir/mappings.txt" ]]; then
        log_error "Restore point corrupted: missing mappings"
        return 1
    fi
    
    log_info "Restoring from: $name"
    
    local restore_count=0
    local restore_errors=0
    
    while IFS='|' read -r original backup; do
        if [[ -f "$backup" ]]; then
            # Create backup of current file before restoring
            if [[ -f "$original" ]]; then
                cp "$original" "${original}.pre-restore"
            fi
            
            if cp "$backup" "$original"; then
                log_debug "Restored: $original"
                restore_count=$((restore_count + 1))  # portable: avoids exit-1 from ((n++)) when n=0 under set -e
            else
                log_error "Failed to restore: $original"
                restore_errors=$((restore_errors + 1))  # portable: avoids exit-1 from ((n++)) when n=0 under set -e
            fi
        fi
    done < "$restore_dir/mappings.txt"
    
    if [[ $restore_errors -gt 0 ]]; then
        log_error "Restore completed with $restore_errors errors ($restore_count files restored)"
        return 1
    fi
    
    log_success "Restored $restore_count files from: $name"
    return 0
}

# List available restore points
# Usage: list_restore_points
list_restore_points() {
    local restore_base="$DEFAULT_BACKUP_DIR/restore_points"
    
    if [[ ! -d "$restore_base" ]]; then
        log_info "No restore points found"
        return 0
    fi
    
    echo "Available Restore Points:"
    echo "========================="
    
    for dir in "$restore_base"/*/; do
        if [[ -d "$dir" ]]; then
            local name
            name=$(basename "$dir")
            local metadata="$dir/metadata.json"
            
            if [[ -f "$metadata" ]]; then
                local created_at files_count
                created_at=$(grep -o '"created_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$metadata" | cut -d'"' -f4)
                files_count=$(grep -o '"files_count"[[:space:]]*:[[:space:]]*[0-9]*' "$metadata" | grep -o '[0-9]*$')
                echo "  - $name (${files_count:-?} files, created: ${created_at:-unknown})"
            else
                echo "  - $name (metadata missing)"
            fi
        fi
    done
}

# Delete a restore point
# Usage: delete_restore_point "point_name"
delete_restore_point() {
    local name="$1"
    local restore_dir="$DEFAULT_BACKUP_DIR/restore_points/$name"
    
    if [[ ! -d "$restore_dir" ]]; then
        log_error "Restore point not found: $name"
        return 1
    fi
    
    rm -rf "$restore_dir"
    log_info "Deleted restore point: $name"
    return 0
}

# Export functions for use in other scripts
export -f create_backup create_zshrc_backup create_p10k_backup create_vscode_backup
export -f restore_backup list_backups cleanup_old_backups validate_backup
export -f transaction_start transaction_add_file transaction_commit transaction_rollback
export -f transaction_is_active transaction_get_name
export -f create_restore_point restore_from_point list_restore_points delete_restore_point
