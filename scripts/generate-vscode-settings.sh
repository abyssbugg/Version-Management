#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2086,SC2155,SC2005,SC2207,SC2016

# VS Code Settings Generator
# Generates personalized VS Code settings from template by replacing placeholders
# with actual system values

set -euo pipefail

# Source required libraries
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

# Source env.sh first (which sources logger.sh)
source "$repo_root/lib/env.sh"

# Source logger for consistent logging (env.sh provides fallbacks)
source "$repo_root/lib/logger.sh" 2>/dev/null || true

# Configuration
readonly TEMPLATE_FILE="$repo_root/config/vscode-settings.template.json"
readonly OUTPUT_FILE="$repo_root/vscode-settings.json"
readonly NVMRC_FILE="$repo_root/.nvmrc"

# Function to detect current Node.js version
detect_node_version() {
    local node_version=""

    # Try to get version from .nvmrc first
    if [ -f "$NVMRC_FILE" ]; then
        node_version=$(cat "$NVMRC_FILE" | tr -d '[:space:]')
        log_debug "Found Node.js version in .nvmrc: $node_version"
    fi

    # Fallback to nvm current if available
    if [ -z "$node_version" ] && [ -n "${NVM_DIR:-}" ] && [ -s "$NVM_DIR/nvm.sh" ]; then
        # Source nvm if not already loaded
        if ! command -v nvm >/dev/null 2>&1; then
            source "$NVM_DIR/nvm.sh"
        fi

        if command -v nvm >/dev/null 2>&1; then
            node_version=$(nvm current 2>/dev/null | sed 's/^v//' || echo "")
            log_debug "Detected current Node.js version from nvm: $node_version"
        fi
    fi

    # Fallback to system node if available
    if [ -z "$node_version" ] && command -v node >/dev/null 2>&1; then
        node_version=$(node --version 2>/dev/null | sed 's/^v//' || echo "")
        log_debug "Detected Node.js version from system: $node_version"
    fi

    # Default fallback
    if [ -z "$node_version" ]; then
        node_version="20.19.2"
        log_warn "Could not detect Node.js version, using default: $node_version"
    fi

    echo "$node_version"
}

# Function to detect NVM directory
detect_nvm_dir() {
    local nvm_dir=""

    # Check environment variable first
    if [ -n "${NVM_DIR:-}" ]; then
        nvm_dir="$NVM_DIR"
        log_debug "Using NVM_DIR from environment: $nvm_dir"
    # Check common locations
    elif [ -d "$HOME/.nvm" ]; then
        nvm_dir="$HOME/.nvm"
        log_debug "Found NVM directory at: $nvm_dir"
    elif [ -d "/usr/local/nvm" ]; then
        nvm_dir="/usr/local/nvm"
        log_debug "Found NVM directory at: $nvm_dir"
    else
        nvm_dir="$HOME/.nvm"
        log_warn "Could not detect NVM directory, using default: $nvm_dir"
    fi

    echo "$nvm_dir"
}

# Function to get home directory
get_home_dir() {
    echo "${HOME:-/home/$(whoami)}"
}

# Function to replace placeholders in template
replace_placeholders() {
    local template_content="$1"
    local nvm_dir="$2"
    local node_version="$3"
    local home_dir="$4"
    local os_type="$5"

    # Replace NVM_DIR placeholder
    template_content="${template_content//\{\{NVM_DIR\}\}/$nvm_dir}"

    # Replace NODE_VERSION placeholder
    template_content="${template_content//\{\{NODE_VERSION\}\}/$node_version}"

    # Replace HOME placeholder
    template_content="${template_content//\{\{HOME\}\}/$home_dir}"

    # Handle OS-specific path separators for Windows
    if [ "$os_type" = "windows" ]; then
        # Convert forward slashes to backslashes for Windows paths
        # shellcheck disable=SC2001
        template_content=$(echo "$template_content" | sed 's|{{NVM_DIR}}/|{{NVM_DIR}}\\|g')
        template_content="${template_content//\{\{NVM_DIR\}\}/$nvm_dir}"
    fi

    echo "$template_content"
}

# Function to validate template file
validate_template() {
    if [ ! -f "$TEMPLATE_FILE" ]; then
        log_error "Template file not found: $TEMPLATE_FILE"
        return 1
    fi

    # Basic JSON validation
    if ! python3 -m json.tool "$TEMPLATE_FILE" >/dev/null 2>&1; then
        if ! node -e "JSON.parse(require('fs').readFileSync('$TEMPLATE_FILE', 'utf8'))" >/dev/null 2>&1; then
            log_error "Template file is not valid JSON: $TEMPLATE_FILE"
            return 1
        fi
    fi

    log_debug "Template file validation passed"
    return 0
}

# Function to validate generated settings
validate_generated_settings() {
    local output_file="$1"

    if [ ! -f "$output_file" ]; then
        log_error "Generated settings file not found: $output_file"
        return 1
    fi

    # Basic JSON validation
    if ! python3 -m json.tool "$output_file" >/dev/null 2>&1; then
        if ! node -e "JSON.parse(require('fs').readFileSync('$output_file', 'utf8'))" >/dev/null 2>&1; then
            log_error "Generated settings file is not valid JSON: $output_file"
            return 1
        fi
    fi

    # Check for remaining placeholders
    if grep -q "{{.*}}" "$output_file"; then
        log_warn "Generated settings still contain unreplaced placeholders:"
        grep -o "{{[^}]*}}" "$output_file" | sort | uniq
    fi

    log_debug "Generated settings validation passed"
    return 0
}

# Function to display usage instructions
show_usage_instructions() {
    local output_file="$1"

    echo ""
    log_info " VS Code settings generated successfully!"
    echo ""
    echo " Generated file: $output_file"
    echo ""
    echo "📋 To import these settings into VS Code:"
    echo "   1. Open VS Code"
    echo "   2. Press Cmd+Shift+P (Mac) or Ctrl+Shift+P (Windows/Linux)"
    echo "   3. Type 'Preferences: Open Settings (JSON)'"
    echo "   4. Copy the contents of $output_file"
    echo "   5. Paste into your VS Code settings.json file"
    echo ""
    echo " Alternatively, you can:"
    echo "   - Copy the file to your VS Code user settings directory"
    echo "   - Use the VS Code Settings Sync feature"
    echo ""
    echo " The generated settings include:"
    echo "   - Personalized terminal profiles for your OS"
    echo "   - Node.js and npm paths configured for your system"
    echo "   - ESLint configuration with your Node.js version"
    echo "   - Cross-platform compatibility settings"
    echo ""
}

# Main function
main() {
    log_info " Generating personalized VS Code settings..."

    # Validate template file
    if ! validate_template; then
        log_error "Template validation failed"
        exit 1
    fi

    # Detect system information
    log_info " Detecting system configuration..."

    local os_type
    os_type=$(detect_os)
    log_info "Operating System: $os_type"

    local home_dir
    home_dir=$(get_home_dir)
    log_info "Home Directory: $home_dir"

    local nvm_dir
    nvm_dir=$(detect_nvm_dir)
    log_info "NVM Directory: $nvm_dir"

    local node_version
    node_version=$(detect_node_version)
    log_info "Node.js Version: $node_version"

    # Read template file
    log_info "📖 Reading template file..."
    local template_content
    if ! template_content=$(cat "$TEMPLATE_FILE"); then
        log_error "Failed to read template file: $TEMPLATE_FILE"
        exit 1
    fi

    # Replace placeholders
    log_info " Replacing placeholders with actual values..."
    local generated_content
    generated_content=$(replace_placeholders "$template_content" "$nvm_dir" "$node_version" "$home_dir" "$os_type")

    # Write generated settings
    log_info " Writing generated settings..."
    if ! echo "$generated_content" > "$OUTPUT_FILE"; then
        log_error "Failed to write generated settings to: $OUTPUT_FILE"
        exit 1
    fi

    # Validate generated settings
    if ! validate_generated_settings "$OUTPUT_FILE"; then
        log_error "Generated settings validation failed"
        exit 1
    fi

    # Show usage instructions
    show_usage_instructions "$OUTPUT_FILE"

    log_info "✨ VS Code settings generation completed successfully!"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
