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
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "$SCRIPT_DIR/lib/logger.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
}

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
    installed=$(font_detect_installed | grep -c "MesloLGS" || echo "0")
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
        # Can't verify, assume valid
        return 0
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
        if [[ ! -f "$SCRIPT_DIR/$font" ]]; then
            ((missing++))
        fi
    done

    [[ $missing -eq 0 ]]
}

# ============================================================================
# Font Installation
# ============================================================================

# Install local MesloLGS fonts when present at repository root
font_install_bundled() {
    local target_dir
    target_dir=$(font_get_target_directory)

    if [[ -z "$target_dir" ]]; then
        log_error "Unsupported operating system for font installation"
        return 1
    fi

    # Create target directory if needed
    mkdir -p "$target_dir"

    local installed=0
    local failed=0

    for font in "${BUNDLED_FONTS[@]}"; do
        local src="$SCRIPT_DIR/$font"

        if [[ -f "$src" ]]; then
            if cp "$src" "$target_dir/"; then
                log_success "Installed: $font"
                ((installed++))
            else
                log_error "Failed to install: $font"
                ((failed++))
            fi
        else
            log_warn "Missing local font file: $font"
            ((failed++))
        fi
    done

    # Refresh font cache on Linux
    if [[ "$(uname -s)" == "Linux" ]] && command -v fc-cache >/dev/null 2>&1; then
        log_info "Refreshing font cache..."
        fc-cache -f "$target_dir" 2>/dev/null || true
    fi

    if [[ $installed -gt 0 ]]; then
        log_success "Installed $installed font(s) to $target_dir"
        return 0
    else
        log_error "No fonts were installed"
        return 1
    fi
}

# Install fonts from URL
font_install_from_url() {
    local url="$1"
    local font_name="$2"
    local target_dir
    target_dir=$(font_get_target_directory)

    if [[ -z "$target_dir" ]]; then
        log_error "Unsupported operating system"
        return 1
    fi

    mkdir -p "$target_dir"

    local temp_file
    temp_file=$(mktemp)

    log_info "Downloading $font_name..."

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$temp_file"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$url" -O "$temp_file"
    else
        log_error "Neither curl nor wget available"
        rm -f "$temp_file"
        return 1
    fi

    if [[ -f "$temp_file" && -s "$temp_file" ]]; then
        mv "$temp_file" "$target_dir/$font_name"
        log_success "Installed: $font_name"

        # Refresh cache on Linux
        if [[ "$(uname -s)" == "Linux" ]] && command -v fc-cache >/dev/null 2>&1; then
            fc-cache -f "$target_dir" 2>/dev/null || true
        fi

        return 0
    else
        log_error "Download failed"
        rm -f "$temp_file"
        return 1
    fi
}

# Uninstall MesloLGS fonts
font_uninstall() {
    local target_dir
    target_dir=$(font_get_target_directory)

    if [[ -z "$target_dir" ]]; then
        log_error "Unsupported operating system"
        return 1
    fi

    local removed=0

    for font in "${BUNDLED_FONTS[@]}"; do
        local font_path="$target_dir/$font"
        if [[ -f "$font_path" ]]; then
            rm -f "$font_path"
            log_info "Removed: $font"
            ((removed++))
        fi
    done

    if [[ $removed -gt 0 ]]; then
        # Refresh cache on Linux
        if [[ "$(uname -s)" == "Linux" ]] && command -v fc-cache >/dev/null 2>&1; then
            fc-cache -f "$target_dir" 2>/dev/null || true
        fi

        log_success "Removed $removed font(s)"
        return 0
    else
        log_info "No MesloLGS fonts found to remove"
        return 0
    fi
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
        if [[ -f "$SCRIPT_DIR/$font" ]]; then
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
        local font_path="$SCRIPT_DIR/$font"
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
export -f font_test_rendering
export -f font_check_terminal
export -f font_status
export -f font_generate_checksums
