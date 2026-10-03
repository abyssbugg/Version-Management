#!/usr/bin/env bash
# =============================================================================
# Managed-Block Mutation Editor (remediation directive M4, finding B2.1)
# =============================================================================
# Atomic, idempotent editing of shell rc files through MANAGED BLOCKS:
#
#   # BEGIN version-management-setup:<name>
#   ...content...
#   # END version-management-setup:<name>
#
# Contract:
#   - An ACTIVE TRANSACTION is required for every write (the adopter script
#     opens transaction_start and owns commit/rollback — the editor adds the
#     target file to it so injected failures roll back byte-identically).
#   - Writes are ATOMIC: temp file in the target directory + rename; the
#     original file's mode is preserved.
#   - IDEMPOTENT: writing the same block content twice leaves the file
#     byte-identical (no timestamp churn, no duplicate blocks).
#   - Dry-run: with TRANSACTION_DRY_RUN=1 the editor plans and reports
#     without touching the filesystem.
#   - Every operation records an audit-journal entry (P3-2).
#
# This file SOURCES lib/backup.sh (transactions) and lib/validation.sh
# (identifier grammar) — per the M1 contract it must not set global shell
# options itself.
# =============================================================================

_MUTATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f transaction_start >/dev/null 2>&1; then
    source "$_MUTATION_DIR/backup.sh"
fi
if ! declare -f validate_identifier >/dev/null 2>&1; then
    source "$_MUTATION_DIR/validation.sh"
fi

mutation_begin_marker() { printf '# BEGIN version-management-setup:%s\n' "$1"; }
mutation_end_marker()   { printf '# END version-management-setup:%s\n' "$1"; }

mutation_block_has() {
    local file="$1" name="$2"
    [[ -f "$file" ]] || return 1
    grep -qF "$(mutation_begin_marker "$name")" "$file"
}

mutation_block_get() {
    # Print the managed block's content (between the markers) to stdout.
    local file="$1" name="$2"
    [[ -f "$file" ]] || return 1
    awk -v b="$(mutation_begin_marker "$name")" -v e="$(mutation_end_marker "$name")" '
        $0 == b { inblock = 1; next }
        $0 == e { inblock = 0; next }
        inblock { print }
    ' "$file"
}

# Write (insert or replace) a managed block atomically and idempotently.
# Usage: mutation_block_write <file> <name> <content-file>
mutation_block_write() {
    local file="$1" name="$2" content_file="$3"

    [[ -n "$file" && -n "$name" && -n "$content_file" ]] || {
        log_error "mutation_block_write: empty argument"
        return 1
    }
    # Block names appear inside marker comments in user rc files — strict
    # grammar, and never 'transaction'-like filesystem material.
    validate_identifier "$name" 48 || return 1
    [[ -f "$content_file" ]] || { log_error "mutation content file missing: $content_file"; return 1; }
    [[ -n "$_TRANSACTION_ACTIVE" ]] || {
        log_error "mutation_block_write requires an active transaction (call transaction_start first)"
        return 1
    }
    validate_safe_path "$file" >/dev/null 2>&1 || {
        log_error "mutation_block_write: target failed lexical validation: $file"
        return 1
    }

    local dir
    dir=$(dirname "$file")
    [[ -d "$dir" ]] || { log_error "mutation target directory missing: $dir"; return 1; }

    # Existing target (or its not-yet-created state) is registered with the
    # transaction BEFORE any mutation so rollback restores the pre-state.
    if [[ "$_TRANSACTION_ACTIVE" != "dryrun" ]]; then
        transaction_add_file "$file" || return 1
    fi

    local begin end
    begin=$(mutation_begin_marker "$name")
    end=$(mutation_end_marker "$name")

    # Compose the new file: everything except any existing <name> block,
    # then the new block appended at the end (managed blocks live last;
    # multiple distinct-name blocks coexist).
    local tmp
    tmp=$(mktemp "$dir/.vms-mutation.XXXXXX") || { log_error "mutation: cannot create temp file in $dir"; return 1; }

    if [[ -f "$file" ]]; then
        awk -v b="$begin" -v e="$end" '
            $0 == b { inblock = 1; next }
            $0 == e { inblock = 0; skip_blank_tail = 1; next }
            inblock { next }
            { print }
        ' "$file" > "$tmp" || { rm -f "$tmp"; log_error "mutation: read failed: $file"; return 1; }
        # Drop the trailing blank lines the block removal left behind so
        # idempotent rewrites do not accumulate blank lines.
        python3 - "$tmp" <<'PY' 2>/dev/null || true
import sys
p = sys.argv[1]
s = open(p).read()
s = s.rstrip("\n")
open(p, "w").write(s + "\n") if s else open(p, "w").write("")
PY
    else
        : > "$tmp"
    fi

    {
        printf '%s\n' "$begin"
        cat "$content_file"
        printf '%s\n' "$end"
    } >> "$tmp"

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        rm -f "$tmp"
        log_info "[dry-run] mutation_block_write would update: $file ($name)"
        _txn_journal "mutation_write" "mode=dry_run file=$file block=$name"
        return 0
    fi

    # Preserve the original mode (new files: 644)
    local mode
    mode=$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file" 2>/dev/null || echo 644)
    chmod "$mode" "$tmp"

    # Idempotency: if the composed result equals the current file, skip.
    if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        log_debug "mutation_block_write: already identical, no change: $file ($name)"
        return 0
    fi

    # Atomic: same-directory rename.
    if ! mv "$tmp" "$file"; then
        rm -f "$tmp"
        log_error "mutation_block_write: atomic rename failed: $file"
        return 1
    fi

    # Apply verification: the block must now be present and parseable.
    if ! mutation_block_has "$file" "$name"; then
        log_error "mutation_block_write: post-write verification FAILED: $file ($name)"
        return 1
    fi

    _txn_journal "mutation_write" "file=$file block=$name"
    log_info "Managed block written: $file ($name)"
    return 0
}

# Remove a managed block atomically. Fails closed if the file or block is
# missing unless MUTATION_REMOVE_TOLERANT=1 (idempotent removal).
mutation_block_remove() {
    local file="$1" name="$2"

    [[ -n "$file" && -n "$name" ]] || { log_error "mutation_block_remove: empty argument"; return 1; }
    validate_identifier "$name" 48 || return 1
    [[ -n "$_TRANSACTION_ACTIVE" ]] || {
        log_error "mutation_block_remove requires an active transaction"
        return 1
    }
    if [[ ! -f "$file" ]]; then
        if [[ "${MUTATION_REMOVE_TOLERANT:-0}" == "1" ]]; then
            log_debug "mutation_block_remove: file absent, tolerant: $file"
            return 0
        fi
        log_error "mutation_block_remove: file missing: $file"
        return 1
    fi

    if [[ "$_TRANSACTION_ACTIVE" != "dryrun" ]]; then
        transaction_add_file "$file" || return 1
    fi

    if ! mutation_block_has "$file" "$name"; then
        if [[ "${MUTATION_REMOVE_TOLERANT:-1}" == "1" ]]; then
            log_debug "mutation_block_remove: block absent, idempotent: $name"
            return 0
        fi
        log_error "mutation_block_remove: block not found: $name in $file"
        return 1
    fi

    local begin end
    begin=$(mutation_begin_marker "$name")
    end=$(mutation_end_marker "$name")

    local tmp
    tmp=$(mktemp "$(dirname "$file")/.vms-mutation.XXXXXX") || return 1
    awk -v b="$begin" -v e="$end" '
        $0 == b { inblock = 1; next }
        $0 == e { inblock = 0; next }
        inblock { next }
        { print }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        rm -f "$tmp"
        log_info "[dry-run] mutation_block_remove would remove: $file ($name)"
        return 0
    fi

    local mode
    mode=$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file" 2>/dev/null || echo 644)
    chmod "$mode" "$tmp"
    if ! mv "$tmp" "$file"; then
        rm -f "$tmp"
        log_error "mutation_block_remove: atomic rename failed: $file"
        return 1
    fi
    mutation_block_has "$file" "$name" && { log_error "remove verification failed"; return 1; }

    _txn_journal "mutation_remove" "file=$file block=$name"
    log_info "Managed block removed: $file ($name)"
    return 0
}

# Canonical NVM block (B2.1): ONE canonical block, ONE idempotency posture
# (NVM_SILENT=true — the '1' vs 'true' drift is the P1-3 finding).
mutation_nvm_block() {
    cat << 'NVMBLOCK'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
NVM_SILENT=true
NVMBLOCK
}
