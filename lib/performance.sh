#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source paths; SC2034: intentionally exported vars
# ============================================================================
# Performance Optimization Utilities
# Part of Professional Development Terminal Setup
# ============================================================================
# Provides performance-focused utilities including:
#   - Command caching for repeated lookups
#   - Parallel version manager detection
#   - Shell startup time monitoring
#   - Lazy loading helpers
# ============================================================================

# Prevent re-sourcing
[[ -n "${_PERFORMANCE_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_PERFORMANCE_SH_LOADED=1

# In-memory caches (associative arrays) - requires bash 4+
_PERF_HAS_ASSOC=false
if (( ${BASH_VERSINFO[0]:-0} >= 4 )); then
    _PERF_HAS_ASSOC=true
    declare -gA COMMAND_CACHE 2>/dev/null || declare -A COMMAND_CACHE
    declare -gA VERSION_CACHE 2>/dev/null || declare -A VERSION_CACHE
    declare -gA STARTUP_TIMES 2>/dev/null || declare -A STARTUP_TIMES
else
    VERSION_CACHE_KEYS=()
    VERSION_CACHE_VALUES=()
fi

# Performance configuration
PERF_STARTUP_THRESHOLD_MS="${PERF_STARTUP_THRESHOLD_MS:-500}"
PERF_PARALLEL_DETECTION="${PERF_PARALLEL_DETECTION:-true}"
PERF_LOG_STARTUP="${PERF_LOG_STARTUP:-false}"
PERF_STARTUP_LOG="${PERF_STARTUP_LOG:-$HOME/.cache/version-manager/startup.log}"
PERF_CACHE_DIR="${PERF_CACHE_DIR:-$HOME/.cache/version-manager/performance}"

# ============================================================================
# Command Caching
# ============================================================================

# Check if command exists with caching
# Usage: cache_command "git"
cache_command() {
    local cmd="$1"
    if $_PERF_HAS_ASSOC && [[ -n "${COMMAND_CACHE[$cmd]+x}" ]]; then
        return "${COMMAND_CACHE[$cmd]}"
    fi

    if command -v "$cmd" >/dev/null 2>&1; then
        $_PERF_HAS_ASSOC && COMMAND_CACHE[$cmd]=0
        return 0
    else
        $_PERF_HAS_ASSOC && COMMAND_CACHE[$cmd]=1
        return 1
    fi
}

_performance_log_warn() {
    local message="$1"

    if declare -f log_warn >/dev/null 2>&1; then
        log_warn "$message"
    else
        echo "WARNING: $message" >&2
    fi
}

_cache_version_get_fallback() {
    local cache_name="$1"
    local cache_index

    for cache_index in "${!VERSION_CACHE_KEYS[@]}"; do
        if [[ "${VERSION_CACHE_KEYS[$cache_index]}" == "$cache_name" ]]; then
            echo "${VERSION_CACHE_VALUES[$cache_index]}"
            return 0
        fi
    done

    return 1
}

_cache_version_set_fallback() {
    local cache_name="$1"
    local version="$2"
    local cache_index

    for cache_index in "${!VERSION_CACHE_KEYS[@]}"; do
        if [[ "${VERSION_CACHE_KEYS[$cache_index]}" == "$cache_name" ]]; then
            VERSION_CACHE_VALUES[cache_index]="$version"
            return 0
        fi
    done

    VERSION_CACHE_KEYS+=("$cache_name")
    VERSION_CACHE_VALUES+=("$version")
}

_cache_version_file() {
    local cache_name="$1"
    local cache_key

    cache_key=$(printf '%s' "$cache_name" | shasum -a 256 2>/dev/null | cut -d' ' -f1)
    if [[ -z "$cache_key" ]]; then
        cache_key=$(printf '%s' "$cache_name" | md5 2>/dev/null | awk '{print $NF}')
    fi
    if [[ -z "$cache_key" ]]; then
        cache_key=$(printf '%s' "$cache_name" | tr -c 'A-Za-z0-9_-' '_')
    fi

    printf '%s/version-%s.cache\n' "$PERF_CACHE_DIR" "$cache_key"
}

# Get cached version of a command's output using argv execution.
# Usage: cached_version=$(cache_version "node" node --version)
cache_version() {
    local cache_name="$1"
    shift

    if [[ -z "$cache_name" || "$#" -eq 0 ]]; then
        return 1
    fi

    if $_PERF_HAS_ASSOC && [[ -n "${VERSION_CACHE[$cache_name]+x}" ]]; then
        echo "${VERSION_CACHE[$cache_name]}"
        return 0
    fi

    if ! $_PERF_HAS_ASSOC && _cache_version_get_fallback "$cache_name"; then
        return 0
    fi

    local cache_file
    cache_file=$(_cache_version_file "$cache_name")
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
        return 0
    fi

    local version
    version=$("$@" 2>/dev/null) || return 1
    if $_PERF_HAS_ASSOC; then
        VERSION_CACHE[$cache_name]="$version"
    else
        _cache_version_set_fallback "$cache_name" "$version"
    fi
    local cache_tmp="$cache_file.$$"
    mkdir -p "$PERF_CACHE_DIR" 2>/dev/null && {
        printf '%s\n' "$version" > "$cache_tmp" 2>/dev/null &&
            mv -f "$cache_tmp" "$cache_file" 2>/dev/null
    }
    echo "$version"
}

cache_version_argv() {
    cache_version "$@"
}

# Clear all caches
clear_caches() {
    if $_PERF_HAS_ASSOC; then
        COMMAND_CACHE=()
        VERSION_CACHE=()
    fi

    VERSION_CACHE_KEYS=()
    VERSION_CACHE_VALUES=()
    rm -f "$PERF_CACHE_DIR"/version-*.cache 2>/dev/null || true
}

# ============================================================================
# Startup Time Monitoring
# ============================================================================

# Record a startup timing checkpoint
# Usage: perf_checkpoint "nvm_loaded"
perf_checkpoint() {
    local name="$1"
    local timestamp_ms

    # Get millisecond timestamp
    if [[ "$(uname)" == "Darwin" ]]; then
        timestamp_ms=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || date +%s000)
    else
        timestamp_ms=$(date +%s%3N 2>/dev/null || date +%s000)
    fi

    if $_PERF_HAS_ASSOC; then
        STARTUP_TIMES[$name]="$timestamp_ms"
    fi
}

# Calculate elapsed time between two checkpoints
# Usage: elapsed=$(perf_elapsed "start" "end")
perf_elapsed() {
    local start_name="$1"
    local end_name="$2"

    if ! $_PERF_HAS_ASSOC; then
        echo "0"
        return
    fi

    local start_time="${STARTUP_TIMES[$start_name]:-0}"
    local end_time="${STARTUP_TIMES[$end_name]:-0}"

    echo $(( end_time - start_time ))
}

# Measure shell startup time
# Usage: startup_ms=$(measure_shell_startup)
# NOTE: spawns an interactive shell; the recursion guard (_MEASURING_STARTUP)
# prevents infinite recursion when the spawned shell sources this file.
measure_shell_startup() {
    # Recursion guard: the spawned interactive shell inherits _MEASURING_STARTUP=1
    # so any re-entry of this function in the child shell is a no-op.
    if [[ -n "${_MEASURING_STARTUP:-}" ]]; then
        return 0
    fi

    local shell="${SHELL:-/bin/bash}"
    local start_time end_time

    start_time=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time() * 1000))')

    # Run shell with minimal commands to measure startup.
    # Pass _MEASURING_STARTUP so child shell skips re-entering this function.
    _MEASURING_STARTUP=1 "$shell" -i -c 'exit 0' 2>/dev/null

    end_time=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time() * 1000))')

    echo $(( end_time - start_time ))
}

# Log startup time if enabled
# Usage: log_startup_time 523 "Full shell initialization"
log_startup_time() {
    local time_ms="$1"
    local description="${2:-Shell startup}"

    if [[ "$PERF_LOG_STARTUP" == "true" ]]; then
        mkdir -p "$(dirname "$PERF_STARTUP_LOG")"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${description}: ${time_ms}ms" >> "$PERF_STARTUP_LOG"
    fi

    # Warn if startup is slow
    if (( time_ms > PERF_STARTUP_THRESHOLD_MS )); then
        echo "[PERF WARNING] $description took ${time_ms}ms (threshold: ${PERF_STARTUP_THRESHOLD_MS}ms)" >&2
    fi
}

# ============================================================================
# Parallel Version Manager Detection
# ============================================================================

# Detect all version managers in parallel
# Usage: detect_version_managers_parallel
# Sets global variables: HAS_NVM, HAS_PYENV, HAS_GOENV, HAS_RUSTUP, HAS_JENV
detect_version_managers_parallel() {
    if [[ "$PERF_PARALLEL_DETECTION" != "true" ]]; then
        # Fall back to sequential detection
        detect_version_managers_sequential
        return
    fi

    local temp_dir
    temp_dir=$(mktemp -d)

    # Launch parallel detection jobs
    (cache_command nvm && echo "1" > "$temp_dir/nvm" || echo "0" > "$temp_dir/nvm") &
    (cache_command pyenv && echo "1" > "$temp_dir/pyenv" || echo "0" > "$temp_dir/pyenv") &
    (cache_command goenv && echo "1" > "$temp_dir/goenv" || echo "0" > "$temp_dir/goenv") &
    (cache_command rustup && echo "1" > "$temp_dir/rustup" || echo "0" > "$temp_dir/rustup") &
    (cache_command jenv && echo "1" > "$temp_dir/jenv" || echo "0" > "$temp_dir/jenv") &

    # Wait for all jobs
    wait

    # Read results
    HAS_NVM=$(cat "$temp_dir/nvm" 2>/dev/null || echo "0")
    HAS_PYENV=$(cat "$temp_dir/pyenv" 2>/dev/null || echo "0")
    HAS_GOENV=$(cat "$temp_dir/goenv" 2>/dev/null || echo "0")
    HAS_RUSTUP=$(cat "$temp_dir/rustup" 2>/dev/null || echo "0")
    HAS_JENV=$(cat "$temp_dir/jenv" 2>/dev/null || echo "0")

    # Cleanup
    rm -rf "$temp_dir"

    # Export for use in other scripts
    export HAS_NVM HAS_PYENV HAS_GOENV HAS_RUSTUP HAS_JENV
}

# Sequential fallback for systems without parallel support
detect_version_managers_sequential() {
    HAS_NVM=$(cache_command nvm && echo "1" || echo "0")
    HAS_PYENV=$(cache_command pyenv && echo "1" || echo "0")
    HAS_GOENV=$(cache_command goenv && echo "1" || echo "0")
    HAS_RUSTUP=$(cache_command rustup && echo "1" || echo "0")
    HAS_JENV=$(cache_command jenv && echo "1" || echo "0")

    export HAS_NVM HAS_PYENV HAS_GOENV HAS_RUSTUP HAS_JENV
}

# ============================================================================
# Lazy Loading Helpers
# ============================================================================

# Generate lazy loading wrapper for a command
# Usage: generate_lazy_wrapper "nvm" "source_nvm_if_available"
# This creates a function that replaces itself on first call
generate_lazy_wrapper() {
    local cmd="$1"
    local loader_func="$2"

    cat << EOF
$cmd() {
    unset -f $cmd
    $loader_func
    $cmd "\$@"
}
EOF
}

# NVM lazy loading initialization
# Call this in .zshrc instead of sourcing nvm.sh directly
setup_nvm_lazy() {
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

    # Only setup if nvm exists
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
        # Lazy load nvm
        nvm() {
            unset -f nvm node npm npx
            source "$NVM_DIR/nvm.sh"
            nvm "$@"
        }

        # Lazy load node commands
        node() {
            unset -f nvm node npm npx
            source "$NVM_DIR/nvm.sh"
            node "$@"
        }

        npm() {
            unset -f nvm node npm npx
            source "$NVM_DIR/nvm.sh"
            npm "$@"
        }

        npx() {
            unset -f nvm node npm npx
            source "$NVM_DIR/nvm.sh"
            npx "$@"
        }
    fi
}

# Pyenv lazy loading initialization
setup_pyenv_lazy() {
    export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"

    if [[ -d "$PYENV_ROOT" ]]; then
        export PATH="$PYENV_ROOT/bin:$PATH"

        pyenv() {
            unset -f pyenv
            eval "$(command pyenv init -)"
            pyenv "$@"
        }
    fi
}

# ============================================================================
# Performance Report
# ============================================================================

# Generate a performance report for shell startup
perf_report() {
    echo "=== Shell Performance Report ==="
    echo "Date: $(date)"
    echo ""

    # Measure current startup time
    local startup_time
    startup_time=$(measure_shell_startup)
    echo "Current shell startup time: ${startup_time}ms"
    echo "Threshold: ${PERF_STARTUP_THRESHOLD_MS}ms"

    if (( startup_time > PERF_STARTUP_THRESHOLD_MS )); then
        echo "Status: SLOW (exceeds threshold)"
    else
        echo "Status: OK"
    fi
    echo ""

    # Show detected version managers
    detect_version_managers_parallel
    echo "Detected Version Managers:"
    [[ "$HAS_NVM" == "1" ]] && echo "  ✓ nvm" || echo "  ✗ nvm"
    [[ "$HAS_PYENV" == "1" ]] && echo "  ✓ pyenv" || echo "  ✗ pyenv"
    [[ "$HAS_GOENV" == "1" ]] && echo "  ✓ goenv" || echo "  ✗ goenv"
    [[ "$HAS_RUSTUP" == "1" ]] && echo "  ✓ rustup" || echo "  ✗ rustup"
    [[ "$HAS_JENV" == "1" ]] && echo "  ✓ jenv" || echo "  ✗ jenv"
    echo ""

    # Recommendations
    if (( startup_time > PERF_STARTUP_THRESHOLD_MS )); then
        echo "Recommendations:"
        echo "  1. Enable lazy loading for version managers"
        echo "  2. Review .zshrc for heavy operations"
        echo "  3. Consider using 'setup_nvm_lazy' and 'setup_pyenv_lazy'"
        echo "  4. Check for synchronous plugin loading"
    fi
}

# ============================================================================
# Export Functions
# ============================================================================

export -f cache_command cache_version cache_version_argv clear_caches
export -f perf_checkpoint perf_elapsed measure_shell_startup log_startup_time
export -f detect_version_managers_parallel detect_version_managers_sequential
export -f generate_lazy_wrapper setup_nvm_lazy setup_pyenv_lazy
export -f perf_report
