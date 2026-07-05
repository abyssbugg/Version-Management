#!/usr/bin/env bash
# shellcheck disable=SC1091  # SC1091: dynamic source path for logger fallback

# Prevent re-sourcing
[[ -n "${_LOCK_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_LOCK_SH_LOADED=1

# =============================================================================
# Atomic Locking Utilities for Version Management Setup
# =============================================================================
# Purpose: serialize workstation-mutating entry points with POSIX-atomic mkdir.
# Public API: lock_acquire, lock_release, lock_with_trap.
# Dependencies: mkdir, rm, kill, date, optional lib/logger.sh.
# Failure modes: invalid names, timeout, unsafe deletion path, pid ownership mismatch.
# =============================================================================

_LOCK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F log_warn >/dev/null 2>&1; then
    if [[ -f "$_LOCK_LIB_DIR/logger.sh" ]]; then
        # shellcheck source=lib/logger.sh
        source "$_LOCK_LIB_DIR/logger.sh"
    else
        log_info() { echo "[INFO] $1"; }
        log_warn() { echo "[WARN] $1" >&2; }
        log_error() { echo "[ERROR] $1" >&2; }
        log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo "[DEBUG] $1"; }
    fi
fi

_lock_state_dir() {
    printf '%s\n' "${VMS_STATE_DIR:-$HOME/.local/state/version-manager}"
}

_lock_validate_name() {
    local name="${1:-}"

    if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        log_error "Invalid lock name: $name"
        return 1
    fi
}

_lock_validate_timeout() {
    local timeout="${1:-}"

    if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
        log_error "Invalid lock timeout: $timeout"
        return 1
    fi
}

_lock_dir_for_name() {
    local name="$1"
    local state_dir
    state_dir="$(_lock_state_dir)"

    printf '%s\n' "$state_dir/locks/$name.lock.d"
}

_lock_guarded_rm_lock_dir() {
    local lock_dir="$1"
    local state_dir
    state_dir="$(_lock_state_dir)"

    case "$lock_dir" in
        "$state_dir"/locks/*.lock.d|"$state_dir"/locks/*.lock.d.reclaim.*) ;;
        *)
            log_error "Refusing to remove unsafe lock path: $lock_dir"
            return 1
            ;;
    esac

    case "$lock_dir" in
        *'/../'*|*'/..'|'../'*)
            log_error "Refusing to remove lock path with parent traversal: $lock_dir"
            return 1
            ;;
    esac

    rm -rf -- "$lock_dir"
}

# Ownership protocol: the owner is encoded as a MARKER DIRECTORY named
# owner.<pid> inside the lock dir, created with a single atomic mkdir.
# No data is ever written, so no reader can observe a partially-written
# owner — the marker either exists or it does not. (Replaces the earlier
# pid-file + claiming-marker design, whose transient write states caused
# live locks to be misjudged as stale under contention.)

# Print the owner pid of a lock dir; fail if no owner marker exists.
_lock_owner_pid() {
    local lock_dir="$1" marker
    for marker in "$lock_dir"/owner.*; do
        [[ -d "$marker" ]] || continue
        printf '%s\n' "${marker##*/owner.}"
        return 0
    done
    return 1
}

# Claim ownership of a freshly created lock dir (single atomic syscall).
_lock_mark_owner() {
    mkdir "$1/owner.$$" 2>/dev/null
}

# True if the directory's mtime is older than $2 seconds.
_lock_dir_older_than() {
    local dir="$1" age="$2" dir_mtime now
    dir_mtime=$(stat -c %Y "$dir" 2>/dev/null || stat -f %m "$dir" 2>/dev/null)
    now=$(date +%s)
    [[ "$dir_mtime" =~ ^[0-9]+$ ]] && (( now - dir_mtime > age ))
}

_lock_is_stale() {
    local lock_dir="$1" owner

    if owner="$(_lock_owner_pid "$lock_dir")" && [[ "$owner" =~ ^[0-9]+$ ]]; then
        kill -0 "$owner" 2>/dev/null && return 1
        return 0    # numeric, dead owner: crash orphan (GLM review finding #1)
    fi

    # No owner marker: either the microsecond mkdir→mkdir claim window, or a
    # crash orphan between those two syscalls. Only age can decide.
    _lock_dir_older_than "$lock_dir" 5 && return 0
    return 1
}

_lock_reclaim_if_stale() {
    local lock_dir="$1"
    local grave="$lock_dir.reclaim.$$"
    local pid claimer

    if ! _lock_is_stale "$lock_dir"; then
        return 1
    fi

    # Atomic rename: exactly one contender wins the reclaim; losers see ENOENT
    # and simply retry acquisition. Deleting in place would race a concurrent
    # release+reacquire and destroy a LIVE lock (ABA hazard).
    if ! mv "$lock_dir" "$grave" 2>/dev/null; then
        return 1
    fi

    # Post-rename verify on the grave's owner marker:
    #  - LIVE owner  -> the path was recycled by a full release+reacquire
    #                   between our staleness decision and the rename; restore.
    #  - dead owner  -> definitively stale; delete.
    #  - no owner    -> either the stale orphan we judged, or a displaced
    #                   in-flight claim; deleting is SAFE in both cases because
    #                   an in-flight claimer's owner-mkdir fails (parent moved)
    #                   and it simply retries. Ownership is never stolen.
    local owner
    if owner="$(_lock_owner_pid "$grave")" && [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
        if ! mv "$grave" "$lock_dir" 2>/dev/null; then
            log_error "Lock reclaim race displaced a live lock; manual cleanup may be needed: $grave"
        fi
        return 1
    fi

    log_warn "Reclaiming stale lock: $lock_dir"
    if ! _lock_guarded_rm_lock_dir "$grave"; then
        log_warn "Stale lock detected but removal failed (permissions?): $grave"
        return 1
    fi
}

# Remove the lock dir only if this process owns it. Prevents deleting another
# process's fresh lock after ours was displaced by a racing reclaimer.
_lock_cleanup_own_claim() {
    local lock_dir="$1"
    if [[ -d "$lock_dir/owner.$$" ]]; then
        _lock_guarded_rm_lock_dir "$lock_dir" || true
    fi
}

lock_acquire() {
    local name="${1:-}"
    local timeout="${2:-30}"

    _lock_validate_name "$name" || return 1
    _lock_validate_timeout "$timeout" || return 1

    local lock_dir lock_root start now
    lock_dir="$(_lock_dir_for_name "$name")"
    lock_root="$(dirname "$lock_dir")"
    start=$(date +%s)

    if ! mkdir -p "$lock_root"; then
        log_error "Failed to create lock directory root: $lock_root"
        return 1
    fi

    while true; do
        if mkdir "$lock_dir" 2>/dev/null; then
            if _lock_mark_owner "$lock_dir"; then
                return 0
            fi
            # Our dir was displaced mid-claim by a racing reclaimer (owner
            # mkdir hit a moved parent). Clean up only if still ours; retry.
            _lock_cleanup_own_claim "$lock_dir"
        else
            _lock_reclaim_if_stale "$lock_dir" || true
        fi

        now=$(date +%s)
        if (( now - start >= timeout )); then
            log_error "Failed to acquire lock '$name' after ${timeout}s"
            return 1
        fi

        sleep 0.1
    done
}

lock_release() {
    local name="${1:-}"

    _lock_validate_name "$name" || return 1

    local lock_dir owner
    lock_dir="$(_lock_dir_for_name "$name")"

    if [[ ! -d "$lock_dir" ]]; then
        return 0
    fi

    if [[ ! -d "$lock_dir/owner.$$" ]]; then
        owner="$(_lock_owner_pid "$lock_dir" 2>/dev/null || true)"
        log_warn "Refusing to release lock '$name' owned by pid ${owner:-unknown}"
        return 1
    fi

    _lock_guarded_rm_lock_dir "$lock_dir"
}

_lock_extract_exit_trap_command() {
    local trap_output="$1"

    [[ -n "$trap_output" ]] || return 1
    trap_output="${trap_output#trap -- \'}"
    trap_output="${trap_output%\' EXIT}"
    printf '%s\n' "$trap_output"
}

# TRAP-OWNERSHIP CONTRACT: lock_with_trap chains onto any EXISTING EXIT trap,
# but bash cannot protect the chain afterwards — any later `trap ... EXIT` in
# the same shell REPLACES it and leaks the lock until stale reclaim kicks in.
# Callers MUST register lock_with_trap LAST, after setup_error_trap,
# setup_cache_cleanup, or any other EXIT-trap registration. A registry-based
# cleanup contract is planned alongside the Phase 3 mutation framework.
lock_with_trap() {
    local name="${1:-}"
    local timeout="${2:-30}"

    lock_acquire "$name" "$timeout" || return 1

    local existing_trap existing_command release_command
    existing_trap=$(trap -p EXIT || true)
    release_command="lock_release '$name'"

    if [[ -n "$existing_trap" ]]; then
        existing_command="$(_lock_extract_exit_trap_command "$existing_trap")"
        if [[ -n "$existing_command" ]]; then
            trap -- "$existing_command; $release_command" EXIT
        else
            trap -- "$release_command" EXIT
        fi
    else
        trap -- "$release_command" EXIT
    fi
}
