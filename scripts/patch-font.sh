#!/usr/bin/env bash
# shellcheck disable=SC1091
# ============================================================================
# Custom Font Patcher — Nerd Font Glyph Injector
# Part of Professional Development Terminal Setup
# ============================================================================
# Patches any TTF/OTF font with the full Nerd Fonts glyph set (icons,
# Powerline symbols, Devicons, Font Awesome, etc.) so it works with
# PowerLevel10k, Oh My Zsh, and other glyph-aware tools.
#
# Wraps the upstream Nerd Fonts font-patcher v3.4.0.
# Requires: fontforge (brew install fontforge)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHER_DIR="$SCRIPT_DIR/FontPatcher"
PATCHER="$PATCHER_DIR/font-patcher"
DEFAULT_OUTPUT="$SCRIPT_DIR/patched-fonts"

# Source logging (with fallback)
if [[ -f "$SCRIPT_DIR/lib/logger.sh" ]]; then
    source "$SCRIPT_DIR/lib/logger.sh"
else
    log_info()    { echo "[INFO]    $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warn()    { echo "[WARN]    $*"; }
    log_error()   { echo "[ERROR]   $*" >&2; }
fi

# ============================================================================
# Dependency Management
# ============================================================================

ensure_fontforge() {
    if command -v fontforge >/dev/null 2>&1; then
        log_info "FontForge detected: $(fontforge --version 2>&1 | head -1 || echo 'ok')"
        return 0
    fi

    log_warn "FontForge is not installed — it is required for font patching."
    echo

    if command -v brew >/dev/null 2>&1; then
        read -r -p "Install FontForge via Homebrew now? [Y/n]: " answer
        case "${answer:-y}" in
            [Yy]*)
                log_info "Installing FontForge..."
                brew install fontforge
                log_success "FontForge installed"
                return 0
                ;;
        esac
    fi

    log_error "Please install FontForge manually:"
    echo "  macOS:  brew install fontforge"
    echo "  Ubuntu: sudo apt install fontforge python3-fontforge"
    echo "  Fedora: sudo dnf install fontforge"
    return 1
}

# ============================================================================
# Font Patching
# ============================================================================

patch_font() {
    local input_file="$1"
    local output_dir="$2"
    local mono_flag="$3"
    local extra_args=("${@:4}")

    if [[ ! -f "$input_file" ]]; then
        log_error "Font file not found: $input_file"
        return 1
    fi

    # Validate file type
    local ext="${input_file##*.}"
    ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
    case "$ext" in
        ttf|otf|woff|woff2|sfd) ;;
        *)
            log_error "Unsupported font format: .$ext (expected ttf, otf, woff, woff2, or sfd)"
            return 1
            ;;
    esac

    if [[ ! -f "$PATCHER" ]]; then
        log_error "font-patcher not found at $PATCHER"
        log_error "The FontPatcher directory may be missing or incomplete."
        return 1
    fi

    mkdir -p "$output_dir"

    local basename
    basename="$(basename "$input_file")"
    log_info "Patching: $basename"
    log_info "Output:   $output_dir/"

    local cmd=(fontforge --script "$PATCHER" "$input_file"
        --complete
        --careful
        --outputdir "$output_dir"
    )

    if [[ "$mono_flag" == "true" ]]; then
        cmd+=(--mono)
        log_info "Mode:     Mono (single-width glyphs)"
    else
        log_info "Mode:     Normal (proportional glyphs)"
    fi

    if [[ ${#extra_args[@]} -gt 0 ]]; then
        cmd+=("${extra_args[@]}")
    fi

    echo
    log_info "Running font-patcher..."
    echo "────────────────────────────────────────"

    if "${cmd[@]}"; then
        echo "────────────────────────────────────────"
        echo
        log_success "Font patched successfully!"
        log_info "Patched files in: $output_dir/"
        ls -lh "$output_dir/"*"${basename%.*}"* 2>/dev/null || ls -lh "$output_dir/" | tail -5
        return 0
    else
        echo "────────────────────────────────────────"
        log_error "Font patching failed."
        log_info "Try running with --verbose for more details:"
        echo "  fontforge --script $PATCHER \"$input_file\" --complete --careful"
        return 1
    fi
}

# ============================================================================
# Font Installation
# ============================================================================

install_patched_fonts() {
    local source_dir="$1"

    if [[ ! -d "$source_dir" ]]; then
        log_error "Directory not found: $source_dir"
        return 1
    fi

    local font_files
    font_files=$(find "$source_dir" -maxdepth 1 \( -name "*.ttf" -o -name "*.otf" \) 2>/dev/null)

    if [[ -z "$font_files" ]]; then
        log_warn "No patched font files found in $source_dir"
        return 1
    fi

    local dest_dir
    if [[ "$OSTYPE" == "darwin"* ]]; then
        dest_dir="$HOME/Library/Fonts"
    else
        dest_dir="$HOME/.local/share/fonts"
        mkdir -p "$dest_dir"
    fi

    local count=0
    while IFS= read -r font; do
        cp "$font" "$dest_dir/"
        log_success "Installed: $(basename "$font") → $dest_dir/"
        ((count++))
    done <<< "$font_files"

    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        log_info "Refreshing font cache..."
        fc-cache -f 2>/dev/null || true
    fi

    log_success "$count font(s) installed to $dest_dir"
    log_info "Restart your terminal or applications to use the new font."
}

# ============================================================================
# Info
# ============================================================================

show_glyph_sets() {
    echo "Included glyph sets (all applied with --complete):"
    echo
    echo "  Set                     Icons  Description"
    echo "  ──────────────────────  ─────  ────────────────────────────────"
    echo "  Powerline Symbols       ~20    Git branch, line-number, lock"
    echo "  Powerline Extra         ~30    Column, right-angle, flame"
    echo "  Font Awesome            ~700   Web icons (cloud, gear, etc.)"
    echo "  Font Awesome Extension  ~170   Additional FA icons"
    echo "  Devicons                ~170   Language/tool logos"
    echo "  Octicons                ~250   GitHub icons"
    echo "  Material Design         ~7000  Google material icons"
    echo "  Weather Icons           ~220   Weather & moon phases"
    echo "  Codicons                ~420   VS Code icons"
    echo "  Pomicons                ~10    Pomodoro icons"
    echo "  Font Logos              ~50    Linux distro & brand logos"
    echo
    echo "  Source glyphs stored in: FontPatcher/src/glyphs/"
}

# ============================================================================
# Usage
# ============================================================================

usage() {
    cat << 'EOF'
Usage: patch-font.sh [OPTIONS] <font-file>

Patch any TTF/OTF font with the full Nerd Fonts glyph set.

Options:
    --mono              Force monospace (single-width) patched glyphs
    --install           Install the patched font after patching
    --output DIR        Output directory (default: ./patched-fonts/)
    --glyphs            Show available glyph sets
    -h, --help          Show this help

Examples:
    # Patch a font with all Nerd Font glyphs
    ./scripts/patch-font.sh ~/Downloads/FiraCode-Regular.ttf

    # Patch as monospace and auto-install
    ./scripts/patch-font.sh --mono --install ~/Downloads/FiraCode-Regular.ttf

    # Custom output directory
    ./scripts/patch-font.sh --output ~/my-fonts ~/Downloads/MyFont.otf

What this does:
    Takes any regular font and injects 9000+ glyphs from Nerd Fonts,
    including Powerline symbols, Devicons, Font Awesome, Material Design
    icons, and more. The patched font works with PowerLevel10k, Oh My Zsh,
    Starship, and any other tool that expects Nerd Font glyphs.

Requires:
    fontforge — Install with: brew install fontforge

EOF
}

# ============================================================================
# Main
# ============================================================================

main() {
    local font_file=""
    local output_dir="$DEFAULT_OUTPUT"
    local mono="false"
    local do_install="false"
    local extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mono)
                mono="true"
                shift
                ;;
            --install)
                do_install="true"
                shift
                ;;
            --output)
                [[ -z "${2:-}" ]] && { log_error "--output requires a directory"; exit 1; }
                output_dir="$2"
                shift 2
                ;;
            --glyphs)
                show_glyph_sets
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                extra_args+=("$@")
                break
                ;;
            -*)
                # Pass unknown flags through to font-patcher
                extra_args+=("$1")
                shift
                ;;
            *)
                if [[ -z "$font_file" ]]; then
                    font_file="$1"
                else
                    extra_args+=("$1")
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$font_file" ]]; then
        usage
        exit 1
    fi

    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║          Nerd Fonts Patcher — Glyph Injector               ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo

    ensure_fontforge || exit 1

    patch_font "$font_file" "$output_dir" "$mono" "${extra_args[@]+"${extra_args[@]}"}" || exit 1

    if [[ "$do_install" == "true" ]]; then
        echo
        install_patched_fonts "$output_dir"
    else
        echo
        log_info "To install the patched font, run:"
        echo "  ./scripts/patch-font.sh --install --output \"$output_dir\" \"$font_file\""
        echo "  — or —"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            echo "  cp \"$output_dir\"/*.ttf ~/Library/Fonts/"
        else
            echo "  cp \"$output_dir\"/*.ttf ~/.local/share/fonts/ && fc-cache -f"
        fi
    fi
}

main "$@"
