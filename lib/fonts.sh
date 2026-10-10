#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# ============================================================================
# Font Management Module
# Part of Professional Development Terminal Setup
# ============================================================================
# Handles Nerd Font detection, validation, and installation.
# ============================================================================

# Prevent multiple sourcing
[[ -n "${_FONTS_LOADED:-}" ]] && return 0
readonly _FONTS_LOADED=1

# Source dependencies
_VMS_FONTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$_VMS_FONTS_DIR/lib/logger.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
}
# Font writers publish through the transaction framework (AX-19); sourced
# unconditionally (B1.13-new: inherited function copies lack state globals).
# shellcheck source=lib/mutation.sh
source "$_VMS_FONTS_DIR/lib/mutation.sh"

# ============================================================================
# Configuration
# ============================================================================

# Optional local font files expected at repository root
readonly BUNDLED_FONTS=(
    "MesloLGS NF Regular.ttf"
    "MesloLGS NF Bold.ttf"
    "MesloLGS NF Italic.ttf"
    "MesloLGS NF Bold Italic.ttf"
)

# Font metadata
readonly FONT_FAMILY="MesloLGS Nerd Font"
readonly FONT_ORIGIN="https://github.com/romkatv/powerlevel10k-media"
readonly FONT_LICENSE="Apache License 2.0"

# ============================================================================
# Font Detection
# ============================================================================

# Get font directories for the current OS
font_get_directories() {
    local os
    os=$(uname -s)

    case "$os" in
        Darwin)
            echo "$HOME/Library/Fonts"
            echo "/Library/Fonts"
            echo "/System/Library/Fonts"
            ;;
        Linux)
            echo "$HOME/.local/share/fonts"
            echo "$HOME/.fonts"
            echo "/usr/share/fonts"
            echo "/usr/local/share/fonts"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            echo "$USERPROFILE/AppData/Local/Microsoft/Windows/Fonts"
            echo "C:/Windows/Fonts"
            ;;
    esac
}

# Get the target font directory for installation
font_get_target_directory() {
    local os
    os=$(uname -s)

    case "$os" in
        Darwin)
            echo "$HOME/Library/Fonts"
            ;;
        Linux)
            echo "$HOME/.local/share/fonts"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            echo "$USERPROFILE/AppData/Local/Microsoft/Windows/Fonts"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Detect installed Nerd Fonts
font_detect_installed() {
    local fonts_found=()

    while IFS= read -r dir; do
        if [[ -d "$dir" ]]; then
            while IFS= read -r font; do
                [[ -n "$font" ]] && fonts_found+=("$font")
            done < <(find "$dir" -maxdepth 2 \( -name "*Nerd*" -o -name "*MesloLGS*" \) -type f 2>/dev/null || true)
        fi
    done < <(font_get_directories)

    printf '%s\n' "${fonts_found[@]}"
}

# Check if MesloLGS Nerd Font is installed
font_is_installed() {
    local installed
    installed=$(font_detect_installed | grep -c "MesloLGS" || true)  # grep -c already prints 0; a second echo made "0\n0" and broke -gt arithmetic
    [[ "$installed" -gt 0 ]]
}

# Get installation location of MesloLGS fonts
font_get_location() {
    local first_font
    first_font=$(font_detect_installed | grep "MesloLGS" | head -1)

    if [[ -n "$first_font" ]]; then
        dirname "$first_font"
    fi
}

# ============================================================================
# Font Validation
# ============================================================================

# Validate font file integrity using checksum
font_validate_checksum() {
    local font_file="$1"
    local expected_checksum="$2"

    if [[ ! -f "$font_file" ]]; then
        return 1
    fi

    local actual_checksum
    if command -v shasum >/dev/null 2>&1; then
        actual_checksum=$(shasum -a 256 "$font_file" | cut -d' ' -f1)
    elif command -v sha256sum >/dev/null 2>&1; then
        actual_checksum=$(sha256sum "$font_file" | cut -d' ' -f1)
    else
        # Cannot verify: fail closed (same contract as the download path).
        return 1
    fi

    [[ "$actual_checksum" == "$expected_checksum" ]]
}

# Validate a font file exists and is readable
font_validate_file() {
    local font_file="$1"

    [[ -f "$font_file" && -r "$font_file" ]]
}

# Check if all optional local fonts exist in project root
font_bundled_exist() {
    local missing=0

    for font in "${BUNDLED_FONTS[@]}"; do
        if [[ ! -f "$_VMS_FONTS_DIR/$font" ]]; then
            missing=$(( missing + 1 ))
        fi
    done

    [[ $missing -eq 0 ]]
}

# ============================================================================
# Font Installation
# ============================================================================

# Font file mutations (AX-19). The three writers below used to cp/mv/rm in
# the user's font directory with no backup, no preview and (for URL installs)
# no integrity check. They now run inside a transaction — the caller's, or
# their own (commit on success, rollback on failure) — and publish through
# mutation_file_publish: an existing font is backed up before it is replaced,
# identical files are left untouched, every write is atomic, and
# TRANSACTION_DRY_RUN=1 plans without writing. Callers that run concurrently
# with other workstation mutators take the workstation-mutation lock
# themselves (setup-fonts-enhanced.sh, tools/preview-nerd-fonts.sh): a
# library-level lock would deadlock a caller that already holds it.

_font_require_mutation() {
    if ! declare -F mutation_file_publish >/dev/null 2>&1 || ! declare -F transaction_start >/dev/null 2>&1; then
        log_error "lib/mutation.sh is not loaded in this shell — source lib/fonts.sh here (an inherited function cannot run its transaction)"
        return 1
    fi
}

# _font_in_txn <transaction-name> <fn> [args...]
_font_in_txn() {
    local name="$1" rc=0 own=0
    shift
    _font_require_mutation || return 1
    if ! transaction_is_active; then
        transaction_start "$name" || return 1
        own=1
    fi
    "$@" || rc=1
    if [[ "$own" == 1 ]]; then
        if [[ "$rc" == 0 ]]; then
            transaction_commit >/dev/null || rc=1
        else
            transaction_rollback >/dev/null 2>&1 || log_error "Font rollback failed — see the audit journal"
            log_error "Font change rolled back"
        fi
    fi
    return "$rc"
}

# Create the per-user font directory (planned only under dry-run).
_font_ensure_target_dir() {
    local target_dir="$1"
    [[ -d "$target_dir" ]] && return 0
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        LOG_FILE='' log_info "[dry-run] would create font directory: $target_dir"
        return 0
    fi
    mkdir -p -- "$target_dir" || { log_error "Cannot create font directory: $target_dir"; return 1; }
}

# Refresh fontconfig after a real change (Linux only; derived state).
_font_refresh_cache() {
    local target_dir="$1"
    [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]] && return 0
    if [[ "$(uname -s)" == "Linux" ]] && command -v fc-cache >/dev/null 2>&1; then
        log_info "Refreshing font cache..."
        fc-cache -f "$target_dir" 2>/dev/null || true
    fi
}

# Install local MesloLGS fonts when present at repository root.
# Missing local files are skipped with a warning (they are optional); a
# failed publish rolls back every font this call installed or replaced.
font_install_bundled() {
    _font_in_txn font_install_bundled _font_install_bundled_txn
}

_font_install_bundled_txn() {
    local target_dir font src installed=0 missing=0
    target_dir=$(font_get_target_directory)
    if [[ -z "$target_dir" ]]; then
        log_error "Unsupported operating system for font installation"
        return 1
    fi
    _font_ensure_target_dir "$target_dir" || return 1

    for font in "${BUNDLED_FONTS[@]}"; do
        src="$_VMS_FONTS_DIR/$font"
        if [[ ! -f "$src" ]]; then
            log_warn "Missing local font file: $font"
            missing=$((missing + 1))
            continue
        fi
        if ! mutation_file_publish "$target_dir/$font" "$src"; then
            log_error "Failed to install: $font"
            return 1
        fi
        installed=$((installed + 1))
    done

    if [[ $installed -eq 0 ]]; then
        log_error "No fonts were installed"
        return 1
    fi
    _font_refresh_cache "$target_dir"
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        LOG_FILE='' log_info "[dry-run] $installed font(s) planned for $target_dir; nothing written"
    else
        log_success "Installed $installed font(s) to $target_dir"
    fi
    return 0
}

# Install one font from a URL, verified against its expected SHA-256.
# Usage: font_install_from_url <https-url> <font-file-name> <sha256>
# Fails closed on a missing/malformed checksum, a non-https URL, a file name
# that is not a plain *.ttf/*.otf name, a failed download or a mismatch.
font_install_from_url() {
    local url="${1:-}" font_name="${2:-}" expected="${3:-}"
    if [[ "$url" != https://* || "$url" == *$'\n'* ]]; then
        log_error "font_install_from_url: an https:// URL is required"
        return 1
    fi
    if [[ -z "$font_name" || "$font_name" == */* || "$font_name" == .* || "$font_name" == *$'\n'* \
        || ! "$font_name" =~ \.(ttf|otf|TTF|OTF)$ ]]; then
        log_error "font_install_from_url: font name must be a plain .ttf/.otf file name: $font_name"
        return 1
    fi
    if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
        log_error "font_install_from_url: a 64-hex SHA-256 checksum is required (fail closed)"
        return 1
    fi
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        LOG_FILE='' log_info "[dry-run] would download $url, verify SHA-256 $expected, and install $font_name"
        return 0
    fi
    _font_in_txn font_install_from_url _font_install_from_url_txn "$url" "$font_name" "$expected"
}

_font_install_from_url_txn() {
    local url="$1" font_name="$2" expected="$3" target_dir temp_file actual=""
    target_dir=$(font_get_target_directory)
    if [[ -z "$target_dir" ]]; then
        log_error "Unsupported operating system"
        return 1
    fi
    _font_ensure_target_dir "$target_dir" || return 1
    temp_file=$(mktemp "${TMPDIR:-/tmp}/vms-font.XXXXXX") || { log_error "Cannot create a temporary file"; return 1; }

    log_info "Downloading $font_name..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' "$url" -o "$temp_file" || { rm -f -- "$temp_file"; log_error "Download failed"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q --https-only "$url" -O "$temp_file" || { rm -f -- "$temp_file"; log_error "Download failed"; return 1; }
    else
        rm -f -- "$temp_file"
        log_error "Neither curl nor wget available"
        return 1
    fi
    if command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$temp_file" | cut -d' ' -f1)
    elif command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$temp_file" | cut -d' ' -f1)
    fi
    if [[ -z "$actual" || "$(printf '%s' "$actual" | tr 'A-F' 'a-f')" != "$(printf '%s' "$expected" | tr 'A-F' 'a-f')" ]]; then
        rm -f -- "$temp_file"
        log_error "Checksum mismatch for $font_name (or no sha256 tool) — not installed"
        return 1
    fi
    if ! mutation_file_publish "$target_dir/$font_name" "$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
    rm -f -- "$temp_file"
    _font_refresh_cache "$target_dir"
    log_success "Installed: $font_name"
    return 0
}

# Uninstall MesloLGS fonts. Every removed file is registered with the
# transaction first, so a failure part-way restores the ones already removed.
font_uninstall() {
    _font_in_txn font_uninstall _font_uninstall_txn
}

_font_uninstall_txn() {
    local target_dir font font_path removed=0
    target_dir=$(font_get_target_directory)
    if [[ -z "$target_dir" ]]; then
        log_error "Unsupported operating system"
        return 1
    fi
    for font in "${BUNDLED_FONTS[@]}"; do
        font_path="$target_dir/$font"
        [[ -f "$font_path" ]] || continue
        if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
            LOG_FILE='' log_info "[dry-run] would remove: $font_path"
            removed=$((removed + 1))
            continue
        fi
        transaction_add_file "$font_path" || return 1
        if ! rm -f -- "$font_path"; then
            log_error "Failed to remove: $font_path"
            return 1
        fi
        log_info "Removed: $font"
        removed=$((removed + 1))
    done
    if [[ $removed -eq 0 ]]; then
        log_info "No MesloLGS fonts found to remove"
        return 0
    fi
    _font_refresh_cache "$target_dir"
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        LOG_FILE='' log_info "[dry-run] $removed font(s) would be removed; nothing written"
    else
        log_success "Removed $removed font(s)"
    fi
    return 0
}

# ============================================================================
# Font Rendering Test
# ============================================================================

# Test if terminal can render Nerd Font icons
font_test_rendering() {
    echo "Testing Nerd Font icon rendering:"
    echo
    echo "  Powerline:    (should show branch icon)"
    echo "  Development:  (should show git icon)"
    echo "  File types:   (should show JS icon)"
    echo "  Folders:      (should show folder icon)"
    echo
    echo "If icons appear as boxes (□) or ?, fonts are not configured correctly."
}

# Check terminal font configuration
font_check_terminal() {
    local term="${TERM_PROGRAM:-unknown}"

    case "$term" in
        vscode)
            echo "VS Code: Set 'Terminal › Integrated: Font Family' to '$FONT_FAMILY'"
            ;;
        Apple_Terminal)
            echo "Terminal.app: Preferences → Profiles → Font → '$FONT_FAMILY'"
            ;;
        iTerm.app)
            echo "iTerm2: Preferences → Profiles → Text → Font → '$FONT_FAMILY'"
            ;;
        Hyper)
            echo "Hyper: Set fontFamily in ~/.hyper.js to '$FONT_FAMILY'"
            ;;
        *)
            echo "Configure your terminal to use font: '$FONT_FAMILY'"
            ;;
    esac
}

# ============================================================================
# Font Information
# ============================================================================

# Get font status summary
font_status() {
    echo "Font Status"
    echo "==========="
    echo

    if font_is_installed; then
        local location
        location=$(font_get_location)
        echo "Status:    Installed"
        echo "Location: $location"
    else
        echo "Status:    Not installed"
    fi

    echo
    echo "Bundled Fonts:"
    for font in "${BUNDLED_FONTS[@]}"; do
        if [[ -f "$_VMS_FONTS_DIR/$font" ]]; then
            echo "   $font"
        else
            echo "   $font (missing)"
        fi
    done

    echo
    echo "Font Family: $FONT_FAMILY"
    echo "Source:      $FONT_ORIGIN"
    echo "License:     $FONT_LICENSE"
}

# Generate checksums for local MesloLGS font files
font_generate_checksums() {
    echo "# Font Checksums (SHA-256)"
    echo "# Generated: $(date -Iseconds)"
    echo

    for font in "${BUNDLED_FONTS[@]}"; do
        local font_path="$_VMS_FONTS_DIR/$font"
        if [[ -f "$font_path" ]]; then
            if command -v shasum >/dev/null 2>&1; then
                shasum -a 256 "$font_path"
            elif command -v sha256sum >/dev/null 2>&1; then
                sha256sum "$font_path"
            fi
        fi
    done
}

# ============================================================================
# Export Functions
# ============================================================================

export -f font_get_directories
export -f font_get_target_directory
export -f font_detect_installed
export -f font_is_installed
export -f font_get_location
export -f font_validate_checksum
export -f font_validate_file
export -f font_bundled_exist
export -f font_install_bundled
export -f font_install_from_url
export -f font_uninstall
export -f _font_require_mutation _font_in_txn _font_ensure_target_dir _font_refresh_cache
export -f _font_install_bundled_txn _font_install_from_url_txn _font_uninstall_txn
export -f font_test_rendering
export -f font_check_terminal
export -f font_status
export -f font_generate_checksums
