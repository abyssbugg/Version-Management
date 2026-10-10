#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source; SC2034: exported vars

# ============================================================================
# Enhanced Version Management System v3.0.0
# ============================================================================
# A comprehensive, production-ready version management system that provides:
# - Multi-language support (Node.js, Python, Ruby, Go, Rust, Java, PHP)
# - Automatic version switching
# - Performance optimizations
# - CI/CD integration
# - Docker support
# - Health diagnostics
# ============================================================================

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_VERSION="3.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Directories
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/version-manager}"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/version-manager}"
LOG_DIR="${LOG_DIR:-$HOME/.local/share/version-manager/logs}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/version-manager}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/.local/backup/version-manager}"

# Files
CONFIG_FILE="$CONFIG_DIR/config.yaml"
STATE_FILE="$STATE_DIR/state.json"
LOG_FILE="$LOG_DIR/version-manager-$(date +%Y%m%d).log"

# Settings
ENABLE_COLORS="${ENABLE_COLORS:-true}"
ENABLE_LOGGING="${ENABLE_LOGGING:-true}"
ENABLE_METRICS="${ENABLE_METRICS:-false}"
DEBUG_MODE="${DEBUG_MODE:-false}"
SILENT_MODE="${SILENT_MODE:-false}"
AUTO_INSTALL="${AUTO_INSTALL:-false}"
LAZY_LOAD="${LAZY_LOAD:-true}"

# Performance settings
CACHE_TTL="${CACHE_TTL:-3600}"  # 1 hour
MAX_PARALLEL="${MAX_PARALLEL:-4}"
TIMEOUT="${TIMEOUT:-30}"

# Global flags (AX-11). parse_args runs inside a process substitution, so its
# assignments never reached this shell: every documented global flag was a
# silent no-op. Leading flags are applied HERE — before colors and logging
# are configured — when the script is executed (a sourcing script's own argv
# is ignored). --confirm (consent for privileged install steps, read by
# vms_confirm_privileged) is honored anywhere on the command line because the
# consent warning tells users to "re-run with --confirm"; parse_args strips it
# from the command words.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _vms_leading=1
    for _vms_flag in "$@"; do
        if [[ "$_vms_flag" == --confirm ]]; then
            export VMS_CONFIRM=1
            continue
        fi
        [[ "$_vms_leading" == 1 ]] || continue
        case "$_vms_flag" in
            --silent) SILENT_MODE=true ;;
            --debug) DEBUG_MODE=true ;;
            --no-color)
                ENABLE_COLORS=false
                export NO_COLOR=1
                ;;
            --auto-install) AUTO_INSTALL=true ;;
            *) _vms_leading=0 ;;
        esac
    done
    unset _vms_flag _vms_leading
fi

# ============================================================================
# Color Definitions
# ============================================================================

if [[ "$ENABLE_COLORS" == "true" ]] && [[ -t 1 ]]; then
    # Real ESC bytes ($'...'): show_usage prints these through a plain
    # here-document, where a '\033' literal is shown verbatim (AX-11). The
    # logger's `echo -e` renders either form identically.
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    MAGENTA=$'\033[0;35m'
    CYAN=$'\033[0;36m'
    WHITE=$'\033[0;37m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
    NC=$'\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''
    WHITE=''
    BOLD=''
    RESET=''
    NC=''
fi

# ============================================================================
# Logging — unified via lib/logger.sh
# ============================================================================
# lib/logger.sh supports: LOG_FILE (file logging), SILENT_MODE, and DEBUG.
# Bridge the script's own settings into the library's env vars, then source.
# ============================================================================

[[ "$ENABLE_LOGGING" == "true" ]] && export LOG_FILE || unset LOG_FILE 2>/dev/null
export SILENT_MODE
[[ "$DEBUG_MODE" == "true" ]] && export DEBUG=true || export DEBUG=false

# shellcheck source=lib/logger.sh
source "$SCRIPT_DIR/lib/logger.sh"
export VMS_STATE_DIR="${VMS_STATE_DIR:-$STATE_DIR}"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"
# Managed rc mutations share the canonical transaction/editor implementation.
# shellcheck source=lib/mutation.sh
source "$SCRIPT_DIR/lib/mutation.sh"

# Canonical platform API (P1-9): lib/env.sh is the single owner of
# get_os/get_shell/detect_os. This script's duplicated bodies (a private
# get_os that reported "linux" under WSL; a private get_shell that probed
# the running shell instead of the login shell) are deleted below — the
# sourced canonical implementations serve every call site.
# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"

# P2-4 (partial, M5 lane C2): canonical validators now guard public install
# entry points. Guarded source; if the lib is missing, validate_node_version
# is undefined and the install_node_version guard below fails CLOSED
# (rejection) rather than passing unvalidated input to an installer.
# shellcheck source=lib/validation.sh
if [[ -f "$SCRIPT_DIR/lib/validation.sh" ]]; then
    source "$SCRIPT_DIR/lib/validation.sh"
fi

# Read-only status mode detection (P3 review, direction b): resolved from
# argv BEFORE lib sourcing, mirroring parse_args' flag handling (the same
# global flags are skipped; the first non-flag word is the command). When set,
# lib/nvm.sh below is NOT sourced: it pulls in lib/cache.sh, which runs
# cache_init AT SOURCE TIME and creates cache directories — a write. The
# status surface is contractually zero-write and needs none of nvm.sh's
# install-path functions.
_VMS_STATUS_MODE=false
for _vms_arg in "$@"; do
    case "$_vms_arg" in
        --silent|--debug|--no-color|--auto-install|--confirm) continue ;;
        *) break ;;
    esac
done
if [[ "${_vms_arg:-}" == "status" || "${_vms_arg:-}" == "status-json" ]]; then
    _VMS_STATUS_MODE=true
fi
# create-versions preview (AX-6b): resolved the same way. A preview
# (`create-versions ... --dry-run`, or TRANSACTION_DRY_RUN=1) is zero-write,
# but sourcing lib/nvm.sh below runs cache_init (cache directory creation)
# at source time — the preview therefore takes the cache-disabled source
# path the configuration-only commands use.
_VMS_CREATE_PREVIEW=false
if [[ "${_vms_arg:-}" == "create-versions" ]]; then
    if [[ "${TRANSACTION_DRY_RUN:-0}" == 1 ]]; then
        _VMS_CREATE_PREVIEW=true
    fi
    for _vms_word in "$@"; do
        if [[ "$_vms_word" == --dry-run ]]; then
            _VMS_CREATE_PREVIEW=true
        fi
    done
    unset _vms_word
fi
unset _vms_arg

# NVM release pin (P2-6): lib/nvm.sh is the SINGLE source of truth for the
# pinned nvm release (NVM_VERSION, env-overridable). install_nvm below
# consumes ${NVM_VERSION} as its positional default — the previously
# duplicated pin literal that lived in install_nvm is gone. Same guarded,
# SCRIPT_DIR-safe posture as the canonical platform source above.
# Note: sourcing lib/nvm.sh pulls in lib/cache.sh, whose readonly CACHE_DIR
# adopts this script's own CACHE_DIR — accepted (same posture as the other
# lib/nvm.sh adopters; cache data is an optimization, never load-bearing).
if [[ "$_VMS_STATUS_MODE" == "true" ]]; then
    : # Read-only status needs neither NVM definitions nor cache initialization.
elif [[ -f "$SCRIPT_DIR/lib/nvm.sh" ]]; then
    if [[ "${BASH_SOURCE[0]}" == "$0" && ( "${1:-}" == configure || "${1:-}" == lazy-load || "$_VMS_CREATE_PREVIEW" == true ) ]]; then
        # Configuration-only commands and the create-versions preview need
        # definitions, not source-time cache writes.
        # The temporary assignment leaves the caller's cache preference unchanged.
        # shellcheck source=lib/nvm.sh
        CACHE_ENABLED=0 source "$SCRIPT_DIR/lib/nvm.sh"
    else
        # shellcheck source=lib/nvm.sh
        source "$SCRIPT_DIR/lib/nvm.sh"
    fi
fi

# log() and command_exists() are provided by lib/env.sh (ROADMAP 4.2 dedup);
# both are sourced above and guarded there so a caller override still wins.

# ============================================================================
# Utility Functions
# ============================================================================

# Create necessary directories
init_directories() {
    local dirs=("$CONFIG_DIR" "$CACHE_DIR" "$LOG_DIR" "$STATE_DIR" "$BACKUP_DIR")
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log_debug "Created directory: $dir"
        fi
    done
}

# command_exists() is provided by lib/env.sh (ROADMAP 4.2 dedup).

# get_os: canonical implementation lives in lib/env.sh (sourced above, P1-9).
# WSL is reported as "wsl" — the install_* case labels below carry explicit
# wsl branches so WSL keeps its pre-conversion behavior.

# Get architecture
get_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x64" ;;
        arm64|aarch64) echo "arm64" ;;
        armv7l)        echo "arm" ;;
        i386|i686)     echo "x86" ;;
        *)             echo "unknown" ;;
    esac
}

# get_shell: canonical implementation lives in lib/env.sh (sourced above,
# P1-9) — the login-shell name, basename of $SHELL with a /bin/bash default.

# Get shell config file
get_shell_config() {
    local shell_type="$(get_shell)"
    # fish intentionally falls through to the generic POSIX fallback: the
    # blocks this script appends are bash/zsh-flavored and must never be
    # appended to a fish config. (The pre-P1-9 fish branch was unreachable —
    # a bash executable always sees BASH_VERSION — but becomes reachable
    # under the canonical login-shell get_shell.)
    case "$shell_type" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash)
            if [[ -f "$HOME/.bashrc" ]]; then
                echo "$HOME/.bashrc"
            else
                echo "$HOME/.bash_profile"
            fi
            ;;
        *)    echo "$HOME/.profile" ;;
    esac
}

# P3-1/P3-2: stdin is trusted generated configuration, never user shell code.
# Subshell scope keeps transaction state and cleanup traps out of the caller.
_vm_configure_block() (
    local name="$1" signature="$2" file="$3" block="version-manager-$1"
    local content='' target="$file" active=0 locked=0
    # shellcheck disable=SC2030 # Deliberately isolate preview logging from the caller.
    local LOG_FILE=''  # Planning and diagnostics must never initialize file logging.
    export LOG_FILE
    if [[ -n "${_TRANSACTION_ACTIVE:-}" ]]; then
        log_error 'Configuration requires its own transaction; nested mutation refused'
        return 1
    fi
    if [[ -L "$file" ]]; then
        mutation_resolve_content_target "$file" || return 1
        target="$_MUTATION_RESOLVED_TARGET"
    fi
    if [[ -e "$target" && ! -f "$target" ]]; then
        log_error "Not a regular shell configuration: $file"
        return 1
    fi
    if [[ -f "$file" ]]; then
        # Fail closed for partial/duplicate markers; never discard unknown rc text.
        awk -v b="# BEGIN version-management-setup:$block" -v e="# END version-management-setup:$block" '
            $0 == b { if (inside || starts++) bad=1; inside=1; next }
            $0 == e { if (!inside) bad=1; inside=0; next }
            END { exit (bad || inside) ? 1 : 0 }
        ' "$file" || { log_error "Malformed managed block in $file; repair markers before retrying"; return 1; }
        if awk -v b="# BEGIN version-management-setup:$block" -v e="# END version-management-setup:$block" '
            $0 == b { inside=1; next } $0 == e { inside=0; next } !inside { print }
        ' "$file" | grep -Eq "$signature"; then
            log_error "Existing unmanaged $name configuration in $file; review/migrate it before retrying (left unchanged)"
            return 1
        fi
    fi
    if [[ "${TRANSACTION_DRY_RUN:-0}" == 1 ]]; then
        printf '[dry-run] Would write managed block %s to %s (backup, verify, rollback on failure)\n' "$block" "$file"
        return 0
    fi
    [[ -d "$(dirname "$target")" ]] || { log_error "Shell configuration parent missing: $file"; return 1; }
    _vm_config_cleanup() {
        local status=$?
        trap - EXIT
        if [[ "$active" == 1 ]]; then
            transaction_rollback || status=1
        fi
        [[ -z "$content" ]] || rm -f -- "$content"
        if [[ "$locked" == 1 ]]; then lock_release workstation-config || status=1; fi
        exit "$status"
    }
    trap _vm_config_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    lock_acquire workstation-config 30 || return 1
    locked=1
    content=$(mktemp "${TMPDIR:-/tmp}/tmp_rovodev_manager_config.XXXXXX") || return 1
    cat > "$content" || return 1
    bash -n "$content" || return 1
    transaction_start "version_manager_$name" || return 1
    active=1
    transaction_add_file "$file" || return 1
    if [[ "$target" != "$file" ]]; then transaction_add_file "$target" || return 1; fi
    mutation_block_write "$file" "$block" "$content" || return 1
    if [[ "${SHELL##*/}" == zsh ]]; then
        command -v zsh >/dev/null 2>&1 || { log_error 'zsh is required to verify zsh configuration'; return 1; }
        zsh -n "$file" || return 1
    else
        bash -n "$file" || return 1
    fi
    transaction_commit || return 1
    active=0
    log_success "Managed $name configuration verified: $file"
)

# Create backup of file
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup_name="$(basename "$file").$(date +%Y%m%d_%H%M%S).bak"
        cp "$file" "$BACKUP_DIR/$backup_name"
        log_info "Backed up $file to $BACKUP_DIR/$backup_name"
    fi
}

# Check internet connectivity
check_internet() {
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null || ping -c 1 -W 2 1.1.1.1 &>/dev/null; then
        return 0
    fi
    return 1
}

# Acquire lock
# shellcheck disable=SC2120  # optional args: callers may omit them (defaults apply)
acquire_lock() {
    local timeout="${1:-30}"
    lock_with_trap "version-manager" "$timeout"
}

# Release lock
release_lock() {
    lock_release "version-manager"
}

# ============================================================================
# Version Manager Detection Functions
# ============================================================================

# Detect installed version managers
detect_version_managers() {
    local managers=()

    # Node.js managers
    if [[ -d "$HOME/.nvm" ]] || command_exists nvm; then
        managers+=("nvm")
    fi
    if command_exists n; then
        managers+=("n")
    fi
    if command_exists fnm; then
        managers+=("fnm")
    fi
    if command_exists volta; then
        managers+=("volta")
    fi

    # Python managers
    if command_exists pyenv; then
        managers+=("pyenv")
    fi
    if command_exists conda; then
        managers+=("conda")
    fi
    if command_exists poetry; then
        managers+=("poetry")
    fi

    # Ruby managers
    if command_exists rbenv; then
        managers+=("rbenv")
    fi
    if command_exists rvm; then
        managers+=("rvm")
    fi
    if command_exists chruby; then
        managers+=("chruby")
    fi

    # Go manager
    if command_exists g; then
        managers+=("g")
    fi

    # Rust manager
    if command_exists rustup; then
        managers+=("rustup")
    fi

    # Java managers
    if command_exists jabba; then
        managers+=("jabba")
    fi
    if command_exists jenv; then
        managers+=("jenv")
    fi
    if command_exists sdk; then
        managers+=("sdkman")
    fi

    # PHP manager
    if command_exists phpenv; then
        managers+=("phpenv")
    fi

    # Universal manager
    if command_exists asdf; then
        managers+=("asdf")
    fi

    echo "${managers[@]}"
}

# ============================================================================
# NVM (Node Version Manager) Functions
# ============================================================================

install_nvm() {
    log_info "Installing NVM..."

    # P2-6: positional override wins; the default is the single pin from
    # lib/nvm.sh (sourced above). No literal here — if lib/nvm.sh is missing
    # (guarded source above) the unmanaged pin is refused loudly instead of
    # re-duplicated.
    local nvm_version="${1:-${NVM_VERSION:-}}"
    [[ -n "$nvm_version" ]] || { log_error "NVM_VERSION unset (lib/nvm.sh missing?) — refusing an unmanaged nvm pin"; return 1; }
    local install_dir="${NVM_DIR:-$HOME/.nvm}"
    export NVM_DIR="$install_dir"
    local repo_url="https://github.com/nvm-sh/nvm.git"

    if ! check_internet; then
        log_error "No internet connection available"
        return 1
    fi

    if ! command_exists git; then
        log_error "Git is required to install NVM securely"
        return 1
    fi

    # AX-6d: move any existing installation aside IMMEDIATELY before the
    # clone; every failure of the clone sequence restores it.
    local staged
    staged="$BACKUP_DIR/nvm_$(date +%Y%m%d_%H%M%S)"
    if [[ -d "$install_dir" ]]; then
        log_warn "NVM directory already exists. Creating backup..."
    fi
    install_dir_stage "$install_dir" "$staged" || return 1

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would git clone $repo_url ($nvm_version) -> $install_dir"
        configure_nvm
        return 0
    fi

    # Clone requested version
    if git clone --depth 1 --branch "$nvm_version" "$repo_url" "$install_dir" 2>/dev/null; then
        log_success "NVM cloned successfully"
    else
        log_warn "Shallow clone failed, attempting full clone..."
        if ! git clone "$repo_url" "$install_dir"; then
            log_error "Failed to clone NVM repository"
            install_dir_restore "$install_dir" "$staged" || true
            return 1
        fi
        if ! git -C "$install_dir" checkout "$nvm_version"; then
            log_error "Unable to checkout NVM version $nvm_version"
            install_dir_restore "$install_dir" "$staged" || true
            return 1
        fi
    fi

    configure_nvm
    return 0
}

configure_nvm() {
    _vm_configure_block nvm 'NVM_DIR|NVM Configuration \(added by version-manager\)' "$(get_shell_config)" << 'EOF'
export NVM_DIR="$HOME/.nvm"

# Lazy load NVM for faster shell startup
nvm() {
    unset -f nvm node npm npx
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"
    nvm "$@"
}

node() {
    unset -f nvm node npm npx
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    node "$@"
}

npm() {
    unset -f nvm node npm npx
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    npm "$@"
}

npx() {
    unset -f nvm node npm npx
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    npx "$@"
}

# Auto-use .nvmrc when changing directories
autoload -U add-zsh-hook 2>/dev/null || true

load_nvmrc() {
    local nvmrc_path="$(nvm_find_nvmrc 2>/dev/null)"

    if [ -n "$nvmrc_path" ]; then
        local nvmrc_node_version=$(nvm version "$(cat "${nvmrc_path}")" 2>/dev/null)

        if [ "$nvmrc_node_version" = "N/A" ]; then
            # Directory hooks never install implicitly. The unified auto-switch
            # hook offers capability-gated installation via explicit project trust.
            return 0
        elif [ "$nvmrc_node_version" != "$(nvm version 2>/dev/null)" ]; then
            nvm use --silent
        fi
    elif [ -n "$(PWD=$OLDPWD nvm_find_nvmrc 2>/dev/null)" ] && [ "$(nvm version 2>/dev/null)" != "$(nvm version default 2>/dev/null)" ]; then
        nvm use default --silent
    fi
}

# Setup hooks based on shell
if command -v add-zsh-hook &>/dev/null; then
    add-zsh-hook chpwd load_nvmrc
    load_nvmrc
elif [[ -n "$BASH_VERSION" ]]; then
    load_nvmrc
    if [[ -z "${PROMPT_COMMAND:-}" ]]; then
        PROMPT_COMMAND="load_nvmrc"
    elif [[ "$PROMPT_COMMAND" != *"load_nvmrc"* ]]; then
        PROMPT_COMMAND+="; load_nvmrc"
    fi
fi

# Silence NVM output
export NVM_SILENT=true
EOF

}

# ============================================================================
# FNM (Fast Node Manager) Functions
# ============================================================================

install_fnm() {
    log_info "Installing FNM..."

    if command_exists fnm; then
        log_info "FNM already installed"
        configure_fnm
        return 0
    fi

    if ! check_internet; then
        log_error "No internet connection available"
        return 1
    fi

    if command_exists brew; then
        log_info "Installing FNM via Homebrew"
        if brew install fnm; then
            log_success "FNM installed successfully via Homebrew"
            configure_fnm
            return 0
        fi
        log_error "Failed to install FNM via Homebrew"
        return 1
    fi

    log_error "Failed to install FNM via package manager. Refusing to execute remote install scripts (curl|bash)."
    log_info "Install manually via a trusted package manager, then re-run: $SCRIPT_NAME install-fnm"
    return 1
}

configure_fnm() {
    _vm_configure_block fnm 'fnm env' "$(get_shell_config)" << 'EOF'
if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --use-on-cd)"
fi
EOF
}

# ============================================================================
# Pyenv (Python Version Manager) Functions
# ============================================================================

install_pyenv() {
    log_info "Installing pyenv..."

    local os="$(get_os)"

    if ! check_internet; then
        log_error "No internet connection available"
        return 1
    fi

    if ! command_exists git; then
        log_error "Git is required to install pyenv"
        return 1
    fi

    local target_dir="${PYENV_ROOT:-$HOME/.pyenv}"
    local repo_url="https://github.com/pyenv/pyenv.git"
    local plugin_url="https://github.com/pyenv/pyenv-virtualenv.git"

    export PYENV_ROOT="$target_dir"

    # Install dependencies when available
    # "wsl" keeps the linux branch (P1-9): the pre-conversion get_os answered
    # "linux" under WSL, so build dependencies were installed there.
    # AX-6e: privileged (rule 1.2) — plan + explicit confirmation; declining
    # still installs pyenv itself (the clone is user-space).
    local deps_rc=0
    case "$os" in
        linux|wsl)
            if command_exists apt-get; then
                _vms_privileged_steps "pyenv build dependencies via apt (sudo)" \
                    "Skipped pyenv build dependencies; pyenv itself is still installed." -- \
                    sudo apt-get update -- \
                    sudo apt-get install -y make build-essential libssl-dev zlib1g-dev \
                    libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm \
                    libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
                    libffi-dev liblzma-dev || deps_rc=$?
            elif command_exists yum; then
                _vms_privileged_steps "pyenv build dependencies via yum (sudo)" \
                    "Skipped pyenv build dependencies; pyenv itself is still installed." -- \
                    sudo yum install -y gcc zlib-devel bzip2 bzip2-devel readline-devel \
                    sqlite sqlite-devel openssl-devel tk-devel libffi-devel xz-devel || deps_rc=$?
            fi
            ;;
    esac
    # A confirmed-but-failed dependency install aborts, as before (set -e);
    # a decline (3) continues with the user-space install.
    if [[ "$deps_rc" -ne 0 && "$deps_rc" -ne 3 ]]; then
        log_error "Failed to install pyenv build dependencies"
        return 1
    fi

    if command_exists brew; then
        # Homebrew does not use $target_dir: it is never moved aside for this
        # path (AX-6d brew-path displacement).
        if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
            log_info "[dry-run] would run: brew install pyenv pyenv-virtualenv"
            configure_pyenv
            return 0
        fi
        brew install pyenv pyenv-virtualenv
    else
        # AX-6d: stage IMMEDIATELY before the clone (single move — the former
        # unconditional move of $HOME/.pyenv duplicated this one and also
        # displaced ~/.pyenv when PYENV_ROOT pointed elsewhere); every failure
        # of the clone sequence restores it.
        local staged
        staged="$BACKUP_DIR/pyenv_$(date +%Y%m%d_%H%M%S)"
        if [[ -d "$target_dir" ]]; then
            log_warn "Pyenv directory already exists. Creating backup..."
        fi
        install_dir_stage "$target_dir" "$staged" || return 1

        if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
            log_info "[dry-run] would git clone $repo_url -> $target_dir (+ pyenv-virtualenv)"
            configure_pyenv
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
    fi

    log_success "Pyenv installed successfully"
    configure_pyenv
    return 0
}

configure_pyenv() {
    _vm_configure_block pyenv 'PYENV_ROOT|pyenv init' "$(get_shell_config)" << 'EOF'
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"

# Lazy load pyenv for faster shell startup
pyenv() {
    unset -f pyenv
    eval "$(command pyenv init -)"
    eval "$(command pyenv virtualenv-init -)" 2>/dev/null || true
    pyenv "$@"
}
EOF
}

# ============================================================================
# rbenv (Ruby Version Manager) Functions
# ============================================================================

install_rbenv() {
    log_info "Installing rbenv..."

    local os="$(get_os)"

    if ! check_internet; then
        log_error "No internet connection available"
        return 1
    fi

    local target_dir="$HOME/.rbenv"

    # "wsl" keeps the linux branch (P1-9): WSL previously matched via the old
    # get_os "linux" value — preserve that behavior.
    case "$os" in
        macos|linux|wsl) ;;
        *)
            log_error "Unsupported OS for rbenv installation: $os"
            return 1
            ;;
    esac

    if [[ "$os" == "macos" ]] && command_exists brew; then
        # Homebrew does not use ~/.rbenv: never moved aside (AX-6d).
        if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
            log_info "[dry-run] would run: brew install rbenv ruby-build"
            configure_rbenv
            return 0
        fi
        if ! brew install rbenv ruby-build; then
            log_error "Failed to install rbenv"
            return 1
        fi
    else
        # AX-6d: stage IMMEDIATELY before the clones; any failure of either
        # clone restores the previous tree (the old code also reported
        # success when only the second clone succeeded).
        local staged
        staged="$BACKUP_DIR/rbenv_$(date +%Y%m%d_%H%M%S)"
        if [[ -d "$target_dir" ]]; then
            log_warn "rbenv directory already exists. Creating backup..."
        fi
        install_dir_stage "$target_dir" "$staged" || return 1

        if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
            log_info "[dry-run] would git clone https://github.com/rbenv/rbenv.git -> $target_dir (+ ruby-build)"
            configure_rbenv
            return 0
        fi

        if ! git clone https://github.com/rbenv/rbenv.git "$target_dir" \
            || ! git clone https://github.com/rbenv/ruby-build.git "$target_dir/plugins/ruby-build"; then
            log_error "Failed to install rbenv"
            install_dir_restore "$target_dir" "$staged" || true
            return 1
        fi
    fi

    log_success "rbenv installed successfully"
    configure_rbenv
    return 0
}

configure_rbenv() {
    _vm_configure_block rbenv 'rbenv init' "$(get_shell_config)" << 'EOF'
export PATH="$HOME/.rbenv/bin:$PATH"

# Lazy load rbenv for faster shell startup
rbenv() {
    unset -f rbenv
    eval "$(command rbenv init -)"
    rbenv "$@"
}

ruby() {
    unset -f rbenv ruby gem bundle
    eval "$(command rbenv init -)"
    ruby "$@"
}

gem() {
    unset -f rbenv ruby gem bundle
    eval "$(command rbenv init -)"
    gem "$@"
}

bundle() {
    unset -f rbenv ruby gem bundle
    eval "$(command rbenv init -)"
    bundle "$@"
}
EOF

}

# ============================================================================
# phpenv (PHP Version Manager) Functions
# ============================================================================

install_phpenv() {
    log_info "Installing phpenv..."

    local os="$(get_os)"

    if ! check_internet; then
        log_error "No internet connection available"
        return 1
    fi

    local target_dir="$HOME/.phpenv"

    # "wsl" keeps the linux branch (P1-9): WSL previously matched via the old
    # get_os "linux" value — preserve that behavior.
    case "$os" in
        macos|linux|wsl) ;;
        *)
            log_error "Unsupported OS for phpenv installation: $os"
            return 1
            ;;
    esac

    if [[ "$os" == "macos" ]] && command_exists brew; then
        # Homebrew does not use ~/.phpenv: never moved aside (AX-6d).
        if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
            log_info "[dry-run] would run: brew install phpenv php-build"
            configure_phpenv
            return 0
        fi
        if ! brew install phpenv php-build; then
            log_error "Failed to install phpenv"
            return 1
        fi
    else
        # AX-6d: stage IMMEDIATELY before the clones; any failure of either
        # clone restores the previous tree.
        local staged
        staged="$BACKUP_DIR/phpenv_$(date +%Y%m%d_%H%M%S)"
        if [[ -d "$target_dir" ]]; then
            log_warn "phpenv directory already exists. Creating backup..."
        fi
        install_dir_stage "$target_dir" "$staged" || return 1

        if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
            log_info "[dry-run] would git clone https://github.com/phpenv/phpenv.git -> $target_dir (+ php-build)"
            configure_phpenv
            return 0
        fi

        if ! git clone https://github.com/phpenv/phpenv.git "$target_dir" \
            || ! git clone https://github.com/php-build/php-build.git "$target_dir/plugins/php-build"; then
            log_error "Failed to install phpenv"
            install_dir_restore "$target_dir" "$staged" || true
            return 1
        fi
    fi

    log_success "phpenv installed successfully"
    configure_phpenv
    return 0
}

configure_phpenv() {
    _vm_configure_block phpenv 'PHPENV_ROOT|phpenv init' "$(get_shell_config)" << 'EOF'
export PHPENV_ROOT="$HOME/.phpenv"
export PATH="$PHPENV_ROOT/bin:$PATH"

# Lazy load phpenv for faster shell startup
phpenv() {
    unset -f phpenv php composer
    eval "$(command phpenv init -)"
    phpenv "$@"
}

php() {
    unset -f phpenv php composer
    eval "$(command phpenv init -)"
    php "$@"
}

composer() {
    unset -f phpenv php composer
    eval "$(command phpenv init -)"
    composer "$@"
}
EOF

}

# ============================================================================
# Version Installation Functions
# ============================================================================

install_node_version() {
    local version="${1:-lts}"

    # P2-4 (partial, M5 lane C2): user-supplied version is validated BEFORE
    # any side effect (no NVM bootstrap, no network, no sourcing). Semver
    # shapes go through the canonical lib/validation.sh validator; nvm's
    # tag aliases (lts, lts/<codename>, node, stable) are explicitly
    # allowed. Everything else is rejected here.
    if ! validate_node_version "$version" 2>/dev/null \
        && ! [[ "$version" == "lts" || "$version" == lts/* || "$version" == "node" || "$version" == "stable" ]]; then
        log_error "install_node_version: refusing invalid version '$version' (expected semver like 20.19.2 or v20, or an nvm alias like lts/lts/iron)"
        return 1
    fi

    log_info "Installing Node.js version: $version"

    # Ensure NVM is installed
    if [[ ! -d "$HOME/.nvm" ]]; then
        log_warn "NVM not installed. Installing NVM first..."
        install_nvm || return 1
    fi

    # Source NVM
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

    # Install Node version
    if nvm install "$version"; then
        nvm use "$version"
        nvm alias default "$version"

        # Install global packages
        npm install -g npm@latest
        npm install -g yarn pnpm typescript ts-node nodemon pm2

        log_success "Node.js $version installed successfully"
        return 0
    else
        log_error "Failed to install Node.js $version"
        return 1
    fi
}

install_python_version() {
    local version="${1:-3.12.0}"

    # P2-4: validate user-supplied version BEFORE any side effect (no pyenv
    # bootstrap, no network, no install). Canonical semver shapes pass the
    # validator; pyenv's non-semver names (3.13-dev, pypy3.10-7.3.12) pass the
    # conservative injection grammar. Everything else is rejected here.
    if ! validate_python_version "$version" 2>/dev/null \
        && [[ ! "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
        log_error "install_python_version: refusing invalid version '$version' (expected e.g. 3.12.0 or a pyenv name like pypy3.10-7.3.12)"
        return 1
    fi

    log_info "Installing Python version: $version"

    # Ensure pyenv is installed
    if ! command_exists pyenv; then
        log_warn "Pyenv not installed. Installing pyenv first..."
        install_pyenv || return 1
    fi

    # Install Python version
    if pyenv install "$version"; then
        pyenv global "$version"

        # Upgrade pip and install essential packages
        pip install --upgrade pip setuptools wheel
        pip install virtualenv pipenv poetry black flake8 mypy pytest

        log_success "Python $version installed successfully"
        return 0
    else
        log_error "Failed to install Python $version"
        return 1
    fi
}

install_ruby_version() {
    local version="${1:-3.0.0}"

    # P2-4: validate user-supplied version BEFORE any side effect.
    if ! validate_ruby_version "$version" 2>/dev/null; then
        log_error "install_ruby_version: refusing invalid version '$version' (expected e.g. 3.3.0 or an rbenv name like jruby-9.4.5.0)"
        return 1
    fi

    log_info "Installing Ruby version: $version"

    # Ensure rbenv is installed
    if ! command_exists rbenv; then
        log_warn "rbenv not installed. Installing rbenv first..."
        install_rbenv || return 1
    fi

    # Install Ruby version
    if rbenv install "$version"; then
        rbenv global "$version"

        # Install essential gems
        gem install bundler rails pry rubocop

        log_success "Ruby $version installed successfully"
        return 0
    else
        log_error "Failed to install Ruby $version"
        return 1
    fi
}

install_php_version() {
    local version="${1:-8.3}"

    # P2-4: validate user-supplied version BEFORE any side effect.
    if ! validate_php_version "$version" 2>/dev/null; then
        log_error "install_php_version: refusing invalid version '$version' (expected e.g. 8.3.0 or a phpenv name like 8.4.0-dev)"
        return 1
    fi

    log_info "Installing PHP version: $version"

    # Ensure phpenv is installed
    if ! command_exists phpenv; then
        log_warn "phpenv not installed. Installing phpenv first..."
        install_phpenv || return 1
    fi

    # Install PHP version
    if phpenv install "$version"; then
        phpenv global "$version"
        phpenv rehash

        # Install Composer if not present (secure installer path only)
        if ! command_exists composer; then
            log_info "Installing Composer..."
            if command_exists brew; then
                brew install composer
            elif [[ -f "$SCRIPT_DIR/lib/phpenv.sh" ]]; then
                # shellcheck source=lib/phpenv.sh
                source "$SCRIPT_DIR/lib/phpenv.sh"
                if ! command_exists composer_install || ! composer_install; then
                    log_error "Failed to install Composer securely"
                    return 1
                fi
            else
                log_error "Cannot install Composer securely: missing lib/phpenv.sh"
                return 1
            fi
        fi

        # Install Laravel installer
        if command_exists composer; then
            composer global require laravel/installer
        fi

        log_success "PHP $version installed successfully"
        return 0
    else
        log_error "Failed to install PHP $version"
        return 1
    fi
}

# ============================================================================
# Project Management Functions
# ============================================================================

# AX-6b (P3-1, P2-4): the project pin files (.nvmrc, .python-version,
# .ruby-version, .tool-versions and — when jq is available — package.json
# engines) are written through ONE transaction:
#   - every target is registered BEFORE the first write;
#   - planned content is staged in $TMPDIR (never in the project dir);
#   - a byte-identical target is not rewritten (no mtime churn);
#   - a changed target is published atomically: temp file in the target's
#     own directory + rename; an existing file keeps its mode, a new file
#     gets the umask-derived mode a plain `>` would have given it;
#   - package.json is published only after jq exited 0 with non-empty,
#     valid JSON that carries the requested engines.node value;
#   - any failure rolls the WHOLE transaction back (every pin restored
#     byte-identically) and returns non-zero; success messages are emitted
#     only after the commit.
# TRANSACTION_DRY_RUN=1 prints one plan line per target (create / replace /
# unchanged) and performs zero writes in the project directory and HOME.
# Subshell scope keeps transaction state and the cleanup trap out of the
# caller (same posture as _vm_configure_block). No here-documents (AX-7).
create_version_files() (
    if [[ "${TRANSACTION_DRY_RUN:-0}" == 1 ]]; then
        # Preview never initializes file logging (zero-write contract);
        # subshell scope keeps the caller's LOG_FILE intact.
        # shellcheck disable=SC2030 # Deliberately isolate preview logging from the caller.
        LOG_FILE=''
    fi

    log_info "Creating version files for current project..."

    local node_version="${1:-$(nvm version default 2>/dev/null || echo '20.0.0')}"
    local python_version="${2:-$(pyenv version-name 2>/dev/null || echo '3.12.0')}"
    local ruby_version="${3:-$(rbenv version-name 2>/dev/null || echo '3.0.0')}"

    # P2-4: each value is written verbatim as one line. Refuse empty values,
    # whitespace/control characters (they would split or corrupt the line
    # formats) and a leading '-' (an option typo, never a version) — before
    # anything is staged or written.
    _vm_cv_valid() {
        if [[ -n "$2" && "$2" != *[[:space:][:cntrl:]]* && "$2" != -* ]]; then
            return 0
        fi
        log_error "create_version_files: refusing invalid $1 version $(printf '%q' "$2") (empty, whitespace, control characters or a leading '-')"
        return 1
    }
    _vm_cv_valid Node.js "$node_version" || return 1
    _vm_cv_valid Python "$python_version" || return 1
    _vm_cv_valid Ruby "$ruby_version" || return 1

    local dry_run=0
    if [[ "${TRANSACTION_DRY_RUN:-0}" == 1 ]]; then
        dry_run=1
    fi

    local project_dir="$PWD" staging='' pub_tmp='' active=0
    _vm_cv_cleanup() {
        local status=$?
        trap - EXIT
        if [[ "$active" == 1 ]]; then
            # Leaving with an open transaction is a failure by definition:
            # restore every registered target to its pre-state.
            if transaction_rollback; then
                log_error "create_version_files FAILED — transaction rolled back; every target restored to its previous state"
            else
                log_error "create_version_files FAILED — rollback reported errors; inspect the transaction under \$HOME/.config-backups/transactions"
            fi
            [[ "$status" -ne 0 ]] || status=1
        fi
        if [[ -n "$pub_tmp" ]]; then
            rm -f -- "$pub_tmp"
        fi
        if [[ -n "$staging" && -d "$staging" ]]; then
            rm -rf -- "$staging"
        fi
        exit "$status"
    }
    trap _vm_cv_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    staging=$(mktemp -d "${TMPDIR:-/tmp}/vms-create-versions.XXXXXX") || {
        log_error "create_version_files: cannot create a staging directory in ${TMPDIR:-/tmp}"
        return 1
    }

    # Planned content — same bytes the previous echo / cat writes produced.
    if ! { printf '%s\n' "${node_version#v}" > "$staging/.nvmrc" \
        && printf '%s\n' "$python_version" > "$staging/.python-version" \
        && printf '%s\n' "$ruby_version" > "$staging/.ruby-version" \
        && printf 'nodejs %s\npython %s\nruby %s\n' "${node_version#v}" "$python_version" "$ruby_version" > "$staging/.tool-versions"; }; then
        log_error "create_version_files: cannot stage planned content in $staging"
        return 1
    fi

    # package.json participates only when it exists and jq is available
    # (jq absent keeps the historical silent skip).
    local -a names=(.nvmrc .python-version .ruby-version .tool-versions)
    local use_pkg=0
    if [[ -f package.json ]] && command_exists jq; then
        use_pkg=1
        names+=(package.json)
    fi

    # Resolve every target before anything is registered or written. A
    # symlinked pin keeps being a symlink: the rename lands on the resolved
    # content file (mutation.sh semantics). Non-regular or read-only targets
    # are refused here — a plain `>` failed on them too.
    local -a links=() targets=()
    local name path target
    for name in "${names[@]}"; do
        path="$project_dir/$name"
        target="$path"
        if [[ -L "$path" ]]; then
            mutation_resolve_content_target "$path" || return 1
            target="$_MUTATION_RESOLVED_TARGET"
        fi
        if [[ -e "$target" && ! -f "$target" ]]; then
            log_error "create_version_files: not a regular file, refusing: $name"
            return 1
        fi
        if [[ -e "$target" && ! -w "$target" ]]; then
            log_error "create_version_files: not writable, refusing: $name"
            return 1
        fi
        links+=("$path")
        targets+=("$target")
    done

    _vm_cv_action() {
        if [[ ! -e "$2" ]]; then
            printf 'create'
        elif mutation_files_identical "$1" "$2"; then
            printf 'unchanged'
        else
            printf 'replace'
        fi
    }

    # jq into the staging dir; publishable only if jq exited 0, the output
    # is non-empty, parses as JSON and carries the requested engines value.
    _vm_cv_stage_package_json() {
        # Major only, without nvm's "v" prefix (`nvm version default` prints
        # v20.1.0; ">=v20" is not a valid semver range for engines.node).
        local node_major="${node_version#v}"
        node_major="${node_major%%.*}"
        local expected=">=${node_major}" staged="$staging/package.json" readback=''
        if ! jq --arg engines "$expected" '.engines.node = $engines' "$project_dir/package.json" > "$staged"; then
            log_error "create_version_files: jq failed to update package.json engines"
            return 1
        fi
        if [[ ! -s "$staged" ]]; then
            log_error "create_version_files: jq produced empty output for package.json — refusing to publish it"
            return 1
        fi
        if ! jq -e . "$staged" >/dev/null 2>&1; then
            log_error "create_version_files: jq output for package.json is not valid JSON — refusing to publish it"
            return 1
        fi
        readback=$(jq -r '.engines.node' "$staged" 2>/dev/null) || readback=''
        if [[ "$readback" != "$expected" ]]; then
            log_error "create_version_files: jq output for package.json does not carry engines.node \"$expected\" — refusing to publish it"
            return 1
        fi
        return 0
    }

    # Same-directory temp + rename. pub_tmp is tracked so an interrupted
    # publish never leaves a temp file behind (cleanup trap).
    _vm_cv_publish() {
        local staged="$1" target="$2" dir mode
        if [[ -e "$target" ]] && mutation_files_identical "$staged" "$target"; then
            log_debug "create_version_files: unchanged, not rewritten: $target"
            return 0
        fi
        dir=$(dirname "$target")
        pub_tmp=$(mktemp "$dir/.vms-create-versions.XXXXXX") || {
            pub_tmp=''
            log_error "create_version_files: cannot create a temp file in $dir"
            return 1
        }
        if ! cp "$staged" "$pub_tmp"; then
            log_error "create_version_files: cannot write temp file for $target"
            return 1
        fi
        if [[ -e "$target" ]]; then
            if ! _mutation_preserve_mode "$target" "$pub_tmp"; then
                log_error "create_version_files: cannot preserve mode of $target"
                return 1
            fi
        else
            printf -v mode '%o' $(( 0666 & ~8#$(umask) ))
            if ! chmod "$mode" "$pub_tmp"; then
                log_error "create_version_files: cannot set mode $mode on new $target"
                return 1
            fi
        fi
        if ! mv "$pub_tmp" "$target"; then
            log_error "create_version_files: atomic rename failed: $target"
            return 1
        fi
        pub_tmp=''
        return 0
    }

    local i
    if [[ "$dry_run" == 1 ]]; then
        for ((i = 0; i < 4; i++)); do
            printf '[dry-run] %s: %s\n' "$(_vm_cv_action "$staging/${names[$i]}" "${targets[$i]}")" "${names[$i]}"
        done
        if [[ "$use_pkg" == 1 ]]; then
            _vm_cv_stage_package_json || return 1
            printf '[dry-run] %s: %s\n' "$(_vm_cv_action "$staging/package.json" "${targets[4]}")" package.json
        elif [[ -f package.json ]]; then
            printf '[dry-run] skip: package.json (jq not available; engines not updated)\n'
        fi
        log_info "Dry-run complete — zero writes in $project_dir and HOME"
        return 0
    fi

    transaction_start create_version_files || return 1
    active=1
    for ((i = 0; i < ${#names[@]}; i++)); do
        transaction_add_file "${links[$i]}" || return 1
        if [[ "${targets[$i]}" != "${links[$i]}" ]]; then
            transaction_add_file "${targets[$i]}" || return 1
        fi
    done

    for ((i = 0; i < 4; i++)); do
        _vm_cv_publish "$staging/${names[$i]}" "${targets[$i]}" || return 1
    done
    if [[ "$use_pkg" == 1 ]]; then
        _vm_cv_stage_package_json || return 1
        _vm_cv_publish "$staging/package.json" "${targets[4]}" || return 1
    fi

    transaction_commit || return 1
    active=0

    log_success "Created .nvmrc with Node.js $node_version"
    log_success "Created .python-version with Python $python_version"
    log_success "Created .ruby-version with Ruby $ruby_version"
    log_success "Created .tool-versions for asdf compatibility"
    if [[ "$use_pkg" == 1 ]]; then
        log_success "Updated package.json engines"
    fi
    return 0
)

# ============================================================================
# Health Check Functions
# ============================================================================

health_check() {
    log_info "Running health check..."
    echo
    echo "================================"
    echo "Version Manager Health Check"
    echo "================================"
    echo

    # System information
    echo "System Information:"
    echo "  OS: $(get_os)"
    echo "  Arch: $(get_arch)"
    echo "  Shell: $(get_shell)"
    echo

    # Check version managers
    echo "Version Managers:"
    local managers
    mapfile -t managers < <(detect_version_managers)
    if [[ ${#managers[@]} -eq 0 ]]; then
        echo "   No version managers installed"
    else
        for manager in "${managers[@]}"; do
            echo "   $manager"
        done
    fi
    echo

    # Check installed versions
    echo "Installed Versions:"

    # Node.js
    if command_exists node; then
        echo "  Node.js: $(node --version)"
    else
        echo "  Node.js: Not installed"
    fi

    # Python
    if command_exists python3; then
        echo "  Python: $(python3 --version 2>&1 | cut -d' ' -f2)"
    else
        echo "  Python: Not installed"
    fi

    # Ruby
    if command_exists ruby; then
        echo "  Ruby: $(ruby --version | cut -d' ' -f2)"
    else
        echo "  Ruby: Not installed"
    fi

    # PHP
    if command_exists php; then
        echo "  PHP: $(php -r 'echo PHP_VERSION;' 2>/dev/null)"
    else
        echo "  PHP: Not installed"
    fi

    echo

    # Check version files
    echo "Version Files:"
    local version_files=(".nvmrc" ".python-version" ".ruby-version" ".php-version" ".tool-versions")
    for file in "${version_files[@]}"; do
        if [[ -f "$file" ]]; then
            echo "   $file: $(head -n1 "$file")"
        else
            echo "   $file: Not found"
        fi
    done
    echo

    # Performance metrics
    echo "Performance Metrics:"
    echo "  Shell startup time: $(time_shell_startup)ms"
    echo "  Cache size: $(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)"
    echo

    log_success "Health check completed"
}

time_shell_startup() {
    local shell="$(get_shell)"
    local start=$(date +%s%N)

    case "$shell" in
        zsh)  zsh -i -c exit ;;
        bash) bash -i -c exit ;;
        *)    $SHELL -i -c exit ;;
    esac

    local end=$(date +%s%N)
    echo $(((end - start) / 1000000))
}

configure_auto_switch() {
    local auto_activate_lib="$SCRIPT_DIR/lib/auto-activate.sh"

    if [[ ! -f "$auto_activate_lib" ]]; then
        log_error "Auto-switch module not found: $auto_activate_lib"
        return 1
    fi

    # shellcheck source=lib/auto-activate.sh
    source "$auto_activate_lib"

    if auto_activate_setup; then
        log_success "Auto-switch configured via dev auto-activate hook"
        return 0
    fi

    log_error "Failed to configure auto-switch"
    return 1
}

configure_lazy_load() {
    local shell_config
    local preferred_shell="${SHELL##*/}"
    if [[ "$preferred_shell" == "zsh" ]]; then
        shell_config="${ZDOTDIR:-$HOME}/.zshrc"
    else
        shell_config="$(get_shell_config)"
    fi
    local perf_lib="$SCRIPT_DIR/lib/performance.sh"

    if [[ ! -f "$perf_lib" ]]; then
        log_error "Performance module not found: $perf_lib"
        return 1
    fi

    local quoted_perf
    printf -v quoted_perf '%q' "$perf_lib"
    _vm_configure_block lazy-load 'version-manager lazy-load|setup_nvm_lazy|setup_pyenv_lazy' "$shell_config" << EOF
# Load performance helper wrappers for nvm/pyenv on first use.
if [[ -f $quoted_perf ]]; then
  source $quoted_perf
  declare -f setup_nvm_lazy >/dev/null 2>&1 && setup_nvm_lazy
  declare -f setup_pyenv_lazy >/dev/null 2>&1 && setup_pyenv_lazy
fi
EOF
}

# ============================================================================
# Read-Only Project Status API (P3 review, direction b)
# ============================================================================
# vm_status_json / vm_status report the expected-vs-active runtime version
# state of the CURRENT directory for the prompt/display layer.
#
# Contract:
#   - ZERO writes, ZERO installs: the status CLI commands bypass
#     init_directories (which would create XDG directories) and the mutation
#     lock; nothing is logged (the lib loggers write files and are
#     deliberately not called here); no version is ever installed or
#     switched from this surface. The display layer reads — it never
#     manages versions.
#   - Fail-open: a missing pin file, an absent runtime, or a failing
#     --version probe degrades exactly one field; the command still exits 0.
#   - Data sources: expected = first field of the pin file (.nvmrc,
#     .python-version, .go-version, .rust-toolchain, .php-version); active =
#     the installed runtime's own --version probe.
#   - JSON assembly uses python3 when available (repo precedent, proper
#     escaping); otherwise a printf fallback emits valid JSON with the
#     documented limitation that quote/backslash/control characters degrade
#     to null.
#
# NOTE on validator reuse: the canonical lib/validation.sh validators log
# through lib/logger.sh, which writes a log file — invoking them would
# violate the zero-write contract above. The private screens below are
# display-only length/grammar caps, not security validators.
# ============================================================================

_VM_STATUS_NAMES=()
_VM_STATUS_EXPECTED=()
_VM_STATUS_ACTIVE=()
_VM_STATUS_MATCH=()

# private: first whitespace-delimited field of a pin file, length-capped.
# Prints nothing when the file is absent, empty, or oversized (fail-open).
_vm_status_read_pin() {
    local file="$1"
    local pin=""
    if [[ -f "$file" ]]; then
        read -r pin _rest < "$file" 2>/dev/null || true
        pin="${pin:-}"
        if (( ${#pin} > 64 )); then
            pin=""
        fi
    fi
    printf '%s' "$pin"
    return 0
}

# private: normalize a version token for equality — strip one leading 'v'
# (node) or 'go' (go toolchain) prefix. Comparison after normalization is a
# literal string equality; channel pins (lts/iron, stable) therefore never
# "match" a concrete installed version.
_vm_status_normalize() {
    local v="${1:-}"
    v="${v#v}"
    v="${v#go}"
    printf '%s' "$v"
    return 0
}

# private: probe the active version of one runtime. Fail-open: prints
# nothing and returns 1 when the runtime is absent or errors out.
_vm_status_active_version() {
    local runtime="$1"
    local raw=""
    local _tc=""
    case "$runtime" in
        node)
            command -v node >/dev/null 2>&1 || return 1
            raw="$(node --version 2>/dev/null || true)"
            raw="${raw%%[[:space:]]*}"
            ;;
        python)
            command -v python3 >/dev/null 2>&1 || return 1
            raw="$(python3 --version 2>&1 | head -n 1 || true)"
            # Extract "Python 3.12.0" -> "3.12.0" with literal parameter
            # expansion only (no glob, subshell, pipe, or here-string), so it
            # evaluates identically on every bash build. (The Linux-only
            # python.match regression that surfaced here was ultimately an
            # export -f serialization bug in transaction_commit poisoning
            # child bash via BASH_FUNC_*, fixed in lib/backup.sh; this parse
            # is kept as defensive hardening regardless.)
            raw="${raw#Python }"
            raw="${raw%% *}"
            ;;
        go)
            command -v go >/dev/null 2>&1 || return 1
            raw="$(go version 2>/dev/null | head -n 1 || true)"
            raw="${raw#go version }"         # -> "go1.22.0 darwin/arm64"
            raw="${raw%%[[:space:]]*}"       # -> "go1.22.0"
            ;;
        rust)
            # rustup-managed rustc resolves the project's rust-toolchain pin
            # from the CURRENT directory and AUTO-INSTALLS a missing
            # toolchain (slow, networked — and the status API is
            # contractually install-free). Resolve the DEFAULT toolchain
            # explicitly instead; `rustup run` on a missing toolchain fails
            # fast and locally, with no directory-override resolution.
            raw=""
            if command -v rustup >/dev/null 2>&1; then
                _tc="$(rustup default 2>/dev/null || true)"
                _tc="${_tc%%[[:space:]]*}"
                if [[ -n "$_tc" ]]; then
                    raw="$(rustup run "$_tc" rustc --version 2>/dev/null | head -n 1 || true)"
                fi
            elif command -v rustc >/dev/null 2>&1; then
                raw="$(rustc --version 2>/dev/null | head -n 1 || true)"
            else
                return 1
            fi
            raw="${raw#*[[:space:]]}"        # drop "rustc "
            raw="${raw%%[[:space:]]*}"
            ;;
        php)
            command -v php >/dev/null 2>&1 || return 1
            raw="$(php --version 2>/dev/null | head -n 1 || true)"
            raw="${raw#*[[:space:]]}"        # drop "PHP "
            raw="${raw%%[[:space:]]*}"
            ;;
        *)
            return 1
            ;;
    esac
    [[ -n "$raw" ]] || return 1
    printf '%s' "$raw"
    return 0
}

# private: collect the status snapshot into the _VM_STATUS_* arrays.
# A runtime appears iff a pin file OR an active runtime is detectable;
# match is strictly boolean (true iff both sides present and equal after
# normalization).
_vm_status_collect() {
    _VM_STATUS_NAMES=()
    _VM_STATUS_EXPECTED=()
    _VM_STATUS_ACTIVE=()
    _VM_STATUS_MATCH=()

    local runtime pin_file expected active match
    local -A pin_map=(
        [node]=".nvmrc"
        [python]=".python-version"
        [go]=".go-version"
        [rust]=".rust-toolchain"
        [php]=".php-version"
    )

    for runtime in node python go rust php; do
        pin_file="${pin_map[$runtime]}"
        expected="$(_vm_status_read_pin "$pin_file")"
        active="$(_vm_status_active_version "$runtime" 2>/dev/null || true)"

        if [[ -z "$expected" && -z "$active" ]]; then
            continue
        fi

        match=false
        if [[ -n "$expected" && -n "$active" ]]; then
            if [[ "$(_vm_status_normalize "$expected")" == "$(_vm_status_normalize "$active")" ]]; then
                match=true
            fi
        fi

        _VM_STATUS_NAMES+=("$runtime")
        _VM_STATUS_EXPECTED+=("$expected")
        _VM_STATUS_ACTIVE+=("$active")
        _VM_STATUS_MATCH+=("$match")
    done
    return 0
}

# private: render a value as a JSON string literal for the printf fallback
# (double quotes included). Control characters, quotes, and backslashes
# degrade to null (documented fallback limitation; the python3 path escapes
# properly instead).
_vm_status_json_escape() {
    local s="${1:-}"
    local badpat='[[:cntrl:]"\\]'
    if [[ -z "$s" || "$s" =~ $badpat ]]; then
        printf 'null'
        return 0
    fi
    printf '"%s"' "$s"
    return 0
}

# private: printf fallback JSON assembler (no python3 dependency).
_vm_status_json_fallback() {
    local project="$1"
    local pjson
    pjson="$(_vm_status_json_escape "$project")"

    local out="{\"project\":${pjson},\"runtime\":{"
    local i name exp act m seg first=1
    for ((i = 0; i < ${#_VM_STATUS_NAMES[@]}; i++)); do
        name="$(_vm_status_json_escape "${_VM_STATUS_NAMES[i]}")"
        exp="$(_vm_status_json_escape "${_VM_STATUS_EXPECTED[i]}")"
        act="$(_vm_status_json_escape "${_VM_STATUS_ACTIVE[i]}")"
        m=false
        if [[ "${_VM_STATUS_MATCH[i]}" == "true" ]]; then
            m=true
        fi
        seg="${name}:{\"expected\":${exp},\"active\":${act},\"match\":${m}}"
        if (( first )); then
            out+="$seg"
            first=0
        else
            out+=",$seg"
        fi
    done
    out+='}}'
    printf '%s\n' "$out"
    return 0
}

# Public: emit one JSON object describing the project's runtime status:
#   {"project": "<cwd>",
#    "runtime": {"node": {"expected": str|null, "active": str|null,
#                         "match": bool}, ...}}
# expected/active are null when the pin file / runtime is absent.
vm_status_json() {
    local project
    project="$(pwd -P 2>/dev/null)" || project=""

    _vm_status_collect

    local -a argv=("$project")
    local i
    for ((i = 0; i < ${#_VM_STATUS_NAMES[@]}; i++)); do
        argv+=("${_VM_STATUS_NAMES[i]}")
        argv+=("${_VM_STATUS_EXPECTED[i]}")
        argv+=("${_VM_STATUS_ACTIVE[i]}")
        if [[ "${_VM_STATUS_MATCH[i]}" == "true" ]]; then
            argv+=("1")
        else
            argv+=("0")
        fi
    done

    # Preferred assembly path: python3 (repo precedent — proper escaping).
    if command_exists python3; then
        if python3 - "${argv[@]}" 2>/dev/null <<'PYEOF'
import json
import sys

argv = sys.argv[1:]
project = argv[0] if argv else ""
runtime = {}
for i in range(1, len(argv), 4):
    name = argv[i]
    expected = argv[i + 1] if i + 1 < len(argv) and argv[i + 1] != "" else None
    active = argv[i + 2] if i + 2 < len(argv) and argv[i + 2] != "" else None
    flag = argv[i + 3] == "1" if i + 3 < len(argv) else False
    runtime[name] = {
        "expected": expected,
        "active": active,
        "match": bool(expected) and bool(active) and flag,
    }
print(json.dumps({"project": project, "runtime": runtime}))
PYEOF
        then
            return 0
        fi
    fi

    # Documented fallback: printf assembly. Still valid JSON; values holding
    # quote/backslash/control characters degrade to null.
    _vm_status_json_fallback "$project"
    return 0
}

# Public: human-readable variant of vm_status_json (same data, no JSON).
vm_status() {
    local project
    project="$(pwd -P 2>/dev/null)" || project=""

    _vm_status_collect

    printf 'project: %s\n' "$project"

    if (( ${#_VM_STATUS_NAMES[@]} == 0 )); then
        printf 'runtime: (no pin files or active runtimes detected)\n'
        return 0
    fi

    local i name exp act state
    for ((i = 0; i < ${#_VM_STATUS_NAMES[@]}; i++)); do
        name="${_VM_STATUS_NAMES[i]}"
        exp="${_VM_STATUS_EXPECTED[i]}"
        act="${_VM_STATUS_ACTIVE[i]}"
        state="MISMATCH"
        if [[ "${_VM_STATUS_MATCH[i]}" == "true" ]]; then
            state="match"
        fi
        if [[ -z "$exp" ]]; then
            exp="(no pin)"
        fi
        if [[ -z "$act" ]]; then
            act="(not installed)"
        fi
        printf '  %-6s expected: %-18s active: %-18s %s\n' "$name" "$exp" "$act" "$state"
    done
    return 0
}

# ============================================================================
# Main Command Handler
# ============================================================================

show_usage() {
    cat << EOF
${BOLD}Enhanced Version Manager v${SCRIPT_VERSION}${RESET}

${BOLD}Usage:${RESET}
  $SCRIPT_NAME <command> [options]

${BOLD}Commands:${RESET}
  ${GREEN}install-all${RESET}              Install all version managers
  ${GREEN}install-nvm${RESET}              Install NVM (Node Version Manager)
  ${GREEN}install-fnm${RESET}              Install FNM (Fast Node Manager)
  ${GREEN}install-pyenv${RESET}            Install pyenv (Python Version Manager)
  ${GREEN}install-rbenv${RESET}            Install rbenv (Ruby Version Manager)
  ${GREEN}install-phpenv${RESET}           Install phpenv (PHP Version Manager)

  ${GREEN}install-node${RESET} [version]   Install Node.js version (default: lts)
  ${GREEN}install-python${RESET} [version] Install Python version (default: 3.12.0)
  ${GREEN}install-ruby${RESET} [version]   Install Ruby version (default: 3.0.0)
  ${GREEN}install-php${RESET} [version]    Install PHP version (default: 8.3)

  ${GREEN}configure${RESET} <manager>       Configure existing manager rc block (no installation)
                              nvm|fnm|pyenv|rbenv|phpenv|lazy-load; accepts --dry-run
  ${GREEN}create-versions${RESET} [node] [python] [ruby] [--dry-run]
                              Create .nvmrc/.python-version/.ruby-version/.tool-versions
                              (+ package.json engines when jq is available) in the
                              current project; defaults: active nvm/pyenv/rbenv version,
                              else 20.0.0/3.12.0/3.0.0. Atomic, rolled back on failure;
                              --dry-run prints the plan and writes nothing
  ${GREEN}status${RESET}                   Show expected-vs-active runtime versions (read-only)
  ${GREEN}status-json${RESET}              Same status as one JSON object (read-only, machine)
  ${GREEN}auto-switch${RESET}              Install unified auto-activation hook
  ${GREEN}lazy-load${RESET}                Add lazy-load bootstrap block to shell config
  ${GREEN}health-check${RESET}             Run comprehensive health check
  ${GREEN}update-all${RESET}               Update all version managers
  ${GREEN}clean-cache${RESET}              Clean cache files

  ${GREEN}help${RESET}                     Show this help message

${BOLD}Options:${RESET}
  --silent                  Run in silent mode
  --debug                   Enable debug output
  --no-color                Disable colored output
  --auto-install            Reserved (accepted; currently has no effect)
  --confirm                 Consent to privileged (sudo) install steps
                            non-interactively (same as VMS_CONFIRM=1)

${BOLD}Examples:${RESET}
  # Install all version managers
  $SCRIPT_NAME install-all

  # Install specific Node.js version
  $SCRIPT_NAME install-node 20.0.0

  # Create version files for project
  $SCRIPT_NAME create-versions

  # Preview pinning explicit versions (zero writes)
  $SCRIPT_NAME create-versions 20.11.1 3.12.0 3.3.0 --dry-run

  # Show project runtime status (human / JSON, read-only)
  $SCRIPT_NAME status
  $SCRIPT_NAME status-json

  # Enable project auto-switch hook
  $SCRIPT_NAME auto-switch

  # Configure lazy-load wrappers
  $SCRIPT_NAME lazy-load

  # Run health check
  $SCRIPT_NAME health-check

${BOLD}Configuration:${RESET}
  Config Dir: $CONFIG_DIR
  Cache Dir:  $CACHE_DIR
  Log Dir:    $LOG_DIR

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --silent)
                SILENT_MODE=true
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                shift
                ;;
            --no-color)
                ENABLE_COLORS=false
                shift
                ;;
            --auto-install)
                AUTO_INSTALL=true
                shift
                ;;
            --confirm)
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    # Emit remaining positional args ONE PER LINE so the caller's
    # `mapfile -t args` preserves argument boundaries. A plain `echo "$@"`
    # space-joins them onto a single line, collapsing e.g.
    # `install-node 20.0.0` into args[0] and leaving args[1] unset — which
    # breaks every command that takes a version argument. (P2/CLI fix)
    # A --confirm after the command was already applied (AX-11) and is not a
    # command word.
    local word
    for word in "$@"; do
        [[ "$word" == --confirm ]] && continue
        printf '%s\n' "$word"
    done
}

# Main function
main() {
    # Configuration-only entrypoint: no installer, eager directories or outer lock.
    # Preserve legacy commands while making preview semantics explicit and scoped.
    if [[ "${1:-}" == configure || "${1:-}" == lazy-load ]]; then
        local manager option
        if [[ "$1" == lazy-load ]]; then manager=lazy-load; shift
        else manager="${2:-}"; shift; [[ $# -eq 0 ]] || shift; fi
        case "$manager" in nvm|fnm|pyenv|rbenv|phpenv|lazy-load) ;;
            *) printf 'Expected configure {nvm|fnm|pyenv|rbenv|phpenv|lazy-load} [--dry-run]\n' >&2; return 2 ;;
        esac
        local TRANSACTION_DRY_RUN="${TRANSACTION_DRY_RUN:-0}"
        for option in "$@"; do
            case "$option" in --dry-run) TRANSACTION_DRY_RUN=1 ;;
                *) printf 'Unsupported configuration option: %s\n' "$option" >&2; return 2 ;;
            esac
        done
        export TRANSACTION_DRY_RUN
        if [[ "$manager" == lazy-load ]]; then configure_lazy_load
        else "configure_$manager"; fi
        return $?
    fi
    # Parse arguments
    local args
    mapfile -t args < <(parse_args "$@")
    local command="${args[0]:-help}"

    # Read-only status surface (P3 review, direction b): bypass
    # init_directories (which creates XDG directories — a write) and the
    # mutation lock. vm_status_json / vm_status perform ZERO writes.
    case "$command" in
        status-json)
            vm_status_json
            return 0
            ;;
        status)
            vm_status
            return 0
            ;;
    esac

    # create-versions (AX-6b, P3-1): --dry-run may appear anywhere after the
    # command and is stripped BEFORE positional handling; the remaining words
    # are the optional [node] [python] [ruby] versions. A preview (--dry-run,
    # or TRANSACTION_DRY_RUN=1 from the environment) is zero-write in the
    # project dir and HOME: it returns here, before init_directories (XDG
    # directory creation) and acquire_lock (lock-root mkdir); file logging is
    # disabled inside create_version_files.
    local -a create_args=()
    if [[ "$command" == create-versions ]]; then
        local TRANSACTION_DRY_RUN="${TRANSACTION_DRY_RUN:-0}"
        local create_arg
        for create_arg in "${args[@]:1}"; do
            case "$create_arg" in
                --dry-run) TRANSACTION_DRY_RUN=1 ;;
                -*) printf 'Unsupported create-versions option: %s\n' "$create_arg" >&2; return 2 ;;
                *) create_args+=("$create_arg") ;;
            esac
        done
        export TRANSACTION_DRY_RUN
        if [[ "$TRANSACTION_DRY_RUN" == 1 ]]; then
            create_version_files "${create_args[0]:-}" "${create_args[1]:-}" "${create_args[2]:-}"
            return $?
        fi
    fi

    # Initialize
    init_directories

    # Acquire lock for write operations
    case "$command" in
        install-*|create-*|update-*|clean-*|auto-switch|lazy-load)
            acquire_lock || exit 1
            ;;
    esac

    # Execute command
    case "$command" in
        install-all)
            install_nvm
            install_fnm
            install_pyenv
            install_rbenv
            install_phpenv
            ;;
        install-nvm)
            install_nvm "${args[1]:-}"
            ;;
        install-fnm)
            install_fnm
            ;;
        install-pyenv)
            install_pyenv
            ;;
        install-rbenv)
            install_rbenv
            ;;
        install-phpenv)
            install_phpenv
            ;;
        install-node)
            install_node_version "${args[1]:-}"
            ;;
        install-python)
            install_python_version "${args[1]:-}"
            ;;
        install-ruby)
            install_ruby_version "${args[1]:-}"
            ;;
        install-php)
            install_php_version "${args[1]:-}"
            ;;
        create-versions)
            create_version_files "${create_args[0]:-}" "${create_args[1]:-}" "${create_args[2]:-}"
            ;;
        auto-switch)
            configure_auto_switch
            ;;
        lazy-load)
            configure_lazy_load
            ;;
        health-check)
            health_check
            ;;
        update-all)
            log_info "Updating all version managers..."
            # Update logic here
            ;;
        clean-cache)
            log_info "Cleaning cache..."
            rm -rf "${CACHE_DIR:?}"/*
            log_success "Cache cleaned"
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac

    # Release lock
    release_lock
}

# ============================================================================
# Script Entry Point
# ============================================================================

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
