#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source paths; SC2034: intentionally exported vars

# Python Version Management Library Module
# Part of Professional Development Terminal Setup
# Provides standardized Python version management interface using pyenv
# Integrates with foundational libraries for caching, logging, and environment setup

# Source foundational libraries
_VMS_PYVM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_VMS_PYVM_DIR}/env.sh"
source "${_VMS_PYVM_DIR}/cache.sh"
source "${_VMS_PYVM_DIR}/logger.sh"
# Unconditional (B1.13-new): install_dir_stage/install_dir_restore are
# export -f'd, so inherited copies would defeat a declare -f guard.
# backup.sh is re-source-safe (preserves live transaction state).
source "${_VMS_PYVM_DIR}/backup.sh"
# Legacy rc-block removal publishes through the mutation editor and takes
# the shared rc lock (AX-20).
# shellcheck source=lib/mutation.sh
source "${_VMS_PYVM_DIR}/mutation.sh"
# shellcheck source=lib/lock.sh
source "${_VMS_PYVM_DIR}/lock.sh"

# Python version management configuration
PYVM_CACHE_PREFIX="pyvm"
PYVM_CACHE_TTL=300  # 5 minutes cache for version lists

# ============================================================================
# PYENV DETECTION AND INSTALLATION
# ============================================================================

# Detect if pyenv is installed and available
# Returns: 0 if pyenv is available, 1 if not
pyvm_detect() {
    log_debug "Detecting pyenv installation"

    if command -v pyenv >/dev/null 2>&1; then
        local pyenv_version=$(pyenv --version 2>/dev/null | cut -d' ' -f2)
        log_info "pyenv detected: version $pyenv_version"
        return 0
    else
        log_warn "pyenv not found in PATH"
        return 1
    fi
}

# Install pyenv if missing
# Returns: 0 on success, 1 on failure
pyvm_install() {
    log_info "Installing pyenv..."

    if pyvm_detect; then
        log_info "pyenv already installed"
        return 0
    fi

    local os_type=$(detect_os)

    if ! command -v git >/dev/null 2>&1; then
        log_error "Git is required to install pyenv"
        return 1
    fi

    local target_dir="${PYENV_ROOT:-$HOME/.pyenv}"
    local repo_url="https://github.com/pyenv/pyenv.git"
    local plugin_url="https://github.com/pyenv/pyenv-virtualenv.git"

    export PYENV_ROOT="$target_dir"

    case "$os_type" in
        "macos")
            if command -v brew >/dev/null 2>&1; then
                # Homebrew does not use $target_dir: it is never moved aside
                # for this path (AX-6d brew-path displacement).
                if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
                    log_info "[dry-run] would run: brew install pyenv pyenv-virtualenv; nothing installed"
                    return 0
                fi
                log_info "Installing pyenv via Homebrew"
                if brew install pyenv pyenv-virtualenv; then
                    log_success "pyenv installed successfully via Homebrew"
                    return 0
                fi
                log_error "Failed to install pyenv via Homebrew"
                return 1
            fi
            ;;
        "linux")
            # Build dependencies are privileged (rule 1.2): plan + explicit
            # confirmation. Declining still clones pyenv (user-space).
            if command -v apt-get >/dev/null 2>&1; then
                _vms_privileged_steps "pyenv build dependencies via apt (sudo)" \
                    "Skipped pyenv build dependencies; pyenv itself is still installed." -- \
                    sudo apt-get update -- \
                    sudo apt-get install -y make build-essential libssl-dev zlib1g-dev \
                    libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm \
                    libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
                    libffi-dev liblzma-dev || true
            elif command -v yum >/dev/null 2>&1; then
                _vms_privileged_steps "pyenv build dependencies via yum (sudo)" \
                    "Skipped pyenv build dependencies; pyenv itself is still installed." -- \
                    sudo yum install -y gcc zlib-devel bzip2 bzip2-devel readline-devel \
                    sqlite sqlite-devel openssl-devel tk-devel libffi-devel xz-devel || true
            fi
            ;;
    esac

    # AX-6d: stage the existing tree IMMEDIATELY before the clone; any
    # failure of the clone sequence restores it.
    local staged
    staged="$target_dir.bak.$(date +%Y%m%d_%H%M%S)"
    if [[ -d "$target_dir" ]]; then
        log_warn "Existing pyenv installation detected. Creating backup..."
    fi
    install_dir_stage "$target_dir" "$staged" || return 1

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would git clone $repo_url -> $target_dir (+ pyenv-virtualenv); nothing installed"
        return 0
    fi

    if ! git clone --depth 1 "$repo_url" "$target_dir"; then
        log_error "Failed to clone pyenv repository"
        install_dir_restore "$target_dir" "$staged" || true
        return 1
    fi

    if ! mkdir -p "$target_dir/plugins" \
        || ! git clone --depth 1 "$plugin_url" "$target_dir/plugins/pyenv-virtualenv"; then
        log_error "Failed to clone pyenv-virtualenv plugin"
        install_dir_restore "$target_dir" "$staged" || true
        return 1
    fi

    export PATH="$target_dir/bin:$PATH"
    log_success "pyenv installed successfully"
    return 0
}

# ============================================================================
# VERSION MANAGEMENT
# ============================================================================

# List available Python versions (cached)
# Returns: 0 on success, 1 on failure
pyvm_list_versions() {
    log_debug "Listing available Python versions"

    if ! pyvm_detect; then
        log_error "pyenv not available"
        return 1
    fi

    local cache_key="${PYVM_CACHE_PREFIX}_versions"
    local cached_versions

    if cached_versions=$(cache_get "$cache_key"); then
        log_debug "Using cached Python versions list"
        echo "$cached_versions"
        return 0
    fi

    log_debug "Fetching Python versions from pyenv"
    local versions
    if versions=$(pyenv versions --bare 2>/dev/null); then
        cache_set "$cache_key" "$versions" "$PYVM_CACHE_TTL"
        echo "$versions"
        return 0
    else
        log_error "Failed to list Python versions"
        return 1
    fi
}

# Install specific Python version
# Args: version - Python version to install (e.g., "3.12.8")
# Returns: 0 on success, 1 on failure
pyvm_install_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Python version not specified"
        return 1
    fi

    if ! _pyvm_validate_version "$version"; then
        return 1
    fi

    if ! pyvm_detect; then
        log_error "pyenv not available"
        return 1
    fi

    log_info "Installing Python $version..."

    # Check if already installed
    if pyenv versions --bare 2>/dev/null | grep -q "^${version}$"; then
        log_info "Python $version already installed"
        return 0
    fi

    # Install the version
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would run: pyenv install --skip-existing $version; nothing installed"
        return 0
    fi

    if pyenv install --skip-existing "$version" 2>/dev/null; then
        log_success "Python $version installed successfully"
        # Invalidate cache
        cache_delete "${PYVM_CACHE_PREFIX}_versions"
        return 0
    else
        log_error "Failed to install Python $version"
        return 1
    fi
}

# Set global Python version
# Args: version - Python version to set as global
# Returns: 0 on success, 1 on failure
pyvm_set_global() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Python version not specified"
        return 1
    fi

    if ! _pyvm_validate_version "$version"; then
        return 1
    fi

    if ! pyvm_detect; then
        log_error "pyenv not available"
        return 1
    fi

    # Check if version is installed
    if ! pyvm_validate_version "$version"; then
        log_warn "Python $version not found, attempting to install..."
        if ! pyvm_install_version "$version"; then
            return 1
        fi
    fi

    log_info "Setting global Python version to $version"
    if pyenv global "$version" 2>/dev/null; then
        log_success "Global Python version set to $version"
        return 0
    else
        log_error "Failed to set global Python version"
        return 1
    fi
}

# Set local Python version for current directory
# Args: version - Python version to set as local
# Returns: 0 on success, 1 on failure
pyvm_set_local() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Python version not specified"
        return 1
    fi

    if ! _pyvm_validate_version "$version"; then
        return 1
    fi

    if ! pyvm_detect; then
        log_error "pyenv not available"
        return 1
    fi

    # Check if version is installed
    if ! pyvm_validate_version "$version"; then
        log_warn "Python $version not found, attempting to install..."
        if ! pyvm_install_version "$version"; then
            return 1
        fi
    fi

    log_info "Setting local Python version to $version"

    # Create .python-version file
    if echo "$version" > .python-version; then
        # Set pyenv local version
        if pyenv local "$version" 2>/dev/null; then
            log_success "Local Python version set to $version"
            return 0
        else
            log_error "Failed to set local Python version with pyenv"
            return 1
        fi
    else
        log_error "Failed to create .python-version file"
        return 1
    fi
}

# Get current Python version
# Returns: current Python version string
pyvm_get_current() {
    log_debug "Getting current Python version"

    if ! pyvm_detect; then
        echo "system"
        return 1
    fi

    local current_version
    if current_version=$(pyenv version-name 2>/dev/null); then
        echo "$current_version"
        return 0
    else
        echo "system"
        return 1
    fi
}

# Validate that a Python version exists in installed versions
# Args: version - Python version to validate
# Returns: 0 if version exists, 1 if not
pyvm_validate_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Python version not specified"
        return 1
    fi

    if ! pyvm_detect; then
        log_error "pyenv not available"
        return 1
    fi

    log_debug "Validating Python version: $version"

    if pyenv versions --bare 2>/dev/null | grep -q "^${version}$"; then
        log_debug "Python version $version is installed"
        return 0
    else
        log_warn "Python version $version is not installed"
        return 1
    fi
}

# ============================================================================
# PRIVATE HELPER FUNCTIONS
# ============================================================================

# Validate Python version format
# Args: version - version string to validate
# Returns: 0 if valid format, 1 if invalid
_pyvm_validate_version() {
    local version="$1"

    if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid Python version format: $version"
        log_info "Expected format: major.minor.patch (e.g., 3.12.8)"
        return 1
    fi

    return 0
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Get Python version for prompt display (only if different from global)
# Returns: Python version string or empty if same as global
pyvm_get_prompt_version() {
    if ! pyvm_detect; then
        return 1
    fi

    local current_version=$(pyvm_get_current)
    local global_version=$(pyenv global 2>/dev/null || echo "system")

    # Only show if different from global or if project-specific
    if [ -f ".python-version" ] || [ "$current_version" != "$global_version" ]; then
        echo "$current_version"
    fi
}

# Check if current directory has Python project configuration
# Returns: 0 if Python project detected, 1 if not
pyvm_is_python_project() {
    [ -f ".python-version" ] || [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "setup.py" ]
}

# ============================================================================
# VIRTUAL ENVIRONMENT AUTO-ACTIVATION
# ============================================================================

# Search upward from $PWD for the nearest .venv / venv / .virtualenv directory.
# Args: [max_depth] — how many parent directories to climb (default: 3)
# Outputs: path to the activate script on stdout
# Returns: 0 if found, 1 if not
# shellcheck disable=SC2120  # optional args: callers may omit them (defaults apply)
_pyvm_find_venv() {
    local dir="$PWD"
    local max_depth="${1:-3}"
    local depth=0
    local venv_dirs=(".venv" "venv" ".virtualenv")

    while [[ "$dir" != "/" && $depth -lt $max_depth ]]; do
        for vname in "${venv_dirs[@]}"; do
            local candidate="$dir/$vname/bin/activate"
            if [[ -f "$candidate" ]]; then
                echo "$candidate"
                return 0
            fi
        done
        dir="$(dirname "$dir")"
        depth=$((depth + 1))
    done

    return 1
}

# Activate the nearest venv, or deactivate if none found in the directory tree.
# Safe to call from both bash (lib sourcing) and zsh hooks.
# Returns: 0 always
pyvm_auto_activate() {
    local activate_script
    if activate_script=$(_pyvm_find_venv); then
        local venv_dir
        venv_dir="$(dirname "$(dirname "$activate_script")")"

        # Already in this exact venv — nothing to do
        if [[ "${VIRTUAL_ENV:-}" == "$venv_dir" ]]; then
            return 0
        fi
        # Deactivate any currently active venv first
        if [[ -n "${VIRTUAL_ENV:-}" ]] && command -v deactivate >/dev/null 2>&1; then
            deactivate
        fi
        # shellcheck source=/dev/null
        source "$activate_script"
        log_debug "pyvm: activated venv at $activate_script"
    else
        # No venv in this directory tree — deactivate if one was active
        if [[ -n "${VIRTUAL_ENV:-}" ]] && command -v deactivate >/dev/null 2>&1; then
            deactivate
            log_debug "pyvm: deactivated venv (left project directory)"
        fi
    fi
    return 0
}

# Install the zsh chpwd auto-activate hook for ALL runtimes (Python, Node, Bun, Go, Ruby, Java).
# Delegates to the unified auto_activate_setup() in lib/auto-activate.sh.
# After running this once, every `cd` will trigger version switching for every supported runtime.
# Returns: 0 on success, 1 on failure
pyvm_setup_auto_activate() {
    # Source and delegate to the unified installer.
    # shellcheck source=lib/auto-activate.sh
    source "${_VMS_PYVM_DIR}/auto-activate.sh"
    auto_activate_setup
    return $?
}

# Remove the auto-activate hook (AX-20). pyvm_setup_auto_activate installs
# the UNIFIED hook (lib/auto-activate.sh), so removal delegates to
# auto_activate_remove. A LEGACY "# >>> pyvm auto-activate hook <<<" block
# written by older releases is removed first. The old remover rewrote
# ~/.zshrc through a /tmp file and mv (no backup, mode reset to 0600, a
# symlinked rc replaced by a plain file) and an unterminated block made its
# awk range delete every line to the end of the file. Returns 0 on success,
# 1 on failure.
pyvm_remove_auto_activate() {
    local rc=0
    _pyvm_remove_legacy_hook || rc=1
    # shellcheck source=lib/auto-activate.sh
    source "${_VMS_PYVM_DIR}/auto-activate.sh" || return 1
    auto_activate_remove || rc=1
    return "$rc"
}

# Legacy block removal: locked (workstation-config, like every rc writer),
# transactional (backup, atomic rename onto the resolved file, mode and
# symlink kept, rollback on any failure), refused unchanged when the markers
# are unterminated or duplicated, previewed under TRANSACTION_DRY_RUN=1.
_pyvm_remove_legacy_hook() (
    local shell_rc="${ZDOTDIR:-$HOME}/.zshrc"
    local start_marker="# >>> pyvm auto-activate hook <<<" end_marker="# <<< pyvm auto-activate hook <<<"
    local state staged="" active=0 locked=0 rc=0
    [[ -f "$shell_rc" ]] || return 0
    if ! declare -F mutation_file_publish >/dev/null 2>&1; then
        log_error "lib/mutation.sh is not loaded in this shell — source lib/pyvm.sh here"
        return 1
    fi
    state=$(awk -v b="$start_marker" -v e="$end_marker" '
        $0 == b { if (inside || n) bad = 1; inside = 1; n++; next }
        $0 == e { if (!inside) bad = 1; inside = 0; next }
        END { if (bad || inside) print "malformed"; else print (n ? "present" : "absent") }' "$shell_rc") || return 1
    case "$state" in
        absent)
            log_info "No legacy pyvm auto-activate block in $shell_rc"
            return 0
            ;;
        malformed)
            log_error "Legacy pyvm auto-activate markers in $shell_rc are unterminated or duplicated — refusing; file left unchanged. Remove the block by hand."
            return 1
            ;;
    esac
    if [[ "${TRANSACTION_DRY_RUN:-0}" == 1 ]]; then
        printf '[dry-run] would remove the legacy pyvm auto-activate block from %s\n' "$shell_rc" >&2
        return 0
    fi
    [[ -z "${_TRANSACTION_ACTIVE:-}" ]] || { log_error "Nested rc mutation refused"; return 1; }
    validate_safe_path "$shell_rc" || return 1
    trap 'rc=$?; trap - EXIT; if [[ "$active" == 1 ]]; then transaction_rollback || rc=1; fi; [[ -z "$staged" ]] || rm -f -- "$staged"; if [[ "$locked" == 1 ]]; then lock_release workstation-config || rc=1; fi; exit "$rc"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    lock_acquire workstation-config 30 || return 1
    locked=1
    staged=$(mktemp "${TMPDIR:-/tmp}/vms-pyvm-rc.XXXXXX") || return 1
    awk -v b="$start_marker" -v e="$end_marker" '
        $0 == b { skip = 1; next }
        skip && $0 == e { skip = 0; next }
        !skip { print }' "$shell_rc" > "$staged" || return 1
    if command -v zsh >/dev/null 2>&1 && ! zsh -n "$staged" 2>/dev/null; then
        log_error "Rewritten $shell_rc would not parse — refusing; file left unchanged"
        return 1
    fi
    transaction_start pyvm_remove_legacy_hook || return 1
    active=1
    mutation_file_publish "$shell_rc" "$staged" || return 1
    transaction_commit >/dev/null || return 1
    active=0
    log_success "Legacy pyvm auto-activate block removed from $shell_rc"
    return 0
)

# Export functions for external use
export -f pyvm_detect pyvm_install pyvm_list_versions pyvm_install_version
export -f pyvm_set_global pyvm_set_local pyvm_get_current pyvm_validate_version
export -f pyvm_get_prompt_version pyvm_is_python_project
export -f _pyvm_find_venv pyvm_auto_activate pyvm_setup_auto_activate pyvm_remove_auto_activate _pyvm_remove_legacy_hook
