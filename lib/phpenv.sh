#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source paths; SC2034: intentionally exported vars

# PHP Version Management Library Module
# Part of Professional Development Terminal Setup
# Provides standardized PHP version management interface using phpenv
# Integrates with foundational libraries for caching, logging, and environment setup
# Includes Composer and Laravel support

# Source foundational libraries
_VMS_PHPENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_VMS_PHPENV_DIR}/env.sh"
source "${_VMS_PHPENV_DIR}/cache.sh"
source "${_VMS_PHPENV_DIR}/logger.sh"
# Unconditional (B1.13-new): install_dir_stage/install_dir_restore are
# export -f'd, so inherited copies would defeat a declare -f guard.
# backup.sh is re-source-safe (preserves live transaction state).
source "${_VMS_PHPENV_DIR}/backup.sh"

# PHP version management configuration
PHPENV_CACHE_PREFIX="phpenv"
PHPENV_CACHE_TTL=300  # 5 minutes cache for version lists

# ============================================================================
# PHPENV DETECTION AND INSTALLATION
# ============================================================================

# Detect if phpenv is installed and available
# Returns: 0 if phpenv is available, 1 if not
phpenv_detect() {
    log_debug "Detecting phpenv installation"

    if command -v phpenv >/dev/null 2>&1; then
        local phpenv_version
        phpenv_version=$(phpenv --version 2>/dev/null | head -n1 | cut -d' ' -f2)
        log_info "phpenv detected: version $phpenv_version"
        return 0
    else
        log_warn "phpenv not found in PATH"
        return 1
    fi
}

# Install phpenv if missing
# Returns: 0 on success, 1 on failure
phpenv_install() {
    log_info "Installing phpenv..."

    if phpenv_detect; then
        log_info "phpenv already installed"
        return 0
    fi

    local os_type
    os_type=$(detect_os)

    if ! command -v git >/dev/null 2>&1; then
        log_error "Git is required to install phpenv"
        return 1
    fi

    local target_dir="${PHPENV_ROOT:-$HOME/.phpenv}"
    local repo_url="https://github.com/phpenv/phpenv.git"
    local build_url="https://github.com/php-build/php-build.git"

    export PHPENV_ROOT="$target_dir"

    case "$os_type" in
        "macos")
            # Install build dependencies via Homebrew
            if command -v brew >/dev/null 2>&1; then
                if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
                    log_info "[dry-run] would run: brew install autoconf automake bison freetype gd gettext icu4c krb5 libedit libiconv libjpeg libpng libxml2 libzip oniguruma openssl@3 pkg-config re2c zlib"
                else
                    log_info "Installing PHP build dependencies via Homebrew"
                    brew install autoconf automake bison freetype gd gettext icu4c krb5 \
                        libedit libiconv libjpeg libpng libxml2 libzip oniguruma openssl@3 \
                        pkg-config re2c zlib 2>/dev/null || true
                fi
            fi
            ;;
        "linux")
            # Build dependencies are privileged (rule 1.2): plan + explicit
            # confirmation. Declining still clones phpenv (user-space).
            if command -v apt-get >/dev/null 2>&1; then
                log_info "Installing PHP build dependencies via apt"
                _vms_privileged_steps "PHP build dependencies via apt (sudo)" \
                    "Skipped PHP build dependencies; phpenv itself is still installed." -- \
                    sudo apt-get update -- \
                    sudo apt-get install -y autoconf bison build-essential curl gettext \
                    libgd-dev libcurl4-openssl-dev libedit-dev libicu-dev libjpeg-dev \
                    libmysqlclient-dev libonig-dev libpng-dev libpq-dev libreadline-dev \
                    libsqlite3-dev libssl-dev libxml2-dev libzip-dev pkg-config re2c \
                    zlib1g-dev || true
            elif command -v yum >/dev/null 2>&1; then
                log_info "Installing PHP build dependencies via yum"
                _vms_privileged_steps "PHP build dependencies via yum (sudo)" \
                    "Skipped PHP build dependencies; phpenv itself is still installed." -- \
                    sudo yum install -y autoconf bison gcc gcc-c++ make curl-devel \
                    gd-devel libicu-devel libjpeg-devel libpng-devel libxml2-devel \
                    libzip-devel oniguruma-devel openssl-devel readline-devel \
                    sqlite-devel zlib-devel || true
            fi
            ;;
    esac

    # AX-6d: stage IMMEDIATELY before the clone; any failure of the clone
    # sequence restores the previous tree.
    local staged
    staged="$target_dir.bak.$(date +%Y%m%d_%H%M%S)"
    if [[ -d "$target_dir" ]]; then
        log_warn "Existing phpenv installation detected. Creating backup..."
    fi
    install_dir_stage "$target_dir" "$staged" || return 1

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would git clone $repo_url -> $target_dir (+ php-build); nothing installed"
        return 0
    fi

    # Clone phpenv
    if ! git clone --depth 1 "$repo_url" "$target_dir"; then
        log_error "Failed to clone phpenv repository"
        install_dir_restore "$target_dir" "$staged" || true
        return 1
    fi

    # Install php-build plugin
    if ! mkdir -p "$target_dir/plugins" \
        || ! git clone --depth 1 "$build_url" "$target_dir/plugins/php-build"; then
        log_error "Failed to clone php-build plugin"
        install_dir_restore "$target_dir" "$staged" || true
        return 1
    fi

    export PATH="$target_dir/bin:$PATH"
    log_success "phpenv installed successfully"
    return 0
}

# ============================================================================
# VERSION MANAGEMENT
# ============================================================================

# List available PHP versions (cached)
# Returns: 0 on success, 1 on failure
phpenv_list_versions() {
    log_debug "Listing available PHP versions"

    if ! phpenv_detect; then
        log_error "phpenv not available"
        return 1
    fi

    local cache_key="${PHPENV_CACHE_PREFIX}_versions"
    local cached_versions

    if cached_versions=$(cache_get "$cache_key"); then
        log_debug "Using cached PHP versions list"
        echo "$cached_versions"
        return 0
    fi

    log_debug "Fetching PHP versions from phpenv"
    local versions
    if versions=$(phpenv install --list 2>/dev/null); then
        cache_set "$cache_key" "$versions" "$PHPENV_CACHE_TTL"
        echo "$versions"
        return 0
    else
        log_error "Failed to list PHP versions"
        return 1
    fi
}

# Install specific PHP version
# Args: version - PHP version to install (e.g., "8.3.12")
# Returns: 0 on success, 1 on failure
phpenv_install_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "PHP version not specified"
        return 1
    fi

    if ! _phpenv_validate_version "$version"; then
        return 1
    fi

    if ! phpenv_detect; then
        log_error "phpenv not available"
        return 1
    fi

    log_info "Installing PHP $version..."

    # Check if already installed
    if phpenv versions --bare 2>/dev/null | grep -q "^${version}$"; then
        log_info "PHP $version already installed"
        return 0
    fi

    # Install the version
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would run: phpenv install $version; nothing installed"
        return 0
    fi

    if phpenv install "$version" 2>/dev/null; then
        log_success "PHP $version installed successfully"
        # Invalidate cache
        cache_delete "${PHPENV_CACHE_PREFIX}_versions"
        return 0
    else
        log_error "Failed to install PHP $version"
        return 1
    fi
}

# Set global PHP version
# Args: version - PHP version to set as global
# Returns: 0 on success, 1 on failure
phpenv_set_global() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "PHP version not specified"
        return 1
    fi

    if ! _phpenv_validate_version "$version"; then
        return 1
    fi

    if ! phpenv_detect; then
        log_error "phpenv not available"
        return 1
    fi

    # Check if version is installed
    if ! phpenv_validate_version "$version"; then
        log_warn "PHP $version not found, attempting to install..."
        if ! phpenv_install_version "$version"; then
            return 1
        fi
    fi

    log_info "Setting global PHP version to $version"
    if phpenv global "$version" 2>/dev/null; then
        phpenv rehash 2>/dev/null || true
        log_success "Global PHP version set to $version"
        return 0
    else
        log_error "Failed to set global PHP version"
        return 1
    fi
}

# Set local PHP version for current directory
# Args: version - PHP version to set as local
# Returns: 0 on success, 1 on failure
phpenv_set_local() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "PHP version not specified"
        return 1
    fi

    if ! _phpenv_validate_version "$version"; then
        return 1
    fi

    if ! phpenv_detect; then
        log_error "phpenv not available"
        return 1
    fi

    # Check if version is installed
    if ! phpenv_validate_version "$version"; then
        log_warn "PHP $version not found, attempting to install..."
        if ! phpenv_install_version "$version"; then
            return 1
        fi
    fi

    log_info "Setting local PHP version to $version"

    # Create .php-version file
    if echo "$version" > .php-version; then
        # Set phpenv local version
        if phpenv local "$version" 2>/dev/null; then
            phpenv rehash 2>/dev/null || true
            log_success "Local PHP version set to $version"
            return 0
        else
            log_error "Failed to set local PHP version with phpenv"
            return 1
        fi
    else
        log_error "Failed to create .php-version file"
        return 1
    fi
}

# Get current PHP version
# Returns: current PHP version string
phpenv_get_current() {
    log_debug "Getting current PHP version"

    if ! phpenv_detect; then
        echo "system"
        return 1
    fi

    local current_version
    if current_version=$(phpenv version-name 2>/dev/null); then
        echo "$current_version"
        return 0
    else
        echo "system"
        return 1
    fi
}

# Validate that a PHP version exists in installed versions
# Args: version - PHP version to validate
# Returns: 0 if version exists, 1 if not
phpenv_validate_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "PHP version not specified"
        return 1
    fi

    if ! phpenv_detect; then
        log_error "phpenv not available"
        return 1
    fi

    log_debug "Validating PHP version: $version"

    if phpenv versions --bare 2>/dev/null | grep -q "^${version}$"; then
        log_debug "PHP version $version is installed"
        return 0
    else
        log_warn "PHP version $version is not installed"
        return 1
    fi
}

# ============================================================================
# PRIVATE HELPER FUNCTIONS
# ============================================================================

# Validate PHP version format
# Args: version - version string to validate
# Returns: 0 if valid format, 1 if invalid
_phpenv_validate_version() {
    local version="$1"

    if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid PHP version format: $version"
        log_info "Expected format: major.minor.patch (e.g., 8.3.12)"
        return 1
    fi

    return 0
}

# ============================================================================
# COMPOSER FUNCTIONS
# ============================================================================

# Detect if Composer is installed
# Returns: 0 if Composer is available, 1 if not
composer_detect() {
    log_debug "Detecting Composer installation"

    if command -v composer >/dev/null 2>&1; then
        local composer_version
        composer_version=$(composer --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        log_info "Composer detected: version $composer_version"
        return 0
    else
        log_warn "Composer not found in PATH"
        return 1
    fi
}

# Install Composer globally
# Returns: 0 on success, 1 on failure
composer_install() {
    log_info "Installing Composer..."

    if composer_detect; then
        log_info "Composer already installed"
        return 0
    fi

    # Require PHP to be available
    if ! command -v php >/dev/null 2>&1; then
        log_error "PHP is required to install Composer"
        return 1
    fi

    local os_type
    os_type=$(detect_os)

    case "$os_type" in
        "macos")
            if command -v brew >/dev/null 2>&1; then
                if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
                    LOG_FILE='' log_info "[dry-run] would run: brew install composer (falling back to the verified official installer if it fails); nothing installed"
                    return 0
                fi
                log_info "Installing Composer via Homebrew"
                if brew install composer; then
                    log_success "Composer installed successfully via Homebrew"
                    return 0
                fi
                log_warn "Homebrew install failed, trying official installer..."
            fi
            ;;
    esac

    # Official Composer installer (AX-6f): download -> verify SHA-384 (fail
    # closed) -> run into a PRIVATE temp dir -> verify the produced binary ->
    # publish without overwriting. The temp dir is removed on every path.
    local bin_dir="${_VMS_COMPOSER_BIN_DIR:-/usr/local/bin}"
    local installer_url="https://getcomposer.org/installer"
    local sig_url="https://composer.github.io/installer.sig"

    if [[ "$bin_dir" != /* || "$bin_dir" == *$'\n'* || "$bin_dir" == *$'\t'* ]]; then
        log_error "Composer install directory must be an absolute path: $bin_dir"
        return 1
    fi
    if [[ -e "$bin_dir/composer" || -L "$bin_dir/composer" ]]; then
        log_error "Composer already exists at $bin_dir/composer but is not on PATH — refusing to overwrite it. Add $bin_dir to PATH (or remove that file yourself) and re-run."
        return 1
    fi

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        LOG_FILE='' log_info "[dry-run] would download $installer_url and $sig_url, verify the installer's SHA-384 (fail closed), run it into a private temp dir, verify 'composer --version', then publish $bin_dir/composer (mode 0755; sudo install only after confirmation if $bin_dir is not writable)"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required to download the official Composer installer"
        log_error "Failed to install Composer"
        return 1
    fi

    local tmp_dir rc=0
    if ! tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/vms-composer.XXXXXX"); then
        log_error "Cannot create a private temp dir for the Composer installer"
        return 1
    fi
    _phpenv_composer_official "$tmp_dir" "$bin_dir" "$installer_url" "$sig_url" || rc=$?
    _phpenv_composer_cleanup "$tmp_dir" || true

    if [[ "$rc" -ne 0 ]]; then
        log_error "Failed to install Composer"
        return 1
    fi
    log_success "Composer installed successfully: $bin_dir/composer"
    return 0
}

# Private (AX-6f): fetch, verify, run and publish the official installer.
# Args: <private tmp dir> <bin dir> <installer url> <signature url>
# NOTE (AX-7): export -f'd — no here-documents inside.
_phpenv_composer_official() {
    local tmp_dir="$1" bin_dir="$2" installer_url="$3" sig_url="$4"
    local setup="$tmp_dir/composer-setup.php" build="$tmp_dir/build"
    local dest="$bin_dir/composer"
    local expected_sig="" actual_sig=""

    # Fail closed: a missing/empty/garbled signature must never "match".
    if ! expected_sig=$(curl -fsSL "$sig_url"); then
        log_error "Could not download the Composer installer signature — installer not run"
        return 1
    fi
    expected_sig="${expected_sig//[[:space:]]/}"
    if ! [[ "$expected_sig" =~ ^[0-9A-Fa-f]{96}$ ]]; then
        log_error "Composer installer signature is missing or malformed (expected 96 hex chars of SHA-384) — installer not run"
        return 1
    fi

    if ! curl -fsSL "$installer_url" -o "$setup"; then
        log_error "Could not download the Composer installer"
        return 1
    fi

    # The path is passed via argv, never interpolated into PHP source.
    # shellcheck disable=SC2016 # $argv is PHP, intentionally single-quoted
    if ! actual_sig=$(php -r 'echo hash_file("sha384", $argv[1]);' "$setup"); then
        log_error "Could not hash the downloaded Composer installer — installer not run"
        return 1
    fi
    expected_sig=$(printf '%s' "$expected_sig" | tr '[:upper:]' '[:lower:]')
    actual_sig=$(printf '%s' "$actual_sig" | tr '[:upper:]' '[:lower:]')
    if [[ "$actual_sig" != "$expected_sig" ]]; then
        log_error "Composer installer signature verification FAILED — installer not run"
        return 1
    fi

    if ! mkdir -p "$build"; then
        log_error "Cannot create the private Composer build dir"
        return 1
    fi
    if ! php "$setup" --install-dir="$build" --filename=composer; then
        log_error "The Composer installer failed"
        return 1
    fi
    if [[ ! -f "$build/composer" ]] || ! php "$build/composer" --version >/dev/null 2>&1; then
        log_error "The produced Composer binary failed verification ('composer --version') — not published"
        return 1
    fi

    if [[ ! -d "$bin_dir" ]]; then
        log_error "Composer install directory does not exist: $bin_dir — not published"
        return 1
    fi
    if [[ -e "$dest" || -L "$dest" ]]; then
        log_error "Composer appeared at $dest during install — refusing to overwrite it"
        return 1
    fi

    if [[ -w "$bin_dir" ]]; then
        local part
        if ! part=$(mktemp "$bin_dir/.composer.XXXXXX"); then
            log_error "Cannot stage Composer in $bin_dir"
            return 1
        fi
        if cp "$build/composer" "$part" && chmod 0755 "$part" && mv -- "$part" "$dest"; then
            return 0
        fi
        rm -f -- "$part"
        log_error "Failed to publish Composer to $dest"
        return 1
    fi

    # Not user-writable: privileged publish only after explicit consent.
    if ! vms_confirm_privileged "Composer into $bin_dir (sudo install -m 0755)"; then
        log_warn "Composer was verified but NOT published: $bin_dir needs sudo. Re-run with VMS_CONFIRM=1 to allow 'sudo install -m 0755 <verified composer> $dest', or install Composer with your package manager."
        return 1
    fi
    if ! sudo install -m 0755 "$build/composer" "$dest"; then
        log_error "sudo install of Composer to $dest failed"
        return 1
    fi
    if [[ ! -f "$dest" ]]; then
        log_error "sudo install reported success but $dest is missing"
        return 1
    fi
    return 0
}

# Private (AX-6f): validated removal of the composer temp dir (rule 1.5).
_phpenv_composer_cleanup() {
    local dir="${1:-}" base
    base="${dir##*/}"
    if [[ -z "$dir" || "$dir" != /* || "$dir" == *$'\n'* || "$dir/" == */../* \
        || "$base" != vms-composer.?????? ]]; then
        log_warn "composer: refusing to remove unexpected temp path: $dir"
        return 1
    fi
    if [[ -d "$dir" && ! -L "$dir" ]]; then
        rm -rf -- "$dir"
    fi
    return 0
}

# Install Laravel installer globally via Composer
# Returns: 0 on success, 1 on failure
laravel_install() {
    log_info "Installing Laravel installer..."

    if ! composer_detect; then
        log_warn "Composer not installed. Installing Composer first..."
        if ! composer_install; then
            log_error "Failed to install Composer, cannot install Laravel"
            return 1
        fi
    fi

    if composer global show laravel/installer 2>/dev/null | grep -q "laravel/installer"; then
        log_info "Laravel installer already installed"
        return 0
    fi

    if composer global require laravel/installer; then
        log_success "Laravel installer installed successfully"
        log_info "You can now create projects with: laravel new my-project"
        return 0
    else
        log_error "Failed to install Laravel installer"
        return 1
    fi
}

# Detect if current directory is a Laravel project
# Returns: 0 if Laravel project detected, 1 if not
laravel_detect_project() {
    [[ -f "artisan" ]] && [[ -f "composer.json" ]] && grep -q "laravel/framework" composer.json 2>/dev/null
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Get PHP version for prompt display (only if different from global)
# Returns: PHP version string or empty if same as global
phpenv_get_prompt_version() {
    if ! phpenv_detect; then
        return 1
    fi

    local current_version
    current_version=$(phpenv_get_current)
    local global_version
    global_version=$(phpenv global 2>/dev/null || echo "system")

    # Only show if different from global or if project-specific
    if [ -f ".php-version" ] || [ "$current_version" != "$global_version" ]; then
        echo "$current_version"
    fi
}

# Check if current directory has PHP project configuration
# Returns: 0 if PHP project detected, 1 if not
phpenv_is_php_project() {
    [ -f ".php-version" ] || [ -f "composer.json" ] || [ -f "composer.lock" ] || [ -f "artisan" ]
}

# Export functions for external use
export -f phpenv_detect phpenv_install phpenv_list_versions phpenv_install_version
export -f phpenv_set_global phpenv_set_local phpenv_get_current phpenv_validate_version
export -f phpenv_get_prompt_version phpenv_is_php_project
export -f composer_detect composer_install laravel_install laravel_detect_project
export -f _phpenv_composer_official _phpenv_composer_cleanup
