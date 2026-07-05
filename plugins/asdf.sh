#!/usr/bin/env bash
# Plugin: asdf
# Universal Version Manager Plugin

# ============================================================================
# Plugin Metadata
# ============================================================================

asdf_info() {
    echo "asdf v1.0.0 - Universal version manager for multiple languages"
}

# ============================================================================
# Core Functions
# ============================================================================

asdf_init() {
    export ASDF_DIR="${ASDF_DIR:-$HOME/.asdf}"
    export ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}"
    return 0
}

asdf_detect() {
    command -v asdf >/dev/null 2>&1
}

asdf_install() {
    echo "Installing asdf..."

    if asdf_detect; then
        echo "asdf is already installed"
        return 0
    fi

    local os_type
    os_type=$(uname -s)

    case "$os_type" in
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                brew install asdf
            else
                git clone https://github.com/asdf-vm/asdf.git "$ASDF_DIR" --branch v0.13.1
            fi
            ;;
        Linux)
            git clone https://github.com/asdf-vm/asdf.git "$ASDF_DIR" --branch v0.13.1
            ;;
        *)
            echo "Unsupported OS: $os_type"
            return 1
            ;;
    esac

    echo "asdf installed successfully"
    echo "Add to your shell: source \$HOME/.asdf/asdf.sh"
    return 0
}

asdf_version() {
    if asdf_detect; then
        asdf version 2>/dev/null || echo "unknown"
    else
        echo "not installed"
        return 1
    fi
}

asdf_list() {
    if ! asdf_detect; then
        echo "asdf not installed"
        return 1
    fi

    echo "Installed plugins:"
    asdf plugin list 2>/dev/null || echo "  (none)"
    echo
    echo "Current versions:"
    asdf current 2>/dev/null || echo "  (none set)"
}

asdf_use() {
    local plugin="$1"
    local version="$2"

    if ! asdf_detect; then
        echo "asdf not installed"
        return 1
    fi

    if [[ -z "$plugin" ]] || [[ -z "$version" ]]; then
        echo "Usage: asdf_use <plugin> <version>"
        echo "Example: asdf_use nodejs 20.10.0"
        return 1
    fi

    # Check if plugin is installed
    if ! asdf plugin list 2>/dev/null | grep -q "^${plugin}$"; then
        echo "Plugin $plugin not installed. Installing..."
        asdf plugin add "$plugin" || return 1
    fi

    # Check if version is installed
    if ! asdf list "$plugin" 2>/dev/null | grep -q "$version"; then
        echo "Version $version not installed. Installing..."
        asdf install "$plugin" "$version" || return 1
    fi

    asdf global "$plugin" "$version"
    echo "Now using $plugin $version"
}

asdf_cleanup() {
    return 0
}

# ============================================================================
# Additional Functions
# ============================================================================

# Add a plugin
asdf_plugin_add() {
    local plugin="$1"

    if ! asdf_detect; then
        echo "asdf not installed"
        return 1
    fi

    asdf plugin add "$plugin"
}

# Install a version
asdf_install_version() {
    local plugin="$1"
    local version="$2"

    if ! asdf_detect; then
        echo "asdf not installed"
        return 1
    fi

    asdf install "$plugin" "$version"
}

# List available plugins
asdf_plugin_list_all() {
    if ! asdf_detect; then
        echo "asdf not installed"
        return 1
    fi

    echo "Available plugins (showing first 20):"
    asdf plugin list all 2>/dev/null | head -20
    echo "..."
    echo "Run 'asdf plugin list all' for complete list"
}

# ============================================================================
# Project Detection
# ============================================================================

asdf_is_asdf_project() {
    [[ -f ".tool-versions" ]]
}

# ============================================================================
# Standard Plugin Interface
# ============================================================================

plugin_info() { asdf_info; }
plugin_init() { asdf_init; }
plugin_detect() { asdf_detect; }
plugin_install() { asdf_install; }
plugin_version() { asdf_version; }
plugin_list() { asdf_list; }
plugin_use() { asdf_use "$@"; }
plugin_cleanup() { asdf_cleanup; }
