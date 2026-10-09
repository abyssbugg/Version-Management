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
#
# M4 adopter (P3-1, AX-6c): the --install font FILE copies (macOS
# ~/Library/Fonts, Linux ~/.local/share/fonts) run under a backup
# transaction (lib/backup.sh) — hash-verified rollback on failure,
# byte-compare idempotency (an unchanged font writes nothing, no mtime
# churn), atomic same-directory publish, and --dry-run planning with zero
# writes. Mirrors setup-fonts-enhanced.sh install_local_fonts.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHER_DIR="$SCRIPT_DIR/FontPatcher"
PATCHER="$PATCHER_DIR/font-patcher"
DEFAULT_OUTPUT="$SCRIPT_DIR/patched-fonts"

# Library paths resolve through a PRIVATE name — sourced libraries may reuse
# common global names, so the adopter never relies on SCRIPT_DIR for them
# (M4 lesson, setup-fonts-enhanced.sh).
_VMS_PATCH_FONT_ROOT="$SCRIPT_DIR"

# Source logging (with fallback)
if [[ -f "$SCRIPT_DIR/lib/logger.sh" ]]; then
    source "$SCRIPT_DIR/lib/logger.sh"
else
    log_info() { echo "[INFO]    $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warn() { echo "[WARN]    $*"; }
    log_error() { echo "[ERROR]   $*" >&2; }
fi

# Backup transactions + portable byte-compare for the --install copies.
source "$_VMS_PATCH_FONT_ROOT/lib/backup.sh"
source "$_VMS_PATCH_FONT_ROOT/lib/mutation.sh"

# ============================================================================
# Dependency Management
# ============================================================================

ensure_fontforge() {
    # Dry-run: plan only — never execute FontForge (its startup may write
    # preference files under HOME) and never prompt for or run an install.
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        if command -v fontforge >/dev/null 2>&1; then
            log_info "[dry-run] FontForge detected: $(command -v fontforge) (not executed)"
        elif command -v brew >/dev/null 2>&1; then
            log_info "[dry-run] FontForge is not installed — apply mode would offer to run: brew install fontforge"
        else
            log_info "[dry-run] FontForge is not installed — apply mode would require a manual install (see --help)"
        fi
        return 0
    fi

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
        ttf | otf | woff | woff2 | sfd) ;;
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

    # The output directory is created only in apply mode — dry-run plans it.
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        if [[ ! -d "$output_dir" ]]; then
            log_info "[dry-run] would create output directory: $output_dir"
        fi
    else
        mkdir -p "$output_dir"
    fi

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

    # Dry-run: font patching is NOT executed — print the exact planned
    # command (shell-quoted, copy-pastable) instead.
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        local planned
        planned=$(printf '%q ' "${cmd[@]}")
        echo
        log_info "[dry-run] Font patching NOT executed — planned command:"
        echo "  ${planned% }"
        return 0
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

# Install patched fonts — the FILE mutations of --install.
# Adoption (P3-1, AX-6c) mirrors setup-fonts-enhanced.sh install_local_fonts:
# one transaction ("patch_font_install"); each target font is registered with
# the transaction BEFORE any mutation so rollback restores (or removes) the
# pre-state byte-identically; an unchanged font writes nothing (byte-compare
# idempotency, no mtime churn); each copy is atomic (temp file in the
# destination directory + rename, source mode preserved). Any failure rolls
# the whole install back and returns non-zero. Dry-run plans, zero writes.
install_patched_fonts() (
    # Serialize with the other workstation mutators; confine the trap to this
    # operation (subshell) so a sourcing caller does not retain the lock.
    if [[ "${TRANSACTION_DRY_RUN:-0}" != 1 ]]; then
        source "$_VMS_PATCH_FONT_ROOT/lib/lock.sh"
        lock_with_trap workstation-mutation 30 || return 1
    fi
    _install_patched_fonts_locked "$@"
)

_install_patched_fonts_locked() {
    local source_dir="$1"
    local dry_run=0
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        dry_run=1
    fi

    if [[ ! -d "$source_dir" ]]; then
        if [[ "$dry_run" -eq 1 ]]; then
            log_info "[dry-run] No patched font files to plan: $source_dir does not exist (patching is planned, not executed)"
            return 0
        fi
        log_error "Directory not found: $source_dir"
        return 1
    fi

    # NUL-safe collection (names may contain spaces, glob characters or
    # newlines); C-locale sorted for a deterministic install order.
    local font_files=() font
    while IFS= read -r -d '' font; do
        font_files+=("$font")
    done < <(find "$source_dir" -maxdepth 1 \( -name "*.ttf" -o -name "*.otf" \) -print0 2>/dev/null | LC_ALL=C sort -z)

    if [[ ${#font_files[@]} -eq 0 ]]; then
        if [[ "$dry_run" -eq 1 ]]; then
            log_info "[dry-run] No patched font files found in $source_dir — nothing to plan for install (patching is planned, not executed)"
            return 0
        fi
        log_warn "No patched font files found in $source_dir"
        return 1
    fi

    local dest_dir
    if [[ "$OSTYPE" == "darwin"* ]]; then
        dest_dir="$HOME/Library/Fonts"
    else
        dest_dir="$HOME/.local/share/fonts"
    fi

    # Target directory is idempotent infrastructure; created only in apply
    # mode — dry-run plans it instead (zero writes).
    if [[ ! -d "$dest_dir" ]]; then
        if [[ "$dry_run" -eq 1 ]]; then
            log_info "[dry-run] would create font directory: $dest_dir"
        elif ! mkdir -p "$dest_dir"; then
            log_error "Cannot create font directory: $dest_dir"
            return 1
        fi
    fi

    transaction_start "patch_font_install" || return 1

    local installed=0 unchanged=0 failed=0 name target tmp mode
    for font in "${font_files[@]}"; do
        name="${font##*/}"
        target="$dest_dir/$name"

        # Register BEFORE any mutation so rollback removes/restores the
        # pre-state (new installs are removed; replaced fonts are restored).
        if ! transaction_add_file "$target"; then
            failed=1
            break
        fi

        # Idempotency: an unchanged font writes nothing (portable
        # byte-compare — degrades to sha256 on hosts without cmp).
        if [[ -f "$target" ]] && mutation_files_identical "$font" "$target"; then
            log_info "Already installed (identical, unchanged): $name"
            unchanged=$((unchanged + 1))
            continue
        fi

        if [[ "$dry_run" -eq 1 ]]; then
            log_info "[dry-run] would install: $target (source: $font)"
            installed=$((installed + 1))
            continue
        fi

        # Atomic: same-directory temp + rename; the source font's mode is
        # preserved (GNU-first stat probing — on Linux, BSD stat -f means
        # filesystem info and exits 0 with wrong data). -L: the mode of the
        # content cp actually copies, never a symlink's own (e.g. 777) mode.
        tmp=$(mktemp "$dest_dir/.vms-font.XXXXXX") || {
            failed=1
            break
        }
        if ! cp "$font" "$tmp"; then
            rm -f "$tmp"
            failed=1
            break
        fi
        mode=$(stat -L -c '%a' "$font" 2>/dev/null || stat -L -f '%Lp' "$font" 2>/dev/null || echo 644)
        chmod "$mode" "$tmp" 2>/dev/null || true
        if ! mv "$tmp" "$target"; then
            rm -f "$tmp"
            failed=1
            break
        fi
        log_success "Installed: $name → $dest_dir/"
        installed=$((installed + 1))
    done

    if [[ "$failed" -ne 0 ]]; then
        transaction_rollback || log_error "Rollback reported errors — inspect $HOME/.config-backups/transactions"
        log_error "Font installation FAILED — rolled back"
        return 1
    fi

    transaction_commit

    if [[ "$dry_run" -eq 1 ]]; then
        log_success "Dry-run complete — $installed font file(s) planned, $unchanged already identical, zero writes"
        return 0
    fi

    if [[ "$installed" -eq 0 ]]; then
        log_info "No font files needed installing — $unchanged already identical in $dest_dir"
        return 0
    fi

    # Refresh font cache on Linux (apply mode only — a cache rewrite is a
    # filesystem side effect dry-run must not perform)
    if [[ "$OSTYPE" == "linux-gnu"* ]] && command -v fc-cache >/dev/null 2>&1; then
        log_info "Refreshing font cache..."
        fc-cache -f >/dev/null 2>&1 || true
    fi

    log_success "$installed font(s) installed to $dest_dir"
    if [[ "$unchanged" -gt 0 ]]; then
        log_info "$unchanged font(s) already identical — left unchanged"
    fi
    log_info "Restart your terminal or applications to use the new font."
    return 0
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
    cat <<'EOF'
Usage: patch-font.sh [OPTIONS] <font-file>

Patch any TTF/OTF font with the full Nerd Fonts glyph set.

Options:
    --mono              Force monospace (single-width) patched glyphs
    --install           Install the patched font after patching
    --output DIR        Output directory (default: ./patched-fonts/)
    --dry-run           Plan only: print the font-patcher command (and, with
                        --install, the install plan for font files already
                        in the output directory) — zero filesystem writes
    --glyphs            Show available glyph sets
    -h, --help          Show this help

Examples:
    # Patch a font with all Nerd Font glyphs
    ./scripts/patch-font.sh ~/Downloads/FiraCode-Regular.ttf

    # Patch as monospace and auto-install
    ./scripts/patch-font.sh --mono --install ~/Downloads/FiraCode-Regular.ttf

    # Custom output directory
    ./scripts/patch-font.sh --output ~/my-fonts ~/Downloads/MyFont.otf

    # Preview the patch command and install plan without writing anything
    ./scripts/patch-font.sh --dry-run --install ~/Downloads/FiraCode-Regular.ttf

What this does:
    Takes any regular font and injects 9000+ glyphs from Nerd Fonts,
    including Powerline symbols, Devicons, Font Awesome, Material Design
    icons, and more. The patched font works with PowerLevel10k, Oh My Zsh,
    Starship, and any other tool that expects Nerd Font glyphs.

    --install copies the patched fonts into your user font directory under
    a backup transaction: a same-named font you already have is backed up
    and restored if any copy fails; identical fonts are left untouched.

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
            --dry-run)
                TRANSACTION_DRY_RUN=1
                export TRANSACTION_DRY_RUN
                shift
                ;;
            --output)
                [[ -z "${2:-}" ]] && {
                    log_error "--output requires a directory"
                    exit 1
                }
                output_dir="$2"
                shift 2
                ;;
            --glyphs)
                show_glyph_sets
                exit 0
                ;;
            -h | --help)
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

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "DRY-RUN MODE — planning only, zero filesystem writes (no patching, no install)"
        echo
    fi

    ensure_fontforge || exit 1

    patch_font "$font_file" "$output_dir" "$mono" "${extra_args[@]+"${extra_args[@]}"}" || exit 1

    if [[ "$do_install" == "true" ]]; then
        echo
        install_patched_fonts "$output_dir" || exit 1
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

# Run only when executed directly — sourcing (tests) defines the functions
# without running main.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
