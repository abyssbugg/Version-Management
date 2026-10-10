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
        # The cmp verdict IS the answer when cmp exists; sha256 is only the
        # fallback for hosts without diffutils (builds #22-#23 lesson).
        cmp -s "$a" "$b"
        return $?
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

# Marker integrity (AX-8): every managed-block edit first audits the target's
# markers for <name>. A BEGIN without its END, an END without a BEGIN, or a
# second BEGIN is MALFORMED — the block-stripping pass would otherwise treat
# every line after a stray BEGIN as block content and silently delete it.
# Malformed files are refused unchanged; the user repairs the markers.
# Prints "absent" or "present"; returns 1 when malformed or unreadable.
_mutation_markers_state() {
    local file="$1" name="$2" state=""
    if [[ ! -e "$file" ]]; then
        printf 'absent\n'
        return 0
    fi
    state=$(awk -v b="$(mutation_begin_marker "$name")" -v e="$(mutation_end_marker "$name")" '
        $0 == b { if (inside || starts) bad = 1; inside = 1; starts++; next }
        $0 == e { if (!inside) bad = 1; inside = 0; next }
        END {
            if (bad || inside) { print "malformed"; exit 0 }
            print (starts ? "present" : "absent")
        }' "$file") || return 1
    [[ "$state" == absent || "$state" == present ]] || return 1
    printf '%s\n' "$state"
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

# Probe dialects in separate assignments: a failed stat can still emit stdout.
# Existing file permissions must be readable and preserved before publication.
_mutation_preserve_mode() {
    local target="$1" tmp="$2" mode=644
    if [[ -e "$target" ]]; then
        if ! mode=$(stat -c '%a' "$target" 2>/dev/null); then
            mode=$(stat -f '%Lp' "$target" 2>/dev/null) || return 1
        fi
        [[ "$mode" =~ ^[0-7]{1,4}$ ]] || return 1
    fi
    chmod "$mode" "$tmp"
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

    # AX-8: refuse malformed markers BEFORE anything is registered or written.
    local marker_state
    if ! marker_state=$(_mutation_markers_state "$file" "$name"); then
        log_error "mutation_block_write: malformed managed-block markers for '$name' in $file (unterminated, stray or duplicate BEGIN/END) — refusing; file left unchanged. Repair the markers and retry."
        return 1
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

    # Compose the new file. An existing <name> block is replaced IN PLACE
    # (AX-8): moving it to the end of the file on every content change would
    # reorder the user's rc — a later user line that depends on the block
    # (e.g. `nvm use 18` after the NVM block) would then run before it. A new
    # block is appended at the end; distinct-name blocks coexist. Block body
    # lines are emitted by awk so a body without a trailing newline cannot
    # glue the END marker onto its last line.
    local tmp
    tmp=$(mktemp "$dir/.vms-mutation.XXXXXX") || { log_error "mutation: cannot create temp file in $dir"; return 1; }

    if [[ "$marker_state" == present ]]; then
        VMS_MUTATION_CONTENT="$content_file" awk -v b="$begin" -v e="$end" '
            $0 == b {
                print
                while ((r = (getline line < ENVIRON["VMS_MUTATION_CONTENT"])) > 0) print line
                if (r < 0) exit 2
                close(ENVIRON["VMS_MUTATION_CONTENT"])
                inblock = 1
                next
            }
            $0 == e { inblock = 0; print; next }
            inblock { next }
            { print }
        ' "$file" > "$tmp" || { rm -f "$tmp"; log_error "mutation: read failed: $file"; return 1; }
    else
        if [[ -f "$file" ]]; then
            # Copy, dropping trailing empty lines before appending so
            # idempotent rewrites do not accumulate blank lines (empty lines
            # inside the file are kept: they are buffered and re-emitted as
            # soon as a non-empty line follows).
            awk '$0 == "" { blanks++; next } { while (blanks > 0) { print ""; blanks-- } print }' \
                "$file" > "$tmp" || { rm -f "$tmp"; log_error "mutation: read failed: $file"; return 1; }
        else
            : > "$tmp"
        fi
        {
            printf '%s\n' "$begin"
            awk '{ print }' "$content_file"
            printf '%s\n' "$end"
        } >> "$tmp" || { rm -f "$tmp"; log_error "mutation: cannot compose block: $file"; return 1; }
    fi

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        rm -f "$tmp"
        log_info "[dry-run] mutation_block_write would update: $file ($name)"
        _txn_journal "mutation_write" "mode=dry_run target=$file block=$name result=planned exit_code=0"
        return 0
    fi

    # Preserve the resolved content-file mode, not a symlink's unrelated mode.
    if ! _mutation_preserve_mode "$write_target" "$tmp"; then
        rm -f "$tmp"
        log_error "mutation_block_write: cannot preserve mode: $write_target"
        return 1
    fi

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
        _txn_journal "mutation_write" "target=$file block=$name via=$write_target result=written exit_code=0"
    else
        _txn_journal "mutation_write" "target=$file block=$name result=written exit_code=0"
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

    # AX-8: a malformed block would make the strip pass delete every line
    # after a stray BEGIN — refuse unchanged, before registering anything.
    if ! _mutation_markers_state "$file" "$name" >/dev/null; then
        log_error "mutation_block_remove: malformed managed-block markers for '$name' in $file (unterminated, stray or duplicate BEGIN/END) — refusing; file left unchanged. Repair the markers and retry."
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

    if ! _mutation_preserve_mode "$write_target" "$tmp"; then
        rm -f "$tmp"
        log_error "mutation_block_remove: cannot preserve mode: $write_target"
        return 1
    fi
    if ! mv "$tmp" "$write_target"; then
        rm -f "$tmp"
        log_error "mutation_block_remove: atomic rename failed: $write_target"
        return 1
    fi
    mutation_block_has "$file" "$name" && { log_error "remove verification failed"; return 1; }

    if [[ "$write_target" != "$file" ]]; then
        _txn_journal "mutation_remove" "target=$file block=$name via=$write_target result=removed exit_code=0"
    else
        _txn_journal "mutation_remove" "target=$file block=$name result=removed exit_code=0"
    fi
    log_info "Managed block removed: $file ($name)"
    return 0
}

# Publish a WHOLE generated file atomically and idempotently (AX-18): the
# version-advanced.sh generators (Dockerfiles, docker-compose.yml, CI configs)
# used to `cat >` straight over a user's existing — possibly hand-edited —
# file with no backup, no preview and no atomicity.
# Usage: mutation_file_publish <file> <content-file>
# Same contract as mutation_block_write:
#   - an active transaction is required; the pre-state (including "did not
#     exist") is registered BEFORE the write, so rollback restores or removes
#     the file byte-identically;
#   - a symlink target stays a link — the rename lands on the resolved file
#     (both registered); a target that is not a regular file is refused;
#   - the existing file's mode is kept (a new file gets 0644);
#   - identical content is a no-op (nothing registered, no mtime churn);
#   - TRANSACTION_DRY_RUN=1 plans only — nothing is created, not even the
#     parent directory;
#   - the published bytes are verified against the content file.
mutation_file_publish() {
    local file="$1" content_file="$2"

    [[ -n "$file" && -n "$content_file" ]] || { log_error "mutation_file_publish: empty argument"; return 1; }
    [[ -f "$content_file" ]] || { log_error "mutation content file missing: $content_file"; return 1; }
    [[ -n "$_TRANSACTION_ACTIVE" ]] || {
        log_error "mutation_file_publish requires an active transaction (call transaction_start first)"
        return 1
    }
    validate_safe_path "$file" >/dev/null 2>&1 || {
        log_error "mutation_file_publish: target failed lexical validation: $file"
        return 1
    }

    local dir write_target="$file"
    dir=$(dirname "$file")
    if [[ -L "$file" ]]; then
        mutation_resolve_content_target "$file" || return 1
        write_target="$_MUTATION_RESOLVED_TARGET"
        dir=$(dirname "$write_target")
    fi
    if [[ -e "$write_target" && ! -f "$write_target" ]]; then
        log_error "mutation_file_publish: target exists and is not a regular file — refusing: $file"
        return 1
    fi

    if [[ -f "$write_target" ]] && mutation_files_identical "$content_file" "$write_target"; then
        LOG_FILE='' log_info "Unchanged (already up to date): $file"
        return 0
    fi

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        if [[ -e "$file" || -L "$file" ]]; then
            LOG_FILE='' log_info "[dry-run] would replace: $file (the current file would be backed up first)"
        else
            LOG_FILE='' log_info "[dry-run] would create: $file"
        fi
        _txn_journal "mutation_publish" "mode=dry_run target=$file result=planned exit_code=0"
        return 0
    fi

    [[ -d "$dir" ]] || { log_error "mutation target directory missing: $dir"; return 1; }

    transaction_add_file "$file" || return 1
    if [[ "$write_target" != "$file" ]]; then
        transaction_add_file "$write_target" || return 1
    fi

    local tmp
    tmp=$(mktemp "$dir/.vms-mutation.XXXXXX") || { log_error "mutation: cannot create temp file in $dir"; return 1; }
    if ! cat -- "$content_file" > "$tmp"; then
        rm -f -- "$tmp"
        log_error "mutation_file_publish: cannot stage content for $file"
        return 1
    fi
    if ! _mutation_preserve_mode "$write_target" "$tmp"; then
        rm -f -- "$tmp"
        log_error "mutation_file_publish: cannot preserve mode: $write_target"
        return 1
    fi
    if ! mv -- "$tmp" "$write_target"; then
        rm -f -- "$tmp"
        log_error "mutation_file_publish: atomic rename failed: $write_target"
        return 1
    fi
    if ! mutation_files_identical "$content_file" "$write_target"; then
        log_error "mutation_file_publish: post-write verification FAILED: $file"
        return 1
    fi

    if [[ "$write_target" != "$file" ]]; then
        _txn_journal "mutation_publish" "target=$file via=$write_target result=published exit_code=0"
    else
        _txn_journal "mutation_publish" "target=$file result=published exit_code=0"
    fi
    log_info "Published: $file"
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
