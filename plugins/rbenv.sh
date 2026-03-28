#!/usr/bin/env bash
# Plugin: rbenv
# Ruby Version Manager Plugin

# ============================================================================
# Plugin Metadata
# ============================================================================

rbenv_info() {
    echo "rbenv v1.0.0 - Ruby version management via rbenv"
}

# ============================================================================
# Core Functions
# ============================================================================

rbenv_init() {
    # Set default rbenv root
    export RBENV_ROOT="${RBENV_ROOT:-$HOME/.rbenv}"
    return 0
}

rbenv_detect() {
    command -v rbenv >/dev/null 2>&1
}

rbenv_install() {
    echo "Installing rbenv..."
    
    if rbenv_detect; then
        echo "rbenv is already installed"
        return 0
    fi
    
    local os_type
    os_type=$(uname -s)
    
    case "$os_type" in
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                brew install rbenv ruby-build
            else
                echo "Homebrew not found. Installing via git..."
                git clone https://github.com/rbenv/rbenv.git "$RBENV_ROOT"
                git clone https://github.com/rbenv/ruby-build.git "$RBENV_ROOT/plugins/ruby-build"
            fi
            ;;
        Linux)
            git clone https://github.com/rbenv/rbenv.git "$RBENV_ROOT"
            git clone https://github.com/rbenv/ruby-build.git "$RBENV_ROOT/plugins/ruby-build"
            ;;
        *)
            echo "Unsupported OS: $os_type"
            return 1
            ;;
    esac
    
    echo "rbenv installed successfully"
    echo "Add to your shell: eval \"\$(rbenv init -)\""
    return 0
}

rbenv_version() {
    if rbenv_detect; then
        rbenv version 2>/dev/null | cut -d' ' -f1
    else
        echo "not installed"
        return 1
    fi
}

rbenv_list() {
    if ! rbenv_detect; then
        echo "rbenv not installed"
        return 1
    fi
    
    echo "Installed Ruby versions:"
    rbenv versions 2>/dev/null || echo "  (none)"
    echo
    echo "Available versions (latest 10):"
    rbenv install -l 2>/dev/null | head -10 || echo "  (run 'rbenv install -l' for full list)"
}

rbenv_use() {
    local version="$1"
    
    if ! rbenv_detect; then
        echo "rbenv not installed"
        return 1
    fi
    
    if [[ -z "$version" ]]; then
        echo "Usage: rbenv_use <version>"
        return 1
    fi
    
    # Check if version is installed
    if ! rbenv versions --bare 2>/dev/null | grep -q "^${version}$"; then
        echo "Version $version not installed. Installing..."
        rbenv install "$version" || return 1
    fi
    
    rbenv global "$version"
    echo "Now using Ruby $version"
}

rbenv_install_version() {
    local version="$1"
    
    if ! rbenv_detect; then
        echo "rbenv not installed"
        return 1
    fi
    
    rbenv install "$version"
}

rbenv_cleanup() {
    return 0
}

# ============================================================================
# Project Detection
# ============================================================================

rbenv_is_ruby_project() {
    [[ -f ".ruby-version" ]] || [[ -f "Gemfile" ]] || [[ -f "*.gemspec" ]]
}

# ============================================================================
# Standard Plugin Interface
# ============================================================================

plugin_info() { rbenv_info; }
plugin_init() { rbenv_init; }
plugin_detect() { rbenv_detect; }
plugin_install() { rbenv_install; }
plugin_version() { rbenv_version; }
plugin_list() { rbenv_list; }
plugin_use() { rbenv_use "$@"; }
plugin_cleanup() { rbenv_cleanup; }
