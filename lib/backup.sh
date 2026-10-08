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

# Contract (directive A2/M1): this file is SOURCED — it must not set global
# shell options; callers own their strict-mode posture. Argument validation
# and error propagation are explicit inside library functions.

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
# Re-source safety (B1.13-new): the transaction functions below are
# export -f'd, so a child process can inherit function copies WITHOUT this
# file having been sourced there. Re-sourcing must therefore be safe and is
# in fact required (mutation.sh sources this file unconditionally — inherited
# copies defeat declare -f guards). readonly declarations would fail on a
# second source, so config is declared once; functions re-define cleanly.
if [[ -z "${_VMS_BACKUP_SH_LOADED:-}" ]]; then
    # Compatibility snapshot only; operations resolve HOME at call time.
    readonly DEFAULT_BACKUP_DIR="${HOME:-}/.config-backups"

    # Maximum number of backups to keep per file
    readonly MAX_BACKUPS_PER_FILE="${BACKUP_MAX_FILES:-10}"

    # Maximum age of backups in days
    readonly MAX_BACKUP_AGE_DAYS="${BACKUP_MAX_AGE:-30}"

    _VMS_BACKUP_SH_LOADED=1
fi

# =============================================================================
# Core Backup Functions
# =============================================================================

# Resolve the default only when needed; never write relative to an empty HOME.
# Explicit positional directory arguments remain authoritative. BACKUP_DIR is
# owned by legacy entry points and is deliberately not a global library option.
_backup_default_dir() {
    if [[ -z "${HOME:-}" || "$HOME" != /* ]]; then
        LOG_FILE='' log_error "An absolute HOME is required for default backup storage"
        return 1
    fi
    printf '%s/.config-backups\n' "${HOME%/}"
}

# Create timestamped backup of a file
create_backup() {
    local source_file="$1"
    local backup_dir="${2:-}"
    [[ -n "$backup_dir" ]] || backup_dir=$(_backup_default_dir) || return 1
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
    local backup_dir="${2:-}"
    [[ -n "$backup_dir" ]] || backup_dir=$(_backup_default_dir) || return 1

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
    local backup_dir="${2:-}"
    [[ -n "$backup_dir" ]] || backup_dir=$(_backup_default_dir) || return 1

    log_info "Creating PowerLevel10k configuration backup..."

    if [[ ! -f "$p10k_file" ]]; then
        log_warn "PowerLevel10k configuration not found: $p10k_file"
        return 1
    fi

    create_backup "$p10k_file" "$backup_dir" "p10k"
}

# Backup VS Code settings
create_vscode_backup() {
    local backup_dir="${1:-}"
    [[ -n "$backup_dir" ]] || backup_dir=$(_backup_default_dir) || return 1
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
    local backup_dir="${3:-}"
    [[ -n "$backup_dir" ]] || backup_dir=$(_backup_default_dir) || return 1
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
        # shellcheck disable=SC2181 # P2-9: $? check kept (assignment above); refactor would change control flow
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
    local backup_dir="${1:-}"
    [[ -n "$backup_dir" ]] || backup_dir=$(_backup_default_dir) || return 1
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
    local backup_dir="${1:-}"
    [[ -n "$backup_dir" ]] || backup_dir=$(_backup_default_dir) || return 1
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
                    cleanup_count=$((cleanup_count + 1))  # portable: avoids exit-1 from n=$(( n + 1 )) when n=0 under set -e
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
                    cleanup_count=$((cleanup_count + 1))  # portable: avoids exit-1 from n=$(( n + 1 )) when n=0 under set -e
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

# Name grammar (A3): restrictive identifier — letters, digits, underscore,
# hyphen only, 1-63 chars. Names are interpolated into filesystem paths and
# metadata, so anything else is rejected outright.
_TRANSACTION_NAME_RE='^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$'

# A3: content hashes use whatever 256-bit tool the platform provides.
_txn_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    fi
}

# Audit journal (P3-2 seed; M2: metadata recorded per operation). Best-effort:
# a journal failure is surfaced but never blocks rollback safety.
_txn_journal() {
    # Preview events are console-only: creating an audit directory or appending
    # even one record would violate the transaction's zero-write contract.
    [[ "${_TRANSACTION_ACTIVE:-}" == "dryrun" || "${TRANSACTION_DRY_RUN:-0}" == 1 ]] && return 0
    local event="$1" detail="$2"
    local journal="${TXN_AUDIT_LOG:-$HOME/.config/version-manager/audit.log}"
    local dir
    dir=$(dirname "$journal")
    if ! mkdir -p "$dir" 2>/dev/null; then
        log_warn "audit journal unavailable: $journal"
        return 0
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "$event" "${_TRANSACTION_NAME:-}" "${_TRANSACTION_DIR:-}" "$detail" >> "$journal" 2>/dev/null \
        || log_warn "audit journal write failed: $journal"
}

# Start a new transaction
# Usage: transaction_start "theme_installation"
transaction_start() {
    local name="${1-transaction}"  # empty arg is NOT defaulted — it must fail the grammar

    if [[ -n "$_TRANSACTION_ACTIVE" ]]; then
        log_error "Transaction already active: $_TRANSACTION_NAME"
        return 1
    fi

    if ! [[ "$name" =~ $_TRANSACTION_NAME_RE ]]; then
        log_error "Invalid transaction name '${name}' (allowed: letters, digits, underscore, hyphen; max 63 chars)"
        return 1
    fi

    # Dry-run (mutation invariant): plan-only — zero filesystem writes.
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        _TRANSACTION_ACTIVE="dryrun"
        _TRANSACTION_NAME="$name"
        _TRANSACTION_DIR=""
        _TRANSACTION_FILES=()
        LOG_FILE='' log_info "Transaction (dry-run, zero writes): $name"
        _txn_journal "start" "mode=dry_run"
        return 0
    fi

    local backup_dir
    backup_dir=$(_backup_default_dir) || return 1
    _TRANSACTION_NAME="$name"
    _TRANSACTION_FILES=()
    _TRANSACTION_ACTIVE="true"

    # Resolve once at start; _TRANSACTION_DIR pins this transaction's pre-state
    # even when the caller subsequently changes HOME.
    if ! mkdir -p "$backup_dir/transactions" 2>/dev/null; then
        log_error "Cannot create transactions directory: $backup_dir/transactions"
        _TRANSACTION_ACTIVE=""
        return 1
    fi
    _TRANSACTION_DIR=$(mktemp -d "${backup_dir}/transactions/${name}.XXXXXX") || {
        log_error "Cannot create transaction directory"
        _TRANSACTION_ACTIVE=""
        return 1
    }
    mkdir -p "$_TRANSACTION_DIR/files"
    : > "$_TRANSACTION_DIR/files.tsv"
    : > "$_TRANSACTION_DIR/new_files.txt"

    # Metadata: the name is grammar-validated (no quotes/separators), so the
    # interpolation below cannot be corrupted into invalid JSON.
    cat > "$_TRANSACTION_DIR/metadata.json" << EOF
{
    "name": "$name",
    "started_at": "$(date -Iseconds)",
    "status": "active",
    "layout": 2,
    "files": []
}
EOF

    _txn_journal "start" "mode=apply dir=$_TRANSACTION_DIR"
    log_info "Transaction started: $name"
    log_debug "Transaction directory: $_TRANSACTION_DIR"
    return 0
}

# Add a file to the current transaction (creates hash-verified backup)
# Usage: transaction_add_file "/path/to/file"
transaction_add_file() {
    local file="$1"

    if [[ -z "$_TRANSACTION_ACTIVE" ]]; then
        log_error "No active transaction"
        return 1
    fi

    if [[ "$_TRANSACTION_ACTIVE" == "dryrun" ]]; then
        LOG_FILE='' log_info "[dry-run] would register: $file"
        return 0
    fi

    # A3: the registry is tab-delimited; embedded newlines/tabs would corrupt
    # it. Reject such paths outright (fail closed).
    if [[ "$file" == *$'\n'* || "$file" == *$'\t'* ]]; then
        log_error "Refusing to register a path containing newline/tab: $file"
        return 1
    fi

    # Idempotent duplicate registration: the same path registered twice keeps
    # its first backup (the pre-transaction state).
    local registered_kind registered_idx registered_sha registered_path
    while IFS=$'\t' read -r registered_kind registered_idx registered_sha registered_path; do
        if [[ "$registered_path" == "$file" ]]; then
            log_debug "Already registered, idempotent: $file"
            return 0
        fi
    done < "$_TRANSACTION_DIR/files.tsv"
    if grep -qxF -- "$file" "$_TRANSACTION_DIR/new_files.txt" 2>/dev/null; then
        log_debug "Already registered, idempotent: $file"
        return 0
    fi

    # New files: nothing to back up; recorded for removal on rollback.
    if [[ ! -e "$file" && ! -L "$file" ]]; then
        log_debug "File does not exist yet, marking as new: $file"
        echo "$file" >> "$_TRANSACTION_DIR/new_files.txt"
        _TRANSACTION_FILES+=("NEW:$file")
        return 0
    fi

    # A3: path-preserving layout — each registration gets its own index
    # directory; backups are keyed by index, never by basename, so
    # /a/config and /b/config can never collapse into one entry.
    local idx
    idx=$(printf '%04d' "$(wc -l < "$_TRANSACTION_DIR/files.tsv" | tr -d ' ')")
    local entry_dir="$_TRANSACTION_DIR/files/$idx"
    mkdir -p "$entry_dir" || { log_error "Cannot create backup entry dir"; return 1; }

    local kind sha
    if [[ -L "$file" ]]; then
        # Symlink semantics (M2): preserve the LINK itself, not the target's
        # content. The stored payload is the link target; rollback recreates
        # the link.
        kind="symlink"
        readlink "$file" > "$entry_dir/data" || { log_error "Cannot read symlink: $file"; return 1; }
    elif [[ -f "$file" ]]; then
        kind="file"
        # Preserve permissions explicitly: BSD cp -p also propagates immutable
        # flags, making backup payloads unremovable and breaking rollback.
        cp "$file" "$entry_dir/data" || { log_error "Cannot back up: $file"; return 1; }
        local mode
        mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null) || return 1
        chmod "$mode" "$entry_dir/data" || return 1
    else
        log_error "Unsupported file type (not regular/symlink): $file"
        return 1
    fi

    sha=$(_txn_sha256 "$entry_dir/data")
    printf '%s\t%s\t%s\t%s\n' "$kind" "$idx" "$sha" "$file" >> "$_TRANSACTION_DIR/files.tsv"
    _TRANSACTION_FILES+=("$file")
    log_debug "Added to transaction [$idx kind=$kind sha=${sha:0:12}]: $file"
    return 0
}

# Commit the transaction (mark complete; backups retained until cleanup)
# Usage: transaction_commit
transaction_commit() {
    if [[ -z "$_TRANSACTION_ACTIVE" ]]; then
        log_error "No active transaction to commit"
        return 1
    fi

    if [[ "$_TRANSACTION_ACTIVE" != "dryrun" ]]; then
        cat > "$_TRANSACTION_DIR/metadata.json" << EOF
{
    "name": "$_TRANSACTION_NAME",
    "completed_at": "$(date -Iseconds)",
    "status": "committed",
    "layout": 2,
    "files_count": ${#_TRANSACTION_FILES[@]}
}
EOF
        _txn_journal "commit" "files=${#_TRANSACTION_FILES[@]}"
        log_success "Transaction committed: $_TRANSACTION_NAME (${#_TRANSACTION_FILES[@]} files)"
    else
        _txn_journal "commit" "mode=dry_run"
        LOG_FILE='' log_info "Dry-run transaction committed (zero writes): $_TRANSACTION_NAME"
    fi

    _TRANSACTION_ACTIVE=""
    _TRANSACTION_NAME=""
    _TRANSACTION_DIR=""
    _TRANSACTION_FILES=()
    return 0
}

# Rollback the transaction (hash-verified restore: byte-identical or loud)
# Usage: transaction_rollback
transaction_rollback() {
    if [[ -z "$_TRANSACTION_ACTIVE" ]]; then
        log_error "No active transaction to rollback"
        return 1
    fi

    if [[ "$_TRANSACTION_ACTIVE" == "dryrun" ]]; then
        _txn_journal "rollback" "mode=dry_run"
        LOG_FILE='' log_info "Dry-run rollback (zero writes): $_TRANSACTION_NAME"
        _TRANSACTION_ACTIVE=""
        _TRANSACTION_NAME=""
        _TRANSACTION_DIR=""
        _TRANSACTION_FILES=()
        return 0
    fi

    log_warn "Rolling back transaction: $_TRANSACTION_NAME"

    local rollback_errors=0

    # Restore backed-up entries: verify the backup's own hash first (a
    # tampered/corrupt backup must never be presented as a successful
    # restore), then restore, then verify the restored bytes.
    if [[ -s "$_TRANSACTION_DIR/files.tsv" ]]; then
        while IFS=$'\t' read -r kind idx sha path; do
            local data="$_TRANSACTION_DIR/files/$idx/data"
            if [[ ! -f "$data" ]]; then
                log_error "Backup payload missing for [$idx]: $path"
                rollback_errors=$((rollback_errors + 1))
                continue
            fi
            if [[ "$(_txn_sha256 "$data")" != "$sha" ]]; then
                log_error "Backup hash mismatch for [$idx] $path — refusing to restore tampered data"
                rollback_errors=$((rollback_errors + 1))
                continue
            fi
            if [[ "$kind" == "symlink" ]]; then
                # B1.11-new: guard the destructive steps exactly like the
                # file branch. A bare `rm -f` here aborted the whole rollback
                # under an adopter's `set -e` (EACCES unlink) — after the
                # [WARN], BEFORE the journal/metadata record — silently
                # losing the rollback record. Count the failure and keep
                # going; the rolled_back_with_errors path surfaces it loudly.
                if rm -f "$path" 2>/dev/null && ln -s "$(cat "$data")" "$path" 2>/dev/null; then
                    log_debug "Restored symlink: $path"
                else
                    log_error "Failed to restore symlink: $path"
                    rollback_errors=$((rollback_errors + 1))
                fi
            else
                local restored_mode
                restored_mode=$(stat -c '%a' "$data" 2>/dev/null || stat -f '%Lp' "$data" 2>/dev/null) || restored_mode=''
                if [[ -n "$restored_mode" ]] && cp "$data" "$path" 2>/dev/null && chmod "$restored_mode" "$path" 2>/dev/null; then
                    if [[ "$(_txn_sha256 "$path")" == "$sha" ]]; then
                        log_debug "Restored (hash-verified): $path"
                    else
                        log_error "Restored bytes differ from recorded pre-state: $path"
                        rollback_errors=$((rollback_errors + 1))
                    fi
                else
                    log_error "Failed to restore: $path"
                    rollback_errors=$((rollback_errors + 1))
                fi
            fi
        done < "$_TRANSACTION_DIR/files.tsv"
    fi

    # Remove newly created files (guarded like the restore branch — B1.11-new:
    # a failed rm under an adopter's set -e must count, not abort the rollback
    # before its record is written).
    if [[ -s "$_TRANSACTION_DIR/new_files.txt" ]]; then
        while IFS= read -r new_file; do
            [[ -z "$new_file" ]] && continue
            if [[ -e "$new_file" || -L "$new_file" ]]; then
                if rm -f "$new_file" 2>/dev/null; then
                    log_debug "Removed new file: $new_file"
                else
                    log_error "Failed to remove new file during rollback: $new_file"
                    rollback_errors=$((rollback_errors + 1))
                fi
            fi
        done < "$_TRANSACTION_DIR/new_files.txt"
    fi

    if [[ $rollback_errors -gt 0 ]]; then
        cat > "$_TRANSACTION_DIR/metadata.json" << EOF
{
    "name": "$_TRANSACTION_NAME",
    "rolled_back_at": "$(date -Iseconds)",
    "status": "rolled_back_with_errors",
    "layout": 2,
    "errors": $rollback_errors
}
EOF
        _txn_journal "rollback" "status=with_errors errors=$rollback_errors"
        log_error "Rollback FAILED for $rollback_errors entr(y/ies) — success not claimed"
        local ret=$rollback_errors
        _TRANSACTION_ACTIVE=""
        _TRANSACTION_NAME=""
        _TRANSACTION_DIR=""
        _TRANSACTION_FILES=()
        return "$ret"
    fi

    cat > "$_TRANSACTION_DIR/metadata.json" << EOF
{
    "name": "$_TRANSACTION_NAME",
    "rolled_back_at": "$(date -Iseconds)",
    "status": "rolled_back",
    "layout": 2,
    "errors": 0
}
EOF
    _txn_journal "rollback" "status=ok hash_verified"
    log_info "Rollback completed successfully (hash-verified)"

    _TRANSACTION_ACTIVE=""
    _TRANSACTION_NAME=""
    _TRANSACTION_DIR=""
    _TRANSACTION_FILES=()
    return 0
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

# Validate restore point name to prevent path traversal / unsafe deletions.
_validate_restore_point_name() {
    local name="$1"
    [[ -n "$name" ]] || return 1
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]
}

# Create a named restore point
# Usage: create_restore_point "before_theme_change" "/path/to/file1" "/path/to/file2"
create_restore_point() {
    local name="$1"
    shift
    local files=("$@")

    if ! _validate_restore_point_name "$name"; then
        log_error "Invalid restore point name. Use only letters, numbers, '.', '_' or '-'."
        return 1
    fi

    local backup_dir restore_dir
    backup_dir=$(_backup_default_dir) || return 1
    restore_dir="$backup_dir/restore_points/$name"

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
            file_count=$((file_count + 1))  # portable: avoids exit-1 from n=$(( n + 1 )) when n=0 under set -e
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
#
# Modes (P3-1, lane C2 — lane-R NO-GO follow-up):
#   default (RESTORE_ALL_OR_NOTHING unset or 0): file-by-file restore with a
#     per-file "<original>.pre-restore" snapshot. Historical behavior — a
#     mid-restore failure leaves earlier files restored (partial apply) and
#     returns nonzero. Preserved unchanged for backward compatibility.
#   RESTORE_ALL_OR_NOTHING=1: ONE transaction registers the pre-restore
#     state of EVERY point file BEFORE the first restore runs. If any single
#     restore fails, the transaction rolls back — every file returns
#     byte-identical to its pre-restore state (hash-verified by
#     transaction_rollback) — and this function exits nonzero. Symlinked
#     originals are refused (cp would write through the link to an
#     unregistered target, which the rollback cannot guarantee).
#   TRANSACTION_DRY_RUN=1 (with the mode on): plan-only — reports the file
#     count, performs zero writes.
#
# Usage: restore_from_point "before_theme_change"
#        RESTORE_ALL_OR_NOTHING=1 restore_from_point "before_theme_change"
restore_from_point() {
    local name="$1"

    if ! _validate_restore_point_name "$name"; then
        log_error "Invalid restore point name. Use only letters, numbers, '.', '_' or '-'."
        return 1
    fi

    local backup_dir restore_dir
    backup_dir=$(_backup_default_dir) || return 1
    restore_dir="$backup_dir/restore_points/$name"

    if [[ ! -d "$restore_dir" ]]; then
        log_error "Restore point not found: $name"
        return 1
    fi

    if [[ ! -f "$restore_dir/mappings.txt" ]]; then
        log_error "Restore point corrupted: missing mappings"
        return 1
    fi

    log_info "Restoring from: $name"

    if [[ "${RESTORE_ALL_OR_NOTHING:-0}" == "1" ]]; then
        _restore_from_point_atomic "$name" "$restore_dir"
        return $?
    fi

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
                restore_count=$((restore_count + 1))  # portable: avoids exit-1 from n=$(( n + 1 )) when n=0 under set -e
            else
                log_error "Failed to restore: $original"
                restore_errors=$((restore_errors + 1))  # portable: avoids exit-1 from n=$(( n + 1 )) when n=0 under set -e
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

# All-or-nothing restore core (P3-1). One transaction covers the whole
# point: every original is registered BEFORE the first restore, so the
# pre-restore bytes of all files are on disk before anything is touched.
_restore_from_point_atomic() {
    local name="$1"
    local restore_dir="$2"

    # Transaction names reject '.' (grammar: letters/digits/_/-); restore
    # point names allow it. Transliterate and clamp to the 63-char grammar.
    local txn_name="restore-${name//./_}"
    txn_name="${txn_name:0:63}"

    # Collect the restorable mappings first. Both the dry-run plan and the
    # real transaction read the same file; missing backups are skipped in
    # both modes (a point file that lost its backup cannot be restored).
    local -a originals=() backups=()
    local original backup
    while IFS='|' read -r original backup; do
        [[ -z "${original:-}" && -z "${backup:-}" ]] && continue
        if [[ ! -f "$backup" ]]; then
            log_warn "Skipping missing backup file: $backup"
            continue
        fi
        # Fail closed BEFORE any write: a symlinked original would make
        # cp write through the link into an unregistered target — rollback
        # restores the link, not the target's bytes, so byte-identical
        # guarantees would be void.
        if [[ -L "${original:-}" ]]; then
            log_error "All-or-nothing restore refuses symlinked original: $original"
            return 1
        fi
        originals+=("$original")
        backups+=("$backup")
    done < "$restore_dir/mappings.txt"

    # Dry-run (mutation invariant): plan-only, zero filesystem writes.
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would restore ${#originals[@]} file(s) from restore point '$name' (all-or-nothing)"
        return 0
    fi

    # ONE transaction for the whole point. If it cannot start (e.g. another
    # transaction is active), nothing has been written yet — fail closed.
    if ! transaction_start "$txn_name"; then
        log_error "Cannot start all-or-nothing restore transaction for '$name'"
        return 1
    fi

    # Registration phase: capture every original's pre-state. Any failure
    # here aborts before the FIRST restore (nothing to roll back, but the
    # transaction is closed cleanly).
    local i
    for ((i = 0; i < ${#originals[@]}; i++)); do
        if ! transaction_add_file "${originals[$i]}"; then
            log_error "Registration failed for '${originals[$i]}' — aborting before any restore"
            transaction_rollback
            return 1
        fi
    done

    # Restore phase: the FIRST failure stops the loop; the transaction rolls
    # back everything restored so far, byte-identical (hash-verified).
    local restore_count=0
    local restore_errors=0
    for ((i = 0; i < ${#originals[@]}; i++)); do
        if cp "${backups[$i]}" "${originals[$i]}"; then
            log_debug "Restored: ${originals[$i]}"
            restore_count=$((restore_count + 1))  # portable: avoids exit-1 from n=$(( n + 1 )) when n=0 under set -e
        else
            log_error "Failed to restore: ${originals[$i]} — rolling back the whole point"
            restore_errors=$((restore_errors + 1))  # portable: avoids exit-1 from n=$(( n + 1 )) when n=0 under set -e
            break
        fi
    done

    if [[ $restore_errors -gt 0 ]]; then
        # Byte-identical rollback is hash-verified by transaction_rollback.
        # Its own status is surfaced; the restore failure decides the exit.
        if ! transaction_rollback; then
            log_error "All-or-nothing rollback reported errors for restore point '$name' (see transaction metadata)"
        fi
        log_error "Restore point '$name' NOT applied (all-or-nothing): pre-restore state restored"
        return 1
    fi

    if ! transaction_commit; then
        log_error "Transaction commit failed after restoring '$name'"
        return 1
    fi

    log_success "Restored $restore_count files from: $name (all-or-nothing)"
    return 0
}

# List available restore points
# Usage: list_restore_points
list_restore_points() {
    local backup_dir restore_base
    backup_dir=$(_backup_default_dir) || return 1
    restore_base="$backup_dir/restore_points"

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
    if ! _validate_restore_point_name "$name"; then
        log_error "Invalid restore point name. Use only letters, numbers, '.', '_' or '-'."
        return 1
    fi

    local backup_dir restore_dir
    backup_dir=$(_backup_default_dir) || return 1
    restore_dir="$backup_dir/restore_points/$name"

    if [[ ! -d "$restore_dir" ]]; then
        log_error "Restore point not found: $name"
        return 1
    fi

    rm -rf "$restore_dir"
    log_info "Deleted restore point: $name"
    return 0
}

# Export functions for use in other scripts
export -f _backup_default_dir
export -f create_backup create_zshrc_backup create_p10k_backup create_vscode_backup
export -f restore_backup list_backups cleanup_old_backups validate_backup
export -f transaction_start transaction_add_file transaction_commit transaction_rollback
export -f transaction_is_active transaction_get_name
export -f create_restore_point restore_from_point list_restore_points delete_restore_point
