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

# ============================================================================
# Color Definitions
# ============================================================================

if [[ "$ENABLE_COLORS" == "true" ]] && [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    WHITE='\033[0;37m'
    BOLD='\033[1m'
    RESET='\033[0m'
    NC='\033[0m'
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

# Canonical platform API (P1-9): lib/env.sh is the single owner of
# get_os/get_shell/detect_os. This script's duplicated bodies (a private
# get_os that reported "linux" under WSL; a private get_shell that probed
# the running shell instead of the login shell) are deleted below — the
# sourced canonical implementations serve every call site.
# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"

# Compatibility shim: allow callers that use log "LEVEL" "msg" directly
log() {
    local level="$1"; shift
    case "$level" in
        ERROR)   log_error "$*" ;;
        WARN)    log_warn  "$*" ;;
        INFO)    log_info  "$*" ;;
        SUCCESS) log_success "$*" ;;
        DEBUG)   log_debug "$*" ;;
        *)       log_info  "[$level] $*" ;;
    esac
}

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

# Check if command exists
command_exists() {
    command -v "$1" &>/dev/null
}

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

    local nvm_version="${1:-v0.39.7}"
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

    # Backup existing installation
    if [[ -d "$install_dir" ]]; then
        log_warn "NVM directory already exists. Creating backup..."
        mv "$install_dir" "$BACKUP_DIR/nvm_$(date +%Y%m%d_%H%M%S)"
    fi

    # Clone requested version
    if git clone --depth 1 --branch "$nvm_version" "$repo_url" "$install_dir" 2>/dev/null; then
        log_success "NVM cloned successfully"
    else
        log_warn "Shallow clone failed, attempting full clone..."
        if ! git clone "$repo_url" "$install_dir"; then
            log_error "Failed to clone NVM repository"
            return 1
        fi
        if ! git -C "$install_dir" checkout "$nvm_version"; then
            log_error "Unable to checkout NVM version $nvm_version"
            return 1
        fi
    fi

    configure_nvm
    return 0
}

configure_nvm() {
    log_info "Configuring NVM..."

    local shell_config="$(get_shell_config)"
    backup_file "$shell_config"

    # Check if already configured
    if grep -q "NVM_DIR" "$shell_config" 2>/dev/null; then
        log_info "NVM already configured in $shell_config"
        return 0
    fi

    # Add NVM configuration
    cat >> "$shell_config" << 'EOF'

# ============================================================================
# NVM Configuration (added by version-manager)
# ============================================================================
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
            nvm install
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

    log_success "NVM configuration added to $shell_config"
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
    log_info "Configuring FNM..."

    local shell_config="$(get_shell_config)"
    backup_file "$shell_config"

    # Check if already configured
    if grep -q "fnm env" "$shell_config" 2>/dev/null; then
        log_info "FNM already configured in $shell_config"
        return 0
    fi

    # Add FNM configuration
    cat >> "$shell_config" << 'EOF'

# ============================================================================
# FNM Configuration (added by version-manager)
# ============================================================================
if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --use-on-cd)"
fi
EOF

    log_success "FNM configuration added to $shell_config"
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

    # Backup existing installation
    if [[ -d "$HOME/.pyenv" ]]; then
        log_warn "Pyenv directory already exists. Creating backup..."
        mv "$HOME/.pyenv" "$BACKUP_DIR/pyenv_$(date +%Y%m%d_%H%M%S)"
    fi

    if ! command_exists git; then
        log_error "Git is required to install pyenv"
        return 1
    fi

    local target_dir="${PYENV_ROOT:-$HOME/.pyenv}"
    local repo_url="https://github.com/pyenv/pyenv.git"
    local plugin_url="https://github.com/pyenv/pyenv-virtualenv.git"

    export PYENV_ROOT="$target_dir"

    if [[ -d "$target_dir" ]]; then
        log_warn "Pyenv directory already exists. Creating backup..."
        mv "$target_dir" "$BACKUP_DIR/pyenv_$(date +%Y%m%d_%H%M%S)"
    fi

    # Install dependencies when available
    # "wsl" keeps the linux branch (P1-9): the pre-conversion get_os answered
    # "linux" under WSL, so build dependencies were installed there.
    case "$os" in
        linux|wsl)
            if command_exists apt-get; then
                sudo apt-get update
                sudo apt-get install -y make build-essential libssl-dev zlib1g-dev \
                    libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm \
                    libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
                    libffi-dev liblzma-dev
            elif command_exists yum; then
                sudo yum install -y gcc zlib-devel bzip2 bzip2-devel readline-devel \
                    sqlite sqlite-devel openssl-devel tk-devel libffi-devel xz-devel
            fi
            ;;
    esac

    if command_exists brew; then
        brew install pyenv pyenv-virtualenv
    else
        if ! git clone --depth 1 "$repo_url" "$target_dir"; then
            log_error "Failed to clone pyenv repository"
            return 1
        fi
        mkdir -p "$target_dir/plugins"
        if ! git clone --depth 1 "$plugin_url" "$target_dir/plugins/pyenv-virtualenv"; then
            log_error "Failed to clone pyenv-virtualenv plugin"
            return 1
        fi
    fi

    log_success "Pyenv installed successfully"
    configure_pyenv
    return 0
}

configure_pyenv() {
    log_info "Configuring pyenv..."

    local shell_config="$(get_shell_config)"
    backup_file "$shell_config"

    # Check if already configured
    if grep -q "PYENV_ROOT" "$shell_config" 2>/dev/null; then
        log_info "Pyenv already configured in $shell_config"
        return 0
    fi

    # Add pyenv configuration (auto-switch handled by unified hook in lib/auto-activate.sh)
    cat >> "$shell_config" << 'EOF'

# ============================================================================
# Pyenv Configuration (added by version-manager)
# ============================================================================
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

    log_success "Pyenv configuration added to $shell_config"
    log_info "Python auto-switch (.python-version) is handled by the unified dev auto-activate hook"
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

    # Backup existing installation
    if [[ -d "$HOME/.rbenv" ]]; then
        log_warn "rbenv directory already exists. Creating backup..."
        mv "$HOME/.rbenv" "$BACKUP_DIR/rbenv_$(date +%Y%m%d_%H%M%S)"
    fi

    # "wsl" keeps the linux branch (P1-9): WSL previously matched via the old
    # get_os "linux" value — preserve that behavior.
    case "$os" in
        macos)
            if command_exists brew; then
                brew install rbenv ruby-build
            else
                git clone https://github.com/rbenv/rbenv.git ~/.rbenv
                git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
            fi
            ;;
        linux|wsl)
            git clone https://github.com/rbenv/rbenv.git ~/.rbenv
            git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
            ;;
        *)
            log_error "Unsupported OS for rbenv installation: $os"
            return 1
            ;;
    esac

    if [[ $? -eq 0 ]]; then
        log_success "rbenv installed successfully"
        configure_rbenv
        return 0
    else
        log_error "Failed to install rbenv"
        return 1
    fi
}

configure_rbenv() {
    log_info "Configuring rbenv..."

    local shell_config="$(get_shell_config)"
    backup_file "$shell_config"

    # Check if already configured
    if grep -q "rbenv init" "$shell_config" 2>/dev/null; then
        log_info "rbenv already configured in $shell_config"
        return 0
    fi

    # Add rbenv configuration
    cat >> "$shell_config" << 'EOF'

# ============================================================================
# rbenv Configuration (added by version-manager)
# ============================================================================
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

    log_success "rbenv configuration added to $shell_config"
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

    # Backup existing installation
    if [[ -d "$HOME/.phpenv" ]]; then
        log_warn "phpenv directory already exists. Creating backup..."
        mv "$HOME/.phpenv" "$BACKUP_DIR/phpenv_$(date +%Y%m%d_%H%M%S)"
    fi

    # "wsl" keeps the linux branch (P1-9): WSL previously matched via the old
    # get_os "linux" value — preserve that behavior.
    case "$os" in
        macos)
            if command_exists brew; then
                brew install phpenv php-build
            else
                git clone https://github.com/phpenv/phpenv.git ~/.phpenv
                git clone https://github.com/php-build/php-build.git ~/.phpenv/plugins/php-build
            fi
            ;;
        linux|wsl)
            git clone https://github.com/phpenv/phpenv.git ~/.phpenv
            git clone https://github.com/php-build/php-build.git ~/.phpenv/plugins/php-build
            ;;
        *)
            log_error "Unsupported OS for phpenv installation: $os"
            return 1
            ;;
    esac

    if [[ $? -eq 0 ]]; then
        log_success "phpenv installed successfully"
        configure_phpenv
        return 0
    else
        log_error "Failed to install phpenv"
        return 1
    fi
}

configure_phpenv() {
    log_info "Configuring phpenv..."

    local shell_config="$(get_shell_config)"
    backup_file "$shell_config"

    # Check if already configured
    if grep -q "PHPENV_ROOT" "$shell_config" 2>/dev/null; then
        log_info "phpenv already configured in $shell_config"
        return 0
    fi

    # Add phpenv configuration
    cat >> "$shell_config" << 'EOF'

# ============================================================================
# phpenv Configuration (added by version-manager)
# ============================================================================
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

    log_success "phpenv configuration added to $shell_config"
}

# ============================================================================
# Version Installation Functions
# ============================================================================

install_node_version() {
    local version="${1:-lts}"

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

create_version_files() {
    log_info "Creating version files for current project..."

    local node_version="${1:-$(nvm version default 2>/dev/null || echo '20.0.0')}"
    local python_version="${2:-$(pyenv version-name 2>/dev/null || echo '3.12.0')}"
    local ruby_version="${3:-$(rbenv version-name 2>/dev/null || echo '3.0.0')}"

    # Create .nvmrc
    echo "${node_version#v}" > .nvmrc
    log_success "Created .nvmrc with Node.js $node_version"

    # Create .python-version
    echo "$python_version" > .python-version
    log_success "Created .python-version with Python $python_version"

    # Create .ruby-version
    echo "$ruby_version" > .ruby-version
    log_success "Created .ruby-version with Ruby $ruby_version"

    # Create .tool-versions (for asdf)
    cat > .tool-versions << EOF
nodejs ${node_version#v}
python $python_version
ruby $ruby_version
EOF
    log_success "Created .tool-versions for asdf compatibility"

    # Update package.json if exists
    if [[ -f "package.json" ]]; then
        local node_major="${node_version%%.*}"
        if command_exists jq; then
            jq ".engines.node = \">=${node_major}\"" package.json > package.json.tmp
            mv package.json.tmp package.json
            log_success "Updated package.json engines"
        fi
    fi
}

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

    backup_file "$shell_config"

    if grep -q "# >>> version-manager lazy-load <<<" "$shell_config" 2>/dev/null; then
        log_info "Lazy-load wrappers already configured in $shell_config"
        return 0
    fi

    cat >> "$shell_config" << EOF

# >>> version-manager lazy-load <<<
# Load performance helper wrappers for nvm/pyenv on first use.
if [[ -f "$perf_lib" ]]; then
  source "$perf_lib"
  declare -f setup_nvm_lazy >/dev/null 2>&1 && setup_nvm_lazy
  declare -f setup_pyenv_lazy >/dev/null 2>&1 && setup_pyenv_lazy
fi
# <<< version-manager lazy-load <<<
EOF

    log_success "Lazy-load bootstrap block added to $shell_config"
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

  ${GREEN}create-versions${RESET}          Create version files for current project
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
  --auto-install            Auto-install missing dependencies

${BOLD}Examples:${RESET}
  # Install all version managers
  $SCRIPT_NAME install-all

  # Install specific Node.js version
  $SCRIPT_NAME install-node 20.0.0

  # Create version files for project
  $SCRIPT_NAME create-versions

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
            *)
                break
                ;;
        esac
    done

    echo "$@"
}

# Main function
main() {
    # Initialize
    init_directories

    # Parse arguments
    local args
    mapfile -t args < <(parse_args "$@")
    local command="${args[0]:-help}"

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
            install_nvm "${args[1]}"
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
            install_node_version "${args[1]}"
            ;;
        install-python)
            install_python_version "${args[1]}"
            ;;
        install-ruby)
            install_ruby_version "${args[1]}"
            ;;
        install-php)
            install_php_version "${args[1]}"
            ;;
        create-versions)
            create_version_files "${args[1]}" "${args[2]}" "${args[3]}"
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
