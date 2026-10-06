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
#   - SYMLINK TARGETS keep being symlinks (M2 semantics, B1.10-new): the
#     atomic rename lands on the RESOLVED content file (temp file in the
#     resolved file's directory, same-filesystem rename) — the link itself
#     and its target string survive verbatim. Both the link (kind=symlink)
#     and the resolved content file (kind=file/NEW) are transaction-registered
#     so a rollback restores the user's bytes, not just the link.
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

# B1.13-new: source UNCONDITIONALLY. The old `declare -f` guards are defeated
# across process boundaries — backup.sh/validation.sh export -f their
# functions, so a child can inherit copies without the state globals
# (_TRANSACTION_ACTIVE et al. never initialized → set -u death on the first
# transaction call; reproduced by the adverse-condition suite). Both libs are
# re-source-safe (backup.sh guards its readonly block; validation.sh has no
# readonly state).
source "$_MUTATION_DIR/backup.sh"
source "$_MUTATION_DIR/validation.sh"

# Portable byte-identical check (M4 lesson): the Buildkite hosted Linux
# agent image does NOT ship `cmp` (diffutils) — a missing cmp made every
# idempotent skip degrade into a silent same-bytes rewrite. sha256sum (or
# shasum) is present wherever this repo runs.
mutation_files_identical() {
    local a="$1" b="$2"
    [[ -f "$a" && -f "$b" ]] || return 1
    if command -v cmp >/dev/null 2>&1; then
        cmp -s "$a" "$b"   # verdict propagates — a return 0 here made every
                           # skip unconditional (builds #22-#23, "block absent")
    fi
    local ha hb
    ha=$(_txn_sha256 "$a")
    hb=$(_txn_sha256 "$b")
    [[ -n "$ha" && "$ha" == "$hb" ]]
}

mutation_begin_marker() { printf '# BEGIN version-management-setup:%s\n' "$1"; }
mutation_end_marker()   { printf '# END version-management-setup:%s\n' "$1"; }

mutation_block_has() {
    local file="$1" name="$2"
    [[ -f "$file" ]] || return 1
    grep -qF "$(mutation_begin_marker "$name")" "$file"
}

# B1.10-new: resolve the file whose CONTENT a managed-block write/remove must
# replace. If $1 is (a chain of) symlink(s), the atomic rename must land on
# the content file the link resolves to, so the link itself survives (M2
# symlink semantics — "preserve the LINK itself", lib/backup.sh
# transaction_add_file). Relative link targets are resolved against the
# link's own directory via cd+pwd (portable; no realpath dependency), with a
# bounded chain depth (ELOOP equivalent). On success sets
# _MUTATION_RESOLVED_TARGET to the absolute path of the final content file;
# the cwd is never changed (resolution runs in a command substitution).
mutation_resolve_content_target() {
    local path="$1" link hops=0
    _MUTATION_RESOLVED_TARGET="$path"
    while [[ -L "$_MUTATION_RESOLVED_TARGET" ]]; do
        hops=$((hops + 1))
        if [[ $hops -gt 40 ]]; then
            log_error "mutation: symlink chain too deep (>40 hops): $path"
            return 1
        fi
        link=$(readlink "$_MUTATION_RESOLVED_TARGET") || {
            log_error "mutation: cannot read symlink target: $_MUTATION_RESOLVED_TARGET"
            return 1
        }
        if [[ "$link" == /* ]]; then
            _MUTATION_RESOLVED_TARGET="$link"
        else
            _MUTATION_RESOLVED_TARGET="$(dirname "$_MUTATION_RESOLVED_TARGET")/$link"
        fi
    done
    # Canonical directory of the final hop (resolves '..' components and
    # gives an absolute path for the same-directory mktemp + atomic rename).
    # A missing/unreachable directory is a hard error: a dangling chain
    # cannot be written through.
    local resolved_dir
    resolved_dir=$(cd "$(dirname "$_MUTATION_RESOLVED_TARGET")" 2>/dev/null && pwd) || {
        log_error "mutation: symlink target directory missing or unreachable: $(dirname "$_MUTATION_RESOLVED_TARGET")"
        return 1
    }
    _MUTATION_RESOLVED_TARGET="$resolved_dir/$(basename "$_MUTATION_RESOLVED_TARGET")"
    return 0
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

    local dir write_target
    dir=$(dirname "$file")
    [[ -d "$dir" ]] || { log_error "mutation target directory missing: $dir"; return 1; }

    # B1.10-new: if the target is a symlink, the atomic rename must land on
    # the RESOLVED content file (same-directory temp + rename there) so the
    # link survives. A dangling chain fails closed here, and a chain that
    # resolves to a non-regular existing file (directory/fifo/...) is
    # refused before anything is registered.
    write_target="$file"
    if [[ -L "$file" ]]; then
        mutation_resolve_content_target "$file" || return 1
        write_target="$_MUTATION_RESOLVED_TARGET"
        if [[ -e "$write_target" && ! -f "$write_target" ]]; then
            log_error "mutation: symlink resolves to a non-regular file, refusing: $file -> $write_target"
            return 1
        fi
        dir=$(dirname "$write_target")
    fi

    # Existing target (or its not-yet-created state) is registered with the
    # transaction BEFORE any mutation so rollback restores the pre-state.
    # For a symlink target BOTH entries are registered: the link itself
    # (kind=symlink — link preserved, M2) and the resolved content file
    # (kind=file/NEW) — otherwise a rollback would recreate the link but
    # leave the user's file mutated (breaks the byte-identical-restore
    # contract, A3).
    if [[ "$_TRANSACTION_ACTIVE" != "dryrun" ]]; then
        transaction_add_file "$file" || return 1
        if [[ "$write_target" != "$file" ]]; then
            transaction_add_file "$write_target" || return 1
        fi
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

    # Preserve the resolved content-file mode, not a symlink's unrelated mode.
    local mode
    mode=$(stat -f '%Lp' "$write_target" 2>/dev/null || stat -c '%a' "$write_target" 2>/dev/null || echo 644)
    chmod "$mode" "$tmp"

    # Idempotency: if the composed result equals the current file, skip.
    if [[ -f "$file" ]] && mutation_files_identical "$tmp" "$file"; then
        rm -f "$tmp"
        log_debug "mutation_block_write: already identical, no change: $file ($name)"
        return 0
    fi

    # Atomic: same-directory rename — onto the RESOLVED content file for a
    # symlink target, so the link itself is never touched (B1.10-new).
    if ! mv "$tmp" "$write_target"; then
        rm -f "$tmp"
        log_error "mutation_block_write: atomic rename failed: $write_target"
        return 1
    fi

    # Apply verification: the block must now be present and parseable.
    if ! mutation_block_has "$file" "$name"; then
        log_error "mutation_block_write: post-write verification FAILED: $file ($name)"
        return 1
    fi

    if [[ "$write_target" != "$file" ]]; then
        _txn_journal "mutation_write" "file=$file block=$name via=$write_target"
    else
        _txn_journal "mutation_write" "file=$file block=$name"
    fi
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

    # B1.10-new (same defect class as the write path): a removal through a
    # symlink must rename onto the RESOLVED content file, never over the
    # link. Both pre-states are registered like in mutation_block_write.
    local write_target="$file"
    if [[ -L "$file" ]]; then
        mutation_resolve_content_target "$file" || return 1
        write_target="$_MUTATION_RESOLVED_TARGET"
        if [[ -e "$write_target" && ! -f "$write_target" ]]; then
            log_error "mutation_block_remove: symlink resolves to a non-regular file, refusing: $file -> $write_target"
            return 1
        fi
        if [[ "$_TRANSACTION_ACTIVE" != "dryrun" ]]; then
            transaction_add_file "$write_target" || return 1
        fi
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
    tmp=$(mktemp "$(dirname "$write_target")/.vms-mutation.XXXXXX") || return 1
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
    mode=$(stat -f '%Lp' "$write_target" 2>/dev/null || stat -c '%a' "$write_target" 2>/dev/null || echo 644)
    chmod "$mode" "$tmp"
    if ! mv "$tmp" "$write_target"; then
        rm -f "$tmp"
        log_error "mutation_block_remove: atomic rename failed: $write_target"
        return 1
    fi
    mutation_block_has "$file" "$name" && { log_error "remove verification failed"; return 1; }

    if [[ "$write_target" != "$file" ]]; then
        _txn_journal "mutation_remove" "file=$file block=$name via=$write_target"
    else
        _txn_journal "mutation_remove" "file=$file block=$name"
    fi
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
