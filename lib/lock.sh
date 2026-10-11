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
        "$state_dir"/locks/*.lock.d) ;;
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

# Stale-lock reclamation (F3, re-audit 2026-10-10). A lock directory is never
# renamed or moved: the earlier rename-to-grave design could move a LIVE lock
# aside (when the path was recycled between the staleness decision and the
# rename), let a third process acquire the empty path meanwhile, and its
# "restore" mv then nested the displaced lock inside the new one. Reclaiming
# now uses only conditional single-syscall removals:
#   - `rmdir <lock>/owner.<pid>` for each owner marker whose pid is dead; it
#     fails if that marker is already gone (another reclaimer won);
#   - `rmdir <lock>`, which succeeds only while the directory is EMPTY. A lock
#     carrying a live owner marker can therefore never be removed. An empty
#     directory is either the crash orphan that was judged or a claim in its
#     mkdir->mkdir window; such a claimer's owner mkdir then fails, or lands in
#     a newer lock and loses the sole-owner check below, so it retries.
# Residual: pid reuse between the kill -0 probe and the rmdir of that pid's
# marker (microseconds) is not detectable with a pid-based owner identity.
_lock_reclaim_if_stale() {
    local lock_dir="$1" marker pid any=0

    for marker in "$lock_dir"/owner.*; do
        [[ -d "$marker" ]] || continue
        any=1
        pid="${marker##*/owner.}"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            return 1    # live owner: never touched
        fi
    done
    if (( any == 0 )); then
        # No owner marker: the microsecond claim window, or a crash orphan
        # between the two mkdirs. Only age can decide.
        _lock_dir_older_than "$lock_dir" 5 || return 1
    fi

    for marker in "$lock_dir"/owner.*; do
        [[ -d "$marker" ]] || continue
        pid="${marker##*/owner.}"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            return 1    # appeared since the first pass
        fi
        rmdir "$marker" 2>/dev/null || return 1
    done
    if rmdir "$lock_dir" 2>/dev/null; then
        log_warn "Reclaimed stale lock: $lock_dir"
        return 0
    fi
    return 1
}

# True when this process's owner marker is the only one in the lock dir. Two
# markers can coexist only if a stalled claimer's owner mkdir landed in a newer
# lock; the claimer whose marker came later always sees the earlier one and
# withdraws, so two processes can never both pass this check.
_lock_sole_owner() {
    local lock_dir="$1" marker
    [[ -d "$lock_dir/owner.$$" ]] || return 1
    for marker in "$lock_dir"/owner.*; do
        [[ "$marker" == "$lock_dir/owner.$$" ]] && continue
        [[ -d "$marker" ]] && return 1
    done
    return 0
}

# Withdraw a claim that did not become sole ownership: remove only this
# process's marker, then the lock dir only if it is now empty. Never rm -rf: the
# directory may already hold another process's marker.
_lock_withdraw_claim() {
    local lock_dir="$1"
    rmdir "$lock_dir/owner.$$" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
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
            if _lock_mark_owner "$lock_dir" && _lock_sole_owner "$lock_dir"; then
                return 0
            fi
            # Our claim was displaced (the owner mkdir hit a removed parent) or
            # landed beside an earlier owner: withdraw only our part; retry.
            _lock_withdraw_claim "$lock_dir"
        elif _lock_reclaim_if_stale "$lock_dir"; then
            # RA-1: the lock is free now; retry at once. Checking the
            # whole-second timeout first could give up a few milliseconds
            # after a successful reclaim when the clock ticked over.
            continue
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

    # AX-10: inside a subshell, bash >= 4 keeps DISPLAYING the parent's traps
    # via `trap -p` until the subshell modifies any trap, although they are no
    # longer active there. Chaining that stale display would run the parent's
    # EXIT command (e.g. a caller's cleanup) when this subshell exits.
    # Resetting an otherwise-unused signal discards the stale display and
    # leaves any EXIT trap the subshell set itself intact (bash 3.2 never
    # shows the inherited display, so this is a no-op there).
    if ((BASH_SUBSHELL > 0)) && [[ -z "$(trap -p SIGURG)" ]]; then
        trap - SIGURG 2>/dev/null || true
    fi

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
