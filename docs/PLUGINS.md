# Plugin Development Guide

This guide explains how to create plugins for the Professional Development Environment Automation Suite.

## Overview

The plugin system allows you to extend the suite with support for additional version managers, tools, and functionality without modifying the core codebase.

## Plugin Structure

Each plugin is a single shell script that implements a standard interface.

### Directory Structure

```text
plugins/
├── rbenv.sh      # Ruby version manager plugin
├── asdf.sh       # Universal version manager plugin
└── my-plugin.sh  # Your custom plugin
```

### User Plugins

Users can install plugins to their personal directory:

```text
~/.config/version-manager/plugins/
```

## Required Functions

Every plugin MUST implement these functions:

### `plugin_info()`

Returns plugin metadata as a single-line string.

```bash
plugin_info() {
    echo "my_plugin v1.0.0 - Description of what this plugin does"
}
```

### `plugin_init()`

Called when the plugin is loaded. Use for initialization.

```bash
plugin_init() {
    export MY_TOOL_HOME="${MY_TOOL_HOME:-$HOME/.my-tool}"
    return 0
}
```

### `plugin_detect()`

Checks if the tool is available on the system.

```bash
plugin_detect() {
    command -v my-tool >/dev/null 2>&1
}
```

### `plugin_install()`

Installs the tool if not present.

```bash
plugin_install() {
    if plugin_detect; then
        echo "Already installed"
        return 0
    fi

    # Preferred channels: platform package manager, or the tool's official
    # installer with a checksum-verified download. Never pipe-to-shell.
    case "$(uname -s)" in
        Darwin) brew install my-tool ;;
        Linux)  apt-get install -y my-tool ;;
    esac
    return $?
}
```

**Installer policy:** plugins must never use `curl | bash` /
`curl | sh` — not in project code and not in generated content
(ENGINEERING_RULES.md §2.3, ADR-002's injection discipline applies to
what a plugin executes too). Use, in order of preference:

1. The platform package manager (`brew`, `apt`, `dnf`, …).
2. A pinned git clone of the tool.
3. A direct download that is checksum-verified before execution.

A plugin that reaches for pipe-to-shell will not pass review.

### `plugin_version()`

Returns the current version of the tool.

```bash
plugin_version() {
    if plugin_detect; then
        my-tool --version 2>/dev/null | head -1
    else
        echo "not installed"
        return 1
    fi
}
```

### `plugin_list()`

Lists installed or available versions.

```bash
plugin_list() {
    echo "Installed versions:"
    my-tool list 2>/dev/null || echo "  (none)"
}
```

### `plugin_use()`

Switches to a specific version.

```bash
plugin_use() {
    local version="$1"
    my-tool use "$version"
}
```

## Optional Functions

### `plugin_cleanup()`

Called when the plugin is unloaded.

```bash
plugin_cleanup() {
    # Cleanup resources
    return 0
}
```

### `plugin_update()`

Updates the tool to the latest version.

```bash
plugin_update() {
    my-tool update
}
```

## Creating a Plugin

### Step 1: Generate Template

```bash
source lib/plugins.sh
plugin_create_template "my_tool"
```

This creates `~/.config/version-manager/plugins/my_tool.sh` with a template.

### Step 2: Implement Functions

Edit the generated file and implement each function:

```bash
#!/usr/bin/env bash
# Plugin: my_tool

my_tool_info() {
    echo "my_tool v1.0.0 - My custom version manager"
}

my_tool_init() {
    export MY_TOOL_ROOT="$HOME/.my-tool"
    return 0
}

my_tool_detect() {
    command -v my-tool >/dev/null 2>&1
}

my_tool_install() {
    echo "Installing my-tool..."
    # Your installation code
    return 0
}

my_tool_version() {
    my-tool --version 2>/dev/null || echo "not installed"
}

my_tool_list() {
    my-tool list
}

my_tool_use() {
    my-tool use "$1"
}

# Standard interface mappings
plugin_info() { my_tool_info; }
plugin_init() { my_tool_init; }
plugin_detect() { my_tool_detect; }
plugin_install() { my_tool_install; }
plugin_version() { my_tool_version; }
plugin_list() { my_tool_list; }
plugin_use() { my_tool_use "$@"; }
```

### Step 3: Test the Plugin

```bash
# Load the plugin system
source lib/plugins.sh

# Initialize and load plugins
plugin_system_init

# List plugins
plugin_list_available

# Check your plugin
plugin_run my_tool detect
plugin_run my_tool version
```

## Plugin API Reference

### Loading Functions

| Function | Description |
|----------|-------------|
| `plugin_system_init` | Initialize the plugin system |
| `plugin_load "path"` | Load a specific plugin |
| `plugin_load_all` | Load all available plugins |
| `plugin_unload "name"` | Unload a plugin |

### Discovery Functions

| Function | Description |
|----------|-------------|
| `plugin_list_available` | List all available plugins |
| `plugin_list_loaded` | List currently loaded plugins |

### Execution Functions

| Function | Description |
|----------|-------------|
| `plugin_run "name" "func" [args]` | Run a plugin function |
| `plugin_has_capability "name" "func"` | Check if plugin has function |

### Installation Functions

| Function | Description |
|----------|-------------|
| `plugin_install_from_file "path"` | Install plugin from file |
| `plugin_remove "name"` | Remove an installed plugin |
| `plugin_create_template "name"` | Generate plugin template |

## Best Practices

1. **Namespace your functions**: Prefix all functions with your plugin name

   ```bash
   my_plugin_detect()  # Good
   detect()            # Bad - may conflict
   ```

2. **Handle missing dependencies**: Always check if tools exist before using them

   ```bash
   my_plugin_version() {
       if ! my_plugin_detect; then
           echo "not installed"
           return 1
       fi
       # ...
   }
   ```

3. **Support multiple platforms**: Check OS type for installation

   ```bash
   case "$(uname -s)" in
       Darwin) brew install my-tool ;;
       Linux)  apt install my-tool ;;
   esac
   ```

4. **Provide helpful error messages**: Guide users when things fail

   ```bash
   if ! my_plugin_detect; then
       echo "my-tool not found. Install with:"
       echo "  brew install my-tool  # macOS"
       echo "  apt install my-tool   # Ubuntu"
       return 1
   fi
   ```

5. **Clean up resources**: Implement `plugin_cleanup()` if needed

## Example Plugins

See the included plugins for reference:

- `plugins/rbenv.sh` - Ruby version manager
- `plugins/asdf.sh` - Universal version manager

## Troubleshooting

### Plugin not loading

1. Check the file has execute permission: `chmod +x plugin.sh`
2. Verify syntax: `bash -n plugin.sh`
3. Check `plugin_info()` is implemented

### Functions not found

Ensure you have the standard interface mappings at the end:

```bash
plugin_info() { my_plugin_info; }
plugin_init() { my_plugin_init; }
# ... etc
```

### Debug mode

Enable debug output:

```bash
DEBUG=true source lib/plugins.sh
plugin_system_init
```
