#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source paths; SC2034: intentionally exported vars

# Theme Management Operations Library Module
# Part of Professional Development Terminal Setup
# Provides standardized theme management interface for Powerlevel10k themes
# Integrates with foundational libraries for caching, logging, and environment setup

# Source foundational libraries
THEME_OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${THEME_OPS_DIR}/env.sh"
source "${THEME_OPS_DIR}/cache.sh"
source "${THEME_OPS_DIR}/logger.sh"

# Theme management configuration
THEME_CACHE_PREFIX="theme"
THEME_CACHE_TTL=600  # 10 minutes cache for theme file checks
P10K_CONFIG="$HOME/.p10k.zsh"
THEME_BASE_DIR="$(dirname "$THEME_OPS_DIR")"  # Parent directory of lib/

# Theme configuration using parallel arrays for Bash 3.x compatibility
THEME_NAMES=("professional" "apple" "minimal" "rainbow")
THEME_FILES=("professional-dev-p10k.zsh" "apple-style-p10k.zsh" "minimal-p10k.zsh" "rainbow-p10k.zsh")
THEME_DESCRIPTIONS=(
    "Professional development theme with version info"
    "Apple-inspired clean theme"
    "Minimal distraction-free theme"
    "Colorful rainbow theme"
)

# Helper function to get theme file by name
get_theme_file() {
    local theme_name="$1"
    local i
    for i in "${!THEME_NAMES[@]}"; do
        if [[ "${THEME_NAMES[$i]}" == "$theme_name" ]]; then
            echo "${THEME_FILES[$i]}"
            return 0
        fi
    done
    return 1
}

# Helper function to get theme description by name
get_theme_description() {
    local theme_name="$1"
    local i
    for i in "${!THEME_NAMES[@]}"; do
        if [[ "${THEME_NAMES[$i]}" == "$theme_name" ]]; then
            echo "${THEME_DESCRIPTIONS[$i]}"
            return 0
        fi
    done
    return 1
}

# ============================================================================
# THEME VALIDATION AND DETECTION
# ============================================================================

# Validate that a theme exists and is available
# Args: theme_name - name of the theme to validate
# Returns: 0 if theme exists, 1 if not
theme_validate() {
    local theme_name="$1"

    if [ -z "$theme_name" ]; then
        log_error "Theme name not specified"
        return 1
    fi

    log_debug "Validating theme: $theme_name"

    # Check if theme is in our known themes
    local theme_file
    if ! theme_file=$(get_theme_file "$theme_name"); then
        log_error "Unknown theme: $theme_name"
        return 1
    fi
    local theme_path="$THEME_BASE_DIR/$theme_file"

    # Use caching for file existence checks
    local cache_key="${THEME_CACHE_PREFIX}_exists_${theme_name}"
    local cached_result

    if cached_result=$(cache_get "$cache_key"); then
        log_debug "Using cached theme validation result for $theme_name"
        [ "$cached_result" = "true" ] && return 0 || return 1
    fi

    # Check if theme file exists
    if [ -f "$theme_path" ]; then
        log_debug "Theme file found: $theme_path"
        cache_set "$cache_key" "true" "$THEME_CACHE_TTL"
        return 0
    else
        log_error "Theme config file not found: $theme_path"
        log_error "Available themes with installed configs:"
        for i in "${!THEME_NAMES[@]}"; do
            local tfile="$THEME_BASE_DIR/${THEME_FILES[$i]}"
            if [ -f "$tfile" ]; then
                log_error "  ✓ ${THEME_NAMES[$i]}"
            else
                log_error "  ✗ ${THEME_NAMES[$i]} (missing: $tfile)"
            fi
        done
        log_error "To use theme '${theme_name}', create the config file at: $theme_path"
        log_error "Alternatively, use: ./setup-theme.sh professional"
        cache_set "$cache_key" "false" "$THEME_CACHE_TTL"
        return 1
    fi
}

# Detect currently active theme
# Returns: theme name if detected, "unknown" if not recognized
theme_detect_current() {
    log_debug "Detecting current theme"

    if [ ! -f "$P10K_CONFIG" ]; then
        log_warn "No Powerlevel10k configuration file found"
        echo "none"
        return 1
    fi

    # Check for theme signatures in the config file
    if grep -q "Professional Development" "$P10K_CONFIG" 2>/dev/null; then
        echo "professional"
        return 0
    elif grep -q "Apple-Style Powerlevel10k" "$P10K_CONFIG" 2>/dev/null; then
        echo "apple"
        return 0
    elif grep -q "Clean Gradient Powerlevel10k" "$P10K_CONFIG" 2>/dev/null; then
        echo "clean"
        return 0
    elif grep -q "VS Code Professional" "$P10K_CONFIG" 2>/dev/null; then
        echo "vscode"
        return 0
    else
        echo "unknown"
        return 1
    fi
}

# ============================================================================
# THEME OPERATIONS
# ============================================================================

# Switch to specified theme
# Args: theme_name - name of the theme to switch to
# Returns: 0 on success, 1 on failure
theme_switch() {
    local theme_name="$1"

    if [ -z "$theme_name" ]; then
        log_error "Theme name not specified"
        return 1
    fi

    log_info "Switching to theme: $theme_name"

    # Validate theme exists
    if ! theme_validate "$theme_name"; then
        return 1
    fi

    local theme_file
    theme_file=$(get_theme_file "$theme_name") || return 1
    local theme_path="$THEME_BASE_DIR/$theme_file"

    # Create backup before switching (handled by backup.sh)
    if command -v create_backup >/dev/null 2>&1; then
        create_backup "$P10K_CONFIG"
    fi

    # Copy theme file to P10K config location
    if cp "$theme_path" "$P10K_CONFIG" 2>/dev/null; then
        log_success "Theme '$theme_name' applied successfully"
        log_info "Restart your terminal or run 'source ~/.zshrc' to apply changes"

        # Add specific instructions for certain themes
        case "$theme_name" in
            "professional"|"vscode")
                log_info "Make sure you have a Nerd Font installed for best experience"
                ;;
        esac

        return 0
    else
        log_error "Failed to apply theme '$theme_name'"
        return 1
    fi
}

# Generate theme preview
# Args: theme_name - name of the theme to preview
# Returns: 0 on success, 1 on failure
theme_preview() {
    local theme_name="$1"

    if [ -z "$theme_name" ]; then
        log_error "Theme name not specified"
        return 1
    fi

    log_info "Generating preview for theme: $theme_name"

    # Validate theme exists
    if ! theme_validate "$theme_name"; then
        return 1
    fi

    echo "Theme Preview: $theme_name"
    echo "=========================="
    echo
    echo "Description: ${THEME_DESCRIPTIONS[$theme_name]}"
    echo

    case "$theme_name" in
        "professional")
            echo "Professional Development Theme:"
            echo "  • OS Icon: 🍎 (Nerd Font Apple logo)"
            echo "  • Directory: ~/projects/my-app"
            echo "  • Git Status:  main ✓"
            echo "  • Python:  3.12.8"
            echo "  • Node.js:  20.19.2"
            echo "  • Project:    "
            ;;
        "apple")
            echo "Apple Style Theme:"
            echo "  • OS Icon: ue711"
            echo "  • Directory: ~/projects/my-app"
            echo "  • Git Status:  main"
            echo "  • Python:  3.12.8"
            echo "  • Node.js: uf12e 20.19.2"
            ;;
        "clean")
            echo "Clean Gradient Theme:"
            echo "  • Directory: ~/projects/my-app"
            echo "  • Git Status:  main"
            echo "  • Python: 3.12.8"
            echo "  • Node.js: 20.19.2"
            ;;
        "vscode")
            echo "VS Code Professional Theme:"
            echo "  • OS Icon:  (Nerd Font)"
            echo "  • Directory: ~/projects/my-app"
            echo "  • Git Status:  main ✓"
            echo "  • Python:  3.12.8"
            echo "  • Node.js:  20.19.2"
            echo "  • Optimized for VS Code terminal"
            ;;
        *)
            echo "Preview not available for theme: $theme_name"
            return 1
            ;;
    esac

    return 0
}

# List all available themes
# Returns: 0 on success
theme_list_available() {
    log_debug "Listing available themes"

    echo "Available Themes"
    echo "================"
    echo

    local theme_count=0
    for theme_name in "${THEME_NAMES[@]}"; do
        local theme_file
        theme_file=$(get_theme_file "$theme_name") || continue
        local theme_path="$THEME_BASE_DIR/$theme_file"
        local description
        description=$(get_theme_description "$theme_name") || description="No description"

        if [ -f "$theme_path" ]; then
            echo "  ✓ $theme_name - $description"
            ((theme_count++))
        else
            echo "  ✗ $theme_name - $description (file not found)"
        fi
    done

    echo
    echo "Total available themes: $theme_count"

    # Show current theme
    local current_theme=$(theme_detect_current)
    if [ "$current_theme" != "none" ] && [ "$current_theme" != "unknown" ]; then
        echo "Current theme: $current_theme"
    elif [ "$current_theme" = "unknown" ]; then
        echo "Current theme: Custom or Unknown"
    else
        echo "Current theme: None (no configuration found)"
    fi

    return 0
}

# ============================================================================
# THEME INFORMATION AND UTILITIES
# ============================================================================

# Get theme file path
# Args: theme_name - name of the theme
# Returns: theme file path if exists
theme_get_file_path() {
    local theme_name="$1"

    if [ -z "$theme_name" ]; then
        log_error "Theme name not specified"
        return 1
    fi

    local theme_file
    if ! theme_file=$(get_theme_file "$theme_name"); then
        log_error "Unknown theme: $theme_name"
        return 1
    fi
    local theme_path="$THEME_BASE_DIR/$theme_file"

    echo "$theme_path"
    return 0
}

# Get theme description
# Args: theme_name - name of the theme
# Returns: theme description
theme_get_description() {
    local theme_name="$1"

    if [ -z "$theme_name" ]; then
        log_error "Theme name not specified"
        return 1
    fi

    if [[ -z "${THEME_DESCRIPTIONS[$theme_name]:-}" ]]; then
        log_error "Unknown theme: $theme_name"
        return 1
    fi

    echo "${THEME_DESCRIPTIONS[$theme_name]}"
    return 0
}

# Check if theme requires Nerd Font
# Args: theme_name - name of the theme
# Returns: 0 if Nerd Font required, 1 if not
theme_requires_nerd_font() {
    local theme_name="$1"

    case "$theme_name" in
        "professional"|"vscode")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Get current theme information
# Returns: detailed information about current theme
theme_get_current_info() {
    log_debug "Getting current theme information"

    if [ ! -f "$P10K_CONFIG" ]; then
        echo "No Powerlevel10k configuration found"
        return 1
    fi

    echo "Current Configuration"
    echo "===================="
    echo "Configuration file: $P10K_CONFIG"
    echo "Last modified: $(stat -f %Sm "$P10K_CONFIG" 2>/dev/null || stat -c %y "$P10K_CONFIG" 2>/dev/null)"
    echo "File size: $(wc -l < "$P10K_CONFIG") lines"
    echo

    local current_theme=$(theme_detect_current)
    case "$current_theme" in
        "professional")
            echo "Current theme: Professional Development"
            echo "Features: Nerd Font icons, sophisticated colors, project-aware"
            ;;
        "apple")
            echo "Current theme: Apple Style"
            echo "Features: Apple emoji, basic colors, simple layout"
            ;;
        "clean")
            echo "Current theme: Clean Gradient"
            echo "Features: Minimal design, gradient colors, essential elements"
            ;;
        "vscode")
            echo "Current theme: VS Code Professional"
            echo "Features: VS Code optimized, Nerd Font icons, professional layout"
            ;;
        "unknown")
            echo "Current theme: Custom or Unknown"
            echo "This may be a custom configuration or default p10k setup"
            ;;
        "none")
            echo "Current theme: None"
            echo "No Powerlevel10k configuration detected"
            ;;
    esac

    # Check for Nerd Font requirement
    if theme_requires_nerd_font "$current_theme"; then
        echo "Font requirement: Nerd Font (for proper icon display)"
    fi

    return 0
}

# Reset theme configuration
# Returns: 0 on success, 1 on failure
theme_reset() {
    log_info "Resetting theme configuration"

    # Create backup before reset
    if command -v create_backup >/dev/null 2>&1; then
        create_backup "$P10K_CONFIG"
    fi

    if rm -f "$P10K_CONFIG" 2>/dev/null; then
        log_success "Theme configuration reset"
        log_info "Restart your terminal or run 'p10k configure' to set up"
        return 0
    else
        log_error "Failed to reset theme configuration"
        return 1
    fi
}

# Export functions for external use
export -f theme_validate theme_detect_current theme_switch theme_preview
export -f theme_list_available theme_get_file_path theme_get_description
export -f theme_requires_nerd_font theme_get_current_info theme_reset
