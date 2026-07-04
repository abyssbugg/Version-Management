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

_lock_pid_from_file() {
    local pid_file="$1"
    local pid

    pid=$(cat "$pid_file" 2>/dev/null || true)
    printf '%s\n' "$pid"
}

_lock_write_pid_file() {
    local lock_dir="$1"
    local pid_tmp="$lock_dir/pid.$$"
    local claiming_file="$lock_dir/claiming"

    if ! printf '%s\n' "$$" > "$claiming_file"; then
        rm -f -- "$claiming_file" 2>/dev/null || true
        return 1
    fi

    if ! printf '%s\n' "$$" > "$pid_tmp"; then
        rm -f -- "$pid_tmp" 2>/dev/null || true
        rm -f -- "$claiming_file" 2>/dev/null || true
        return 1
    fi

    if ! mv -f -- "$pid_tmp" "$lock_dir/pid"; then
        rm -f -- "$pid_tmp" "$claiming_file" 2>/dev/null || true
        return 1
    fi

    rm -f -- "$claiming_file" 2>/dev/null || true
}

_lock_is_stale() {
    local lock_dir="$1"
    local pid_file="$lock_dir/pid"
    local pid

    if [[ -f "$lock_dir/claiming" ]]; then
        return 1
    fi

    if [[ ! -f "$pid_file" ]]; then
        return 1
    fi

    pid="$(_lock_pid_from_file "$pid_file")"
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    if kill -0 "$pid" 2>/dev/null; then
        return 1
    fi

    return 0
}

_lock_reclaim_if_stale() {
    local lock_dir="$1"

    if ! _lock_is_stale "$lock_dir"; then
        return 1
    fi

    log_warn "Reclaiming stale lock: $lock_dir"
    _lock_guarded_rm_lock_dir "$lock_dir"
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
            if _lock_write_pid_file "$lock_dir"; then
                return 0
            fi

            log_error "Failed to write lock pid: $lock_dir/pid"
            _lock_guarded_rm_lock_dir "$lock_dir" || true
            return 1
        fi

        if _lock_reclaim_if_stale "$lock_dir"; then
            if mkdir "$lock_dir" 2>/dev/null; then
                if _lock_write_pid_file "$lock_dir"; then
                    return 0
                fi

                log_error "Failed to write lock pid: $lock_dir/pid"
                _lock_guarded_rm_lock_dir "$lock_dir" || true
                return 1
            fi
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

    local lock_dir pid_file pid
    lock_dir="$(_lock_dir_for_name "$name")"
    pid_file="$lock_dir/pid"

    if [[ ! -d "$lock_dir" ]]; then
        return 0
    fi

    pid="$(_lock_pid_from_file "$pid_file")"
    if [[ "$pid" != "$$" ]]; then
        log_warn "Refusing to release lock '$name' owned by pid ${pid:-unknown}"
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

lock_with_trap() {
    local name="${1:-}"
    local timeout="${2:-30}"

    lock_acquire "$name" "$timeout" || return 1

    local existing_trap existing_command release_command
    existing_trap=$(trap -p EXIT || true)
    release_command="lock_release '$name'"

    if [[ -n "$existing_trap" ]]; then
        existing_command="$(_lock_extract_exit_trap_command "$existing_trap")"
        trap -- "$existing_command; $release_command" EXIT
    else
        trap -- "$release_command" EXIT
    fi
}