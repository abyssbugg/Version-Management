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
_VMS_PLUGINS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_VMS_PLUGINS_DIR/logger.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo "[DEBUG] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
}

# B1.1: the plugin mutation paths depend on the shared validation foundation
# (identifier grammar, canonical containment). If it cannot be sourced,
# install fail-closed stubs — a plugin must never be written or removed
# through an unvalidated trust boundary.
if ! source "$_VMS_PLUGINS_DIR/validation.sh" 2>/dev/null; then
    log_error "plugins.sh: validation.sh unavailable — fail-closed stubs active"
    validate_identifier() { log_error "Validation unavailable — refusing plugin name: $1"; return 1; }
    path_validate_containment() { log_error "Validation unavailable — refusing path: $1"; return 1; }
    validate_safe_path() { log_error "Validation unavailable — refusing path: $1"; return 1; }
    _path_realpath() { return 1; }
fi

# ============================================================================
# Configuration
# ============================================================================

# Plugin directories
PLUGIN_DIR="${PLUGIN_DIR:-$_VMS_PLUGINS_DIR/../plugins}"
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

    # B1.1: registry keys are plugin names — apply the identifier grammar.
    if ! validate_identifier "$plugin_name"; then
        return 1
    fi

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

    # B1.1: both names are composed into a function identifier — grammar gate.
    if ! validate_identifier "$plugin_name"; then
        return 1
    fi
    if ! validate_identifier "$func_name"; then
        return 1
    fi

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

    # B1.1: same grammar gate as plugin_run (composed function identifier).
    if ! validate_identifier "$plugin_name" || ! validate_identifier "$capability"; then
        return 1
    fi

    local full_func="${plugin_name}_${capability}"
    declare -f "$full_func" >/dev/null 2>&1
}

# Check if a plugin is installed (file exists in plugin directories)
# Usage: is_plugin_installed "plugin_name"
is_plugin_installed() {
    local plugin_name="$1"
    # B1.1: a non-identifier can never denote an installed plugin.
    validate_identifier "$plugin_name" || return 1
    [[ -f "$PLUGIN_DIR/${plugin_name}.sh" ]] || [[ -f "$PLUGIN_ENABLED_DIR/${plugin_name}.sh" ]]
}

# List all plugins (convenience wrapper)
list_plugins() {
    plugin_list_available
}

# ============================================================================
# Plugin Installation
# ============================================================================

# B1.1: transaction names must satisfy the transaction grammar in backup.sh
# (letters/digits/underscore/hyphen, first char alnum, <=63 chars). Plugin
# names are already grammar-validated ([A-Za-z0-9._-]) before reaching this
# helper; dots are folded to underscores, the '.sh' suffix is stripped and
# the suffix truncated so the composed name always fits the grammar.
_plugin_txn_name() {
    local op="$1" name="$2"
    local suffix="${name%.sh}"
    suffix="${suffix//./_}"
    suffix="${suffix:0:48}"
    printf 'plugin_%s_%s' "$op" "$suffix"
}

# Install a plugin from a file
# Usage: plugin_install_from_file "/path/to/plugin.sh" [target_name]
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

    # B1.1: strict identifier grammar — applies to explicit names AND to
    # basename-derived ones. Rejects traversal ('..'), separators, leading
    # dots, empties; nothing outside the plugin dir can be denoted.
    if ! validate_identifier "$target_name"; then
        return 1
    fi

    # The plugin directory is configuration (not caller input); create it
    # before the containment check, which requires an existing base.
    if ! mkdir -p "$PLUGIN_ENABLED_DIR"; then
        log_error "Cannot create plugin directory: $PLUGIN_ENABLED_DIR"
        return 1
    fi

    local target_path="$PLUGIN_ENABLED_DIR/$target_name"

    # B1.1: canonical containment — sibling-proof and canonical (raw-string
    # prefix tricks like PLUGIN_ENABLED_DIR2 fail; not-yet-existing targets
    # are canonicalized through their existing ancestor).
    if ! path_validate_containment "$target_path" "$PLUGIN_ENABLED_DIR"; then
        return 1
    fi

    # B1.1: never install THROUGH a symlink — cp would follow it and write
    # outside the plugin directory. A plugin install target must be absent
    # or a regular file; escaping links are rejected outright.
    if [[ -L "$target_path" ]]; then
        log_error "Refusing to install over a symlink: $target_path"
        return 1
    fi

    # B1.1: route the mutation through the transaction primitive — a mid-way
    # failure rolls back to fully-absent (new file) or the prior bytes
    # (overwrite). The transaction name is derived to satisfy the
    # transaction grammar (see _plugin_txn_name).
    if ! transaction_start "$(_plugin_txn_name install "$target_name")"; then
        return 1
    fi
    if ! transaction_add_file "$target_path"; then
        transaction_rollback
        return 1
    fi

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would install plugin: $target_name"
    else
        if ! cp "$source_path" "$target_path"; then
            transaction_rollback
            return 1
        fi
        if ! chmod +x "$target_path"; then
            transaction_rollback
            return 1
        fi
    fi

    if ! transaction_commit; then
        return 1
    fi

    log_success "Plugin installed: $target_name"
    log_info "Reload plugins with: plugin_load_all"
}

# Remove an installed plugin
# Usage: plugin_remove "plugin_name"
plugin_remove() {
    local plugin_name="$1"

    # B1.1: grammar gate FIRST — a non-identifier cannot denote a plugin
    # inside PLUGIN_ENABLED_DIR, so nothing is unloaded or deleted.
    if ! validate_identifier "$plugin_name"; then
        return 1
    fi

    # Unload first
    plugin_unload "$plugin_name"

    # Remove from user directory
    local plugin_path="$PLUGIN_ENABLED_DIR/${plugin_name}.sh"

    if [[ ! -e "$plugin_path" && ! -L "$plugin_path" ]]; then
        log_warn "Plugin file not found: $plugin_path"
        return 0
    fi

    # B1.1: symlink-escape rejection with a distinct message — resolve the
    # link and refuse if its referent lives outside the plugin directory
    # (both the link and the outside target survive).
    if [[ -L "$plugin_path" ]]; then
        local resolved rbase
        resolved=$(_path_realpath "$plugin_path") || {
            log_error "Cannot resolve plugin symlink: $plugin_path"
            return 1
        }
        rbase=$(_path_realpath "$PLUGIN_ENABLED_DIR") || {
            log_error "Cannot resolve plugin directory: $PLUGIN_ENABLED_DIR"
            return 1
        }
        if [[ "$resolved" != "$rbase" && "$resolved" != "$rbase/"* ]]; then
            log_error "Refusing to remove plugin through symlink escaping the plugin directory: $plugin_path"
            return 1
        fi
    fi

    # B1.1: canonical containment as the general gate (covers any remaining
    # resolution trick — sibling prefixes, indirection through in-dir links).
    if ! path_validate_containment "$plugin_path" "$PLUGIN_ENABLED_DIR"; then
        return 1
    fi

    # B1.1: transactional delete — the pre-state (file or symlink) is backed
    # up hash-verified before the rm; a failed rm rolls back.
    if ! transaction_start "$(_plugin_txn_name remove "$plugin_name")"; then
        return 1
    fi
    if ! transaction_add_file "$plugin_path"; then
        transaction_rollback
        return 1
    fi

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would remove plugin: $plugin_name"
    else
        if ! rm -f "$plugin_path"; then
            transaction_rollback
            return 1
        fi
    fi

    if ! transaction_commit; then
        return 1
    fi

    log_success "Plugin removed: $plugin_name"
}

# ============================================================================
# Plugin Template
# ============================================================================

# Generate a plugin template
# Usage: plugin_create_template "my_plugin" [output_path]
plugin_create_template() {
    local plugin_name="$1"
    local output_path="${2:-}"

    if [[ -z "$plugin_name" ]]; then
        log_error "Plugin name required"
        return 1
    fi

    # B1.1: the name is interpolated into generated code (function names)
    # and into the sed substitution below — grammar-restrict it so it can
    # neither smuggle traversal nor corrupt the template generation.
    if ! validate_identifier "$plugin_name"; then
        return 1
    fi

    if [[ -n "$output_path" ]]; then
        # Explicit caller-supplied path: lexical screen only (no traversal,
        # no shell metacharacters). The caller chooses the location; the
        # screen guarantees the path cannot smuggle '..' or metacharacters.
        if ! validate_safe_path "$output_path"; then
            return 1
        fi
    else
        # Name-derived path: must be canonically contained in the plugin dir.
        if ! mkdir -p "$PLUGIN_ENABLED_DIR"; then
            log_error "Cannot create plugin directory: $PLUGIN_ENABLED_DIR"
            return 1
        fi
        output_path="$PLUGIN_ENABLED_DIR/${plugin_name}.sh"
        if ! path_validate_containment "$output_path" "$PLUGIN_ENABLED_DIR"; then
            return 1
        fi
    fi

    if ! mkdir -p "$(dirname "$output_path")"; then
        log_error "Cannot create output directory for: $output_path"
        return 1
    fi

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

    # Replace PLUGIN_NAME placeholder (name is grammar-validated: no '/', no
    # '&', no newlines — the sed expression cannot be corrupted).
    if ! sed -i '' "s/PLUGIN_NAME/$plugin_name/g" "$output_path" 2>/dev/null \
        && ! sed -i "s/PLUGIN_NAME/$plugin_name/g" "$output_path"; then
        log_error "Template substitution failed for: $output_path"
        rm -f "$output_path"
        return 1
    fi

    if ! chmod +x "$output_path"; then
        log_error "Cannot make template executable: $output_path"
        rm -f "$output_path"
        return 1
    fi

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
