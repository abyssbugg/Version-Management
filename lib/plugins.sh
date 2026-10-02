#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# ============================================================================
# Plugin System
# Part of Professional Development Terminal Setup
# ============================================================================
# Provides a modular plugin architecture for extending the suite with
# additional version managers, tools, and functionality.
# ============================================================================

# Prevent re-sourcing
[[ -n "${_PLUGINS_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_PLUGINS_SH_LOADED=1

# Contract (directive A2/M1): this file is SOURCED — it must not set global
# shell options; callers own their strict-mode posture. Argument validation
# and error propagation are explicit inside library functions.

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/logger.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo "[DEBUG] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
}

# ============================================================================
# Configuration
# ============================================================================

# Plugin directories
PLUGIN_DIR="${PLUGIN_DIR:-$SCRIPT_DIR/../plugins}"
PLUGIN_ENABLED_DIR="${PLUGIN_ENABLED_DIR:-$HOME/.config/version-manager/plugins}"

# Plugin registry - requires bash 4+ for associative arrays
_PLUGINS_HAS_ASSOC=false
if (( ${BASH_VERSINFO[0]:-0} >= 4 )); then
    _PLUGINS_HAS_ASSOC=true
    declare -gA LOADED_PLUGINS 2>/dev/null || declare -A LOADED_PLUGINS
    declare -gA PLUGIN_METADATA 2>/dev/null || declare -A PLUGIN_METADATA
fi

# ============================================================================
# Plugin Interface Definition
# ============================================================================
# Each plugin must implement these functions:
#
#   plugin_info()     - Return plugin metadata (name, version, description)
#   plugin_init()     - Initialize the plugin
#   plugin_detect()   - Check if the tool is available
#   plugin_install()  - Install the tool
#   plugin_version()  - Get current version
#   plugin_list()     - List available versions
#   plugin_use()      - Switch to a version
#
# Optional functions:
#   plugin_cleanup()  - Cleanup resources
#   plugin_update()   - Update the tool
#   plugin_uninstall() - Remove the tool
# ============================================================================

# ============================================================================
# Plugin Loader
# ============================================================================

# Initialize plugin system
plugin_system_init() {
    log_debug "Initializing plugin system..."

    # Create plugin directories if needed
    mkdir -p "$PLUGIN_DIR"
    mkdir -p "$PLUGIN_ENABLED_DIR"

    # Load enabled plugins
    plugin_load_all

    log_debug "Plugin system initialized"
}

# Load a single plugin
# Usage: plugin_load "/path/to/plugin.sh"
plugin_load() {
    local plugin_path="$1"

    if [[ ! -f "$plugin_path" ]]; then
        log_error "Plugin not found: $plugin_path"
        return 1
    fi

    local plugin_name
    plugin_name=$(basename "$plugin_path" .sh)

    # Check if already loaded
    if [[ -n "${LOADED_PLUGINS[$plugin_name]:-}" ]]; then
        log_debug "Plugin already loaded: $plugin_name"
        return 0
    fi

    log_debug "Loading plugin: $plugin_name"

    # Source the plugin
    # shellcheck source=/dev/null
    if ! source "$plugin_path"; then
        log_error "Failed to load plugin: $plugin_name"
        return 1
    fi

    # Verify required functions exist
    if ! declare -f plugin_info >/dev/null 2>&1; then
        log_error "Plugin missing required function: plugin_info"
        return 1
    fi

    # Get plugin metadata
    local info
    info=$(plugin_info)
    PLUGIN_METADATA[$plugin_name]="$info"

    # Initialize the plugin
    if declare -f plugin_init >/dev/null 2>&1; then
        if ! plugin_init; then
            log_warn "Plugin initialization returned non-zero: $plugin_name"
        fi
    fi

    LOADED_PLUGINS[$plugin_name]="$plugin_path"
    log_debug "Plugin loaded successfully: $plugin_name"
    return 0
}

# Load all enabled plugins
plugin_load_all() {
    local count=0

    # Load from main plugin directory
    if [[ -d "$PLUGIN_DIR" ]]; then
        for plugin in "$PLUGIN_DIR"/*.sh; do
            if [[ -f "$plugin" ]]; then
                plugin_load "$plugin" && count=$((count + 1))
            fi
        done
    fi

    # Load from user plugin directory
    if [[ -d "$PLUGIN_ENABLED_DIR" ]]; then
        for plugin in "$PLUGIN_ENABLED_DIR"/*.sh; do
            if [[ -f "$plugin" ]]; then
                plugin_load "$plugin" && count=$((count + 1))
            fi
        done
    fi

    log_debug "Loaded $count plugins"
}

# Unload a plugin
# Usage: plugin_unload "plugin_name"
plugin_unload() {
    local plugin_name="$1"

    if [[ -z "${LOADED_PLUGINS[$plugin_name]:-}" ]]; then
        log_debug "Plugin not loaded: $plugin_name"
        return 0
    fi

    # Call cleanup if available
    if declare -f plugin_cleanup >/dev/null 2>&1; then
        plugin_cleanup
    fi

    # Remove from registry
    unset "LOADED_PLUGINS[$plugin_name]"
    unset "PLUGIN_METADATA[$plugin_name]"

    log_debug "Plugin unloaded: $plugin_name"
}

# ============================================================================
# Plugin Discovery
# ============================================================================

# List all available plugins
plugin_list_available() {
    echo "Available Plugins:"
    echo "=================="
    echo

    local found=0

    # Check main plugin directory
    if [[ -d "$PLUGIN_DIR" ]]; then
        for plugin in "$PLUGIN_DIR"/*.sh; do
            if [[ -f "$plugin" ]]; then
                local name
                name=$(basename "$plugin" .sh)
                local status="available"
                $_PLUGINS_HAS_ASSOC && [[ -n "${LOADED_PLUGINS[$name]:-}" ]] && status="loaded"
                echo "  - $name ($status)"
                found=$((found + 1))
            fi
        done
    fi

    # Check user plugin directory
    if [[ -d "$PLUGIN_ENABLED_DIR" ]]; then
        for plugin in "$PLUGIN_ENABLED_DIR"/*.sh; do
            if [[ -f "$plugin" ]]; then
                local name
                name=$(basename "$plugin" .sh)
                local status="available"
                $_PLUGINS_HAS_ASSOC && [[ -n "${LOADED_PLUGINS[$name]:-}" ]] && status="loaded"
                echo "  - $name [user] ($status)"
                found=$((found + 1))
            fi
        done
    fi

    if [[ $found -eq 0 ]]; then
        echo "  No plugins found"
        echo
        echo "  Plugin directories:"
        echo "    System: $PLUGIN_DIR"
        echo "    User:   $PLUGIN_ENABLED_DIR"
    fi
    echo
}

# List loaded plugins
plugin_list_loaded() {
    echo "Loaded Plugins:"
    echo "==============="
    echo

    if ! $_PLUGINS_HAS_ASSOC || [[ ${#LOADED_PLUGINS[@]} -eq 0 ]]; then
        echo "  No plugins loaded"
        return
    fi

    for name in "${!LOADED_PLUGINS[@]}"; do
        local info="${PLUGIN_METADATA[$name]:-No info}"
        echo "  - $name: $info"
    done
    echo
}

# ============================================================================
# Plugin Execution
# ============================================================================

# Run a plugin function
# Usage: plugin_run "plugin_name" "function_name" [args...]
plugin_run() {
    local plugin_name="$1"
    local func_name="$2"
    shift 2

    if [[ -z "${LOADED_PLUGINS[$plugin_name]:-}" ]]; then
        log_error "Plugin not loaded: $plugin_name"
        return 1
    fi

    local full_func="${plugin_name}_${func_name}"

    if ! declare -f "$full_func" >/dev/null 2>&1; then
        log_error "Plugin function not found: $full_func"
        return 1
    fi

    "$full_func" "$@"
}

# Check if a plugin provides a capability
# Usage: plugin_has_capability "plugin_name" "detect"
plugin_has_capability() {
    local plugin_name="$1"
    local capability="$2"

    local full_func="${plugin_name}_${capability}"
    declare -f "$full_func" >/dev/null 2>&1
}

# Check if a plugin is installed (file exists in plugin directories)
# Usage: is_plugin_installed "plugin_name"
is_plugin_installed() {
    local plugin_name="$1"
    [[ -f "$PLUGIN_DIR/${plugin_name}.sh" ]] || [[ -f "$PLUGIN_ENABLED_DIR/${plugin_name}.sh" ]]
}

# List all plugins (convenience wrapper)
list_plugins() {
    plugin_list_available
}

# ============================================================================
# Plugin Installation
# ============================================================================

# Install a plugin from a file
# Usage: plugin_install_from_file "/path/to/plugin.sh"
plugin_install_from_file() {
    local source_path="$1"
    local target_name="${2:-}"

    if [[ ! -f "$source_path" ]]; then
        log_error "Plugin file not found: $source_path"
        return 1
    fi

    if [[ -z "$target_name" ]]; then
        target_name=$(basename "$source_path")
    fi

    local target_path="$PLUGIN_ENABLED_DIR/$target_name"

    mkdir -p "$PLUGIN_ENABLED_DIR"
    cp "$source_path" "$target_path"
    chmod +x "$target_path"

    log_success "Plugin installed: $target_name"
    log_info "Reload plugins with: plugin_load_all"
}

# Remove an installed plugin
# Usage: plugin_remove "plugin_name"
plugin_remove() {
    local plugin_name="$1"

    # Unload first
    plugin_unload "$plugin_name"

    # Remove from user directory
    local plugin_path="$PLUGIN_ENABLED_DIR/${plugin_name}.sh"
    if [[ -f "$plugin_path" ]]; then
        rm -f "$plugin_path"
        log_success "Plugin removed: $plugin_name"
    else
        log_warn "Plugin file not found: $plugin_path"
    fi
}

# ============================================================================
# Plugin Template
# ============================================================================

# Generate a plugin template
# Usage: plugin_create_template "my_plugin"
plugin_create_template() {
    local plugin_name="$1"
    local output_path="${2:-$PLUGIN_ENABLED_DIR/${plugin_name}.sh}"

    if [[ -z "$plugin_name" ]]; then
        log_error "Plugin name required"
        return 1
    fi

    mkdir -p "$(dirname "$output_path")"

    cat > "$output_path" << 'TEMPLATE'
#!/usr/bin/env bash
# Plugin: PLUGIN_NAME
# Version Manager Plugin Template

# ============================================================================
# Required Functions
# ============================================================================

# Return plugin metadata
PLUGIN_NAME_info() {
    echo "PLUGIN_NAME v1.0.0 - Description of what this plugin does"
}

# Initialize the plugin (called on load)
PLUGIN_NAME_init() {
    # Setup code here
    return 0
}

# Check if the tool is available
PLUGIN_NAME_detect() {
    command -v TOOL_COMMAND >/dev/null 2>&1
}

# Install the tool
PLUGIN_NAME_install() {
    echo "Installing PLUGIN_NAME..."
    # Installation code here
    return 0
}

# Get current version
PLUGIN_NAME_version() {
    if PLUGIN_NAME_detect; then
        TOOL_COMMAND --version 2>/dev/null | head -1
    else
        echo "not installed"
        return 1
    fi
}

# List available/installed versions
PLUGIN_NAME_list() {
    echo "Available versions:"
    # List versions here
}

# Switch to a specific version
PLUGIN_NAME_use() {
    local version="$1"
    echo "Switching to version: $version"
    # Switch version here
}

# ============================================================================
# Optional Functions
# ============================================================================

# Cleanup on unload
PLUGIN_NAME_cleanup() {
    return 0
}

# Update the tool
PLUGIN_NAME_update() {
    echo "Updating PLUGIN_NAME..."
    return 0
}

# ============================================================================
# Standard Plugin Interface (required for plugin system)
# ============================================================================

plugin_info() { PLUGIN_NAME_info; }
plugin_init() { PLUGIN_NAME_init; }
plugin_detect() { PLUGIN_NAME_detect; }
plugin_install() { PLUGIN_NAME_install; }
plugin_version() { PLUGIN_NAME_version; }
plugin_list() { PLUGIN_NAME_list; }
plugin_use() { PLUGIN_NAME_use "$@"; }
plugin_cleanup() { PLUGIN_NAME_cleanup; }
TEMPLATE

    # Replace PLUGIN_NAME placeholder
    sed -i '' "s/PLUGIN_NAME/$plugin_name/g" "$output_path" 2>/dev/null || \
        sed -i "s/PLUGIN_NAME/$plugin_name/g" "$output_path"

    chmod +x "$output_path"

    log_success "Plugin template created: $output_path"
    log_info "Edit the file and replace TOOL_COMMAND with your tool's command"
}

# ============================================================================
# Export Functions
# ============================================================================

export -f plugin_system_init plugin_load plugin_load_all plugin_unload
export -f plugin_list_available plugin_list_loaded
export -f plugin_run plugin_has_capability
export -f plugin_install_from_file plugin_remove
export -f plugin_create_template
