#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source paths; SC2034: intentionally exported vars

# Rust Version Management Library Module
# Part of Professional Development Terminal Setup
# Provides standardized Rust version management interface using rustup
# Integrates with foundational libraries for caching, logging, and environment setup

# Source foundational libraries
_VMS_RUSTUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_VMS_RUSTUP_DIR}/env.sh"
source "${_VMS_RUSTUP_DIR}/cache.sh"
source "${_VMS_RUSTUP_DIR}/logger.sh"

# Rust version management configuration
RUSTUP_CACHE_PREFIX="rustup"
RUSTUP_CACHE_TTL=300  # 5 minutes cache for version lists

# ============================================================================
# RUSTUP DETECTION AND INSTALLATION
# ============================================================================

# Detect if rustup is installed and available
# Returns: 0 if rustup is available, 1 if not
rustup_detect() {
    log_debug "Detecting rustup installation"

    if command -v rustup >/dev/null 2>&1; then
        local rustup_version=$(rustup --version 2>/dev/null | head -n1 | cut -d' ' -f2)
        log_info "rustup detected: version $rustup_version"
        return 0
    else
        log_warn "rustup not found in PATH"
        return 1
    fi
}

# Install rustup if missing
# Returns: 0 on success, 1 on failure
rustup_install() {
    log_info "Installing rustup..."

    if rustup_detect; then
        log_info "rustup already installed"
        return 0
    fi

    local os_type
    os_type=$(detect_os) || os_type="unknown"

    # Check if curl is available
    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required to install rustup"
        return 1
    fi

    case "$os_type" in
        "macos")
            if command -v brew >/dev/null 2>&1; then
                if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
                    log_info "[DRY RUN] Would install rustup via Homebrew: brew install rustup"
                    return 0
                fi
                log_info "Installing rustup via Homebrew"
                if brew install rustup; then
                    log_success "rustup installed successfully via Homebrew"
                    return 0
                fi
                log_error "Failed to install rustup via Homebrew"
                return 1
            fi
            ;;
    esac

    # Pinned, checksum-verified rustup-init (AX-9; ENGINEERING_RULES 2.3/7.1):
    # map host -> target triple, look up the pinned digest, then
    # download -> verify -> execute inside a private temp dir. Nothing is
    # written under $HOME before verification passes.
    local triple
    if ! triple=$(_rustup_target_triple); then
        log_error "Unsupported host for the pinned rustup installer ($(uname -s 2>/dev/null || echo '?') $(uname -m 2>/dev/null || echo '?')); refusing to install. Install rustup manually: https://rustup.rs"
        return 1
    fi

    local expected_sha256
    if ! expected_sha256=$(_rustup_expected_sha256 "$triple") \
        || [[ ! "$expected_sha256" =~ ^[0-9a-f]{64}$ ]]; then
        log_error "No pinned rustup-init checksum for target $triple; refusing to install"
        return 1
    fi

    local init_version
    init_version=$(_rustup_init_version) || init_version=""
    if [[ -z "$init_version" ]]; then
        log_error "No pinned rustup-init version; refusing to install"
        return 1
    fi
    local init_url="https://static.rust-lang.org/rustup/archive/${init_version}/${triple}/rustup-init"

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[DRY RUN] Would download pinned rustup-init ${init_version} (${triple})"
        log_info "[DRY RUN]   URL: ${init_url}"
        log_info "[DRY RUN]   Expected sha256: ${expected_sha256}"
        log_info "[DRY RUN] Would verify the checksum, then run: rustup-init -y --no-modify-path --profile minimal"
        return 0
    fi

    local tmp_root="${TMPDIR:-/tmp}"
    tmp_root="${tmp_root%/}"
    local work_dir
    if ! work_dir=$(mktemp -d "${tmp_root}/vms-rustup-init.XXXXXX") || [[ -z "$work_dir" ]]; then
        log_error "Failed to create a private temporary directory for the rustup installer"
        return 1
    fi

    local install_rc=0
    _rustup_install_verified "$work_dir" "$init_url" "$expected_sha256" \
        "$init_version" "$triple" || install_rc=$?
    # Always clean up the private dir, on success and on every failure path.
    _rustup_remove_work_dir "$work_dir" "$tmp_root" \
        || log_warn "Could not remove rustup installer temp dir: $work_dir"
    return "$install_rc"
}

# ============================================================================
# VERSION MANAGEMENT
# ============================================================================

# List available Rust versions (cached)
# Returns: 0 on success, 1 on failure
rustup_list_versions() {
    log_debug "Listing available Rust versions"

    if ! rustup_detect; then
        log_error "rustup not available"
        return 1
    fi

    local cache_key="${RUSTUP_CACHE_PREFIX}_versions"
    local cached_versions

    if cached_versions=$(cache_get "$cache_key"); then
        log_debug "Using cached Rust versions list"
        echo "$cached_versions"
        return 0
    fi

    log_debug "Fetching Rust versions from rustup"
    local versions
    if versions=$(rustup toolchain list 2>/dev/null); then
        cache_set "$cache_key" "$versions" "$RUSTUP_CACHE_TTL"
        echo "$versions"
        return 0
    else
        log_error "Failed to list Rust versions"
        return 1
    fi
}

# Install specific Rust version
# Args: version - Rust version to install (e.g., "1.75.0")
# Returns: 0 on success, 1 on failure
rustup_install_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Rust version not specified"
        return 1
    fi

    if ! _rustup_validate_version "$version"; then
        return 1
    fi

    if ! rustup_detect; then
        log_error "rustup not available"
        return 1
    fi

    log_info "Installing Rust $version..."

    # Check if already installed
    if rustup toolchain list 2>/dev/null | grep -q "$version"; then
        log_info "Rust $version already installed"
        return 0
    fi

    # Install the version
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would run: rustup toolchain install $version; nothing installed"
        return 0
    fi

    if rustup toolchain install "$version" 2>/dev/null; then
        log_success "Rust $version installed successfully"
        # Invalidate cache
        cache_delete "${RUSTUP_CACHE_PREFIX}_versions"
        return 0
    else
        log_error "Failed to install Rust $version"
        return 1
    fi
}

# Set global Rust version
# Args: version - Rust version to set as default
# Returns: 0 on success, 1 on failure
rustup_set_global() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Rust version not specified"
        return 1
    fi

    if ! _rustup_validate_version "$version"; then
        return 1
    fi

    if ! rustup_detect; then
        log_error "rustup not available"
        return 1
    fi

    # Check if version is installed
    if ! rustup_validate_version "$version"; then
        log_warn "Rust $version not found, attempting to install..."
        if ! rustup_install_version "$version"; then
            return 1
        fi
    fi

    log_info "Setting global Rust version to $version"
    if rustup default "$version" 2>/dev/null; then
        log_success "Global Rust version set to $version"
        return 0
    else
        log_error "Failed to set global Rust version"
        return 1
    fi
}

# Set local Rust version for current directory
# Args: version - Rust version to set for current project
# Returns: 0 on success, 1 on failure
rustup_set_local() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Rust version not specified"
        return 1
    fi

    if ! _rustup_validate_version "$version"; then
        return 1
    fi

    if ! rustup_detect; then
        log_error "rustup not available"
        return 1
    fi

    # Check if version is installed
    if ! rustup_validate_version "$version"; then
        log_warn "Rust $version not found, attempting to install..."
        if ! rustup_install_version "$version"; then
            return 1
        fi
    fi

    log_info "Setting local Rust version to $version"

    # Create rust-toolchain file
    if echo "$version" > rust-toolchain; then
        log_success "Local Rust version set to $version"
        return 0
    else
        log_error "Failed to create rust-toolchain file"
        return 1
    fi
}

# Get current Rust version
# Returns: current Rust version string
rustup_get_current() {
    log_debug "Getting current Rust version"

    if ! rustup_detect; then
        echo "none"
        return 1
    fi

    local current_version
    if current_version=$(rustc --version 2>/dev/null | cut -d' ' -f2); then
        echo "$current_version"
        return 0
    else
        echo "none"
        return 1
    fi
}

# Validate that a Rust version exists in installed versions
# Args: version - Rust version to validate
# Returns: 0 if version exists, 1 if not
rustup_validate_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Rust version not specified"
        return 1
    fi

    if ! rustup_detect; then
        log_error "rustup not available"
        return 1
    fi

    log_debug "Validating Rust version: $version"

    if rustup toolchain list 2>/dev/null | grep -q "$version"; then
        log_debug "Rust version $version is installed"
        return 0
    else
        log_warn "Rust version $version is not installed"
        return 1
    fi
}

# ============================================================================
# PRIVATE HELPER FUNCTIONS
# ============================================================================

# Validate Rust version format
# Args: version - version string to validate
# Returns: 0 if valid format, 1 if invalid
_rustup_validate_version() {
    local version="$1"

    if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid Rust version format: $version"
        log_info "Expected format: major.minor.patch (e.g., 1.75.0)"
        return 1
    fi

    return 0
}

# ----------------------------------------------------------------------------
# Pinned rustup-init (AX-9, P3-1; ENGINEERING_RULES 2.3 + 7.1)
# ----------------------------------------------------------------------------
# The pin lives in function bodies as literals (not global variables) on
# purpose: rustup_install is `export -f`'d, so a child bash re-imports the
# functions but NOT unexported globals — a global pin would silently become
# empty/attacker-chosen there. No environment variable can replace or bypass
# the pinned version or digests; tests override these functions in their own
# shell instead.
#
# Pin verified 2026-10-09 (lane L5). Version from
# https://static.rust-lang.org/rustup/release-stable.toml (version = '1.29.1').
# For EVERY target below the digest was cross-checked two ways, and both
# matched the value pinned here:
#   1. upstream-published
#      https://static.rust-lang.org/rustup/archive/1.29.1/<target>/rustup-init.sha256
#   2. `shasum -a 256` AND `sha256sum` of an independent download of
#      https://static.rust-lang.org/rustup/archive/1.29.1/<target>/rustup-init
#      (byte size equal to the served Content-Length) into a scratch dir
#      under /tmp (binaries never executed; deleted after).
# Bump procedure: change the version AND every digest together, repeating the
# same two-source cross-check for each target.

# Print the pinned rustup-init release version.
_rustup_init_version() {
    printf '%s\n' "1.29.1"
}

# Print the pinned sha256 of rustup-init for a target triple.
# Args: triple. Returns: 0 + digest on stdout; 1 for an unpinned triple.
_rustup_expected_sha256() {
    case "${1:-}" in
        x86_64-unknown-linux-gnu)   printf '%s\n' "dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71" ;;
        aarch64-unknown-linux-gnu)  printf '%s\n' "15f6e4ce9f583b929c996c91562bad6d4454f3281de858b02cdfdef615fac433" ;;
        x86_64-unknown-linux-musl)  printf '%s\n' "331228566cc931f32cd684f9bebc5956a5e5d7394c8d5de595f196a658ab98e6" ;;
        aarch64-unknown-linux-musl) printf '%s\n' "1ddf36182ac5d1782dbeefcb9bea7f5f9412d88f4a0d5047b1564a223624e8c6" ;;
        x86_64-apple-darwin)        printf '%s\n' "259e2b84274434085163fe8d556510571772cda2aa6d87ca6aa664f57bc644e3" ;;
        aarch64-apple-darwin)       printf '%s\n' "ec1b9233e7f72990ecd8e62063fa7f6c3dfc2bec8e97f88bff165f9100ac696a" ;;
        *) return 1 ;;
    esac
}

# Detect a musl-libc Linux host. Mirrors rustup's own rustup-init.sh probe
# (`ldd --version` mentions musl), captured rather than piped so a caller's
# pipefail cannot turn musl ldd's non-zero exit into a false negative.
_rustup_host_is_musl() {
    command -v ldd >/dev/null 2>&1 || return 1
    local ldd_out=""
    ldd_out=$(ldd --version 2>&1) || true
    [[ "$ldd_out" == *musl* ]]
}

# Map the host to a pinned rustup target triple. OS family comes from the
# canonical detect_os (lib/env.sh, P1-9: uname -s; WSL is Linux), the CPU from
# uname -m. Returns: 0 + triple on stdout; 1 for any unmapped host (fail closed).
_rustup_target_triple() {
    local os="" arch="" libc="gnu"
    os=$(detect_os 2>/dev/null) || return 1
    arch=$(uname -m 2>/dev/null) || return 1
    case "$arch" in
        x86_64|amd64)  arch="x86_64" ;;
        arm64|aarch64) arch="aarch64" ;;
        *) return 1 ;;
    esac
    case "$os" in
        macos)
            printf '%s-apple-darwin\n' "$arch"
            ;;
        linux|wsl)
            if _rustup_host_is_musl; then
                libc="musl"
            fi
            printf '%s-unknown-linux-%s\n' "$arch" "$libc"
            ;;
        *)
            return 1
            ;;
    esac
}

# Print the lowercase sha256 of a file. Portable: sha256sum, else
# `shasum -a 256`. Returns: 0 + digest; 1 on hashing failure; 2 when no
# sha256 tool exists (callers fail closed).
_rustup_sha256_file() {
    local file="${1:-}" out=""
    [[ -n "$file" && -f "$file" ]] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        out=$(sha256sum "$file" 2>/dev/null) || return 1
    elif command -v shasum >/dev/null 2>&1; then
        out=$(shasum -a 256 "$file" 2>/dev/null) || return 1
    else
        return 2
    fi
    out="${out%%[[:space:]]*}"
    [[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$out"
}

# Download -> verify -> execute rustup-init inside an already-created private
# work dir. Never writes outside work_dir before the checksum matches.
# Args: work_dir url expected_sha256 version triple. Returns: 0/1.
_rustup_install_verified() {
    local work_dir="${1:-}" url="${2:-}" expected="${3:-}"
    local version="${4:-}" triple="${5:-}"
    local init_bin="${work_dir}/rustup-init"

    if [[ -z "$work_dir" || ! -d "$work_dir" || -z "$url" || -z "$expected" ]]; then
        log_error "rustup installer: invalid internal arguments; refusing to install"
        return 1
    fi

    log_info "Downloading rustup installer (rustup-init ${version}, ${triple})..."
    if ! curl -fsSL -o "$init_bin" "$url"; then
        log_error "Failed to download rustup installer"
        return 1
    fi

    local actual="" sha_rc=0
    actual=$(_rustup_sha256_file "$init_bin") || sha_rc=$?
    if (( sha_rc == 2 )); then
        log_error "Neither sha256sum nor shasum is available; refusing to execute an unverified rustup installer"
        return 1
    fi
    if (( sha_rc != 0 )) || [[ -z "$actual" ]]; then
        log_error "Could not compute the checksum of the downloaded rustup installer; refusing to execute"
        return 1
    fi
    if [[ "$actual" != "$expected" ]]; then
        log_error "rustup installer checksum mismatch (expected ${expected}, got ${actual}); refusing to execute"
        return 1
    fi
    log_info "Downloaded rustup installer verified (sha256 ${actual})"

    if ! chmod 700 "$init_bin"; then
        log_error "Failed to mark the verified rustup installer executable"
        return 1
    fi

    # Install rustup with minimal profile and no modifications to shell files
    log_info "Running rustup installer..."
    if "$init_bin" -y --no-modify-path --profile minimal 2>/dev/null; then
        # Add cargo bin to PATH if not already there
        local cargo_bin="$HOME/.cargo/bin"
        if [[ ":$PATH:" != *":$cargo_bin:"* ]]; then
            export PATH="$cargo_bin:$PATH"
        fi

        log_success "rustup installed successfully"
        return 0
    else
        log_error "Failed to install rustup"
        return 1
    fi
}

# Remove the private installer work dir — only a real directory (not a
# symlink) created by rustup_install under the expected temp root
# (ENGINEERING_RULES 1.5: validated deletion path).
# Args: work_dir tmp_root. Returns: 0 removed/absent; 1 refused.
_rustup_remove_work_dir() {
    local work_dir="${1:-}" tmp_root="${2:-}"
    if [[ -z "$work_dir" || -z "$tmp_root" ]]; then
        return 1
    fi
    case "$work_dir" in
        "${tmp_root}/vms-rustup-init."?*) ;;
        *)
            log_warn "Refusing to remove unexpected rustup temp path: $work_dir"
            return 1
            ;;
    esac
    case "$work_dir" in
        *..*)
            log_warn "Refusing to remove unexpected rustup temp path: $work_dir"
            return 1
            ;;
    esac
    if [[ -L "$work_dir" ]]; then
        log_warn "Refusing to remove symlinked rustup temp path: $work_dir"
        return 1
    fi
    [[ -d "$work_dir" ]] || return 0
    rm -rf -- "$work_dir"
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Get Rust version for prompt display (only if different from default)
# Returns: Rust version string or empty if same as default
rustup_get_prompt_version() {
    if ! rustup_detect; then
        return 1
    fi

    local current_version=$(rustup_get_current)
    local default_version=$(rustup show active-toolchain 2>/dev/null | head -n1 | cut -d' ' -f1)

    # Only show if different from default or if project-specific
    if [ -f "rust-toolchain" ] || [ "$current_version" != "$default_version" ]; then
        echo "$current_version"
    fi
}

# Check if current directory has Rust project configuration
# Returns: 0 if Rust project detected, 1 if not
rustup_is_rust_project() {
    [ -f "rust-toolchain" ] || [ -f "Cargo.toml" ] || [ -f "rust-toolchain.toml" ]
}

# Export functions for external use
export -f rustup_detect rustup_install rustup_list_versions rustup_install_version
export -f rustup_set_global rustup_set_local rustup_get_current rustup_validate_version
export -f rustup_get_prompt_version rustup_is_rust_project
# rustup_install's private helpers travel with it: an exported rustup_install
# run in a child bash must find the pinned version/digests, not fail on
# command-not-found. (Serialization-safe bodies: no here-docs — AX-7.)
export -f _rustup_init_version _rustup_expected_sha256 _rustup_host_is_musl
export -f _rustup_target_triple _rustup_sha256_file _rustup_install_verified
export -f _rustup_remove_work_dir
