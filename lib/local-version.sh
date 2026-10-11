#!/usr/bin/env bash
# Transactional project version files (A3-3).
# API: local_version_publish <file> <version> [command arg...].
# Dependencies: mutation.sh. Failure returns nonzero; owned file state rolls back.
# Callback argv runs in the caller shell. Runtime installs and manager-internal
# state are not rolled back. Active caller transactions are refused (no savepoints).
_VMS_LOCAL_VERSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/mutation.sh
source "$_VMS_LOCAL_VERSION_DIR/mutation.sh"

local_version_preflight() {
    if [[ "${TRANSACTION_DRY_RUN:-0}" != 1 ]] && transaction_is_active; then
        log_error "Local version changes require their own transaction"
        return 1
    fi
}

local_version_publish() {
    local file="${1:-}" version="${2:-}"
    [[ -n "$file" && -n "$version" ]] || return 1
    shift 2
    if [[ "${TRANSACTION_DRY_RUN:-0}" == 1 ]]; then
        LOG_FILE='' log_info "[dry-run] would set $file to $version"
        return 0
    fi
    local_version_preflight || return 1
    local content rc=0
    # Pin a relative project file before any callback can change the caller cwd.
    [[ "$file" == /* ]] || file="$PWD/$file"
    content=$(mktemp "${TMPDIR:-/tmp}/vms-local-version.XXXXXX") || return 1
    if ! printf '%s\n' "$version" > "$content"; then
        rm -f -- "$content"
        return 1
    fi
    if ! transaction_start local_version; then
        rm -f -- "$content"
        return 1
    fi
    # Manager callbacks can write the same version file themselves, even
    # when the publisher detects identical content and skips its own write.
    transaction_add_file "$file" || rc=$?
    if [[ $rc -eq 0 && -L "$file" ]]; then
        mutation_resolve_content_target "$file" || rc=$?
        if [[ $rc -eq 0 ]]; then
            transaction_add_file "$_MUTATION_RESOLVED_TARGET" || rc=$?
        fi
    fi
    if [[ $rc -eq 0 ]]; then
        mutation_file_publish "$file" "$content" || rc=$?
    fi
    rm -f -- "$content"
    if [[ $rc -eq 0 && $# -gt 0 ]]; then
        "$@" >/dev/null 2>&1 || rc=$?
    fi
    if [[ $rc -eq 0 ]]; then
        transaction_commit || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        transaction_rollback || log_error "Local version rollback failed; inspect retained backup"
    fi
    return "$rc"
}
