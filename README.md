# Professional Development Environment Automation Suite

A comprehensive automation suite for setting up and managing professional development environments with PowerLevel10k themes, version managers, and VS Code integration. This project has evolved from a simple configuration pack into a fully functional automation suite with cross-platform compatibility.

## 🆕 Enhanced Version Management System

We've significantly upgraded our version management capabilities! The new system provides:

- 🔄 **Automatic version switching** when entering project directories
- 🚀 **Performance optimized** with lazy loading for faster shell startup
- 🏥 **Comprehensive diagnostics** for troubleshooting
- 🔌 **CI/CD integration** with GitHub Actions, GitLab CI, CircleCI
- 📦 **Docker support** for containerized development

**[📖 View the Complete Version Management Guide](docs/API.md)**

## 🚀 Quick Start

```bash
./setup.sh
```

This launches an interactive automation suite with options to:

- Install & Apply Professional Theme with automatic backup
- Setup Version Managers (Node.js via nvm, Python via pyenv)
- Generate Personalized VS Code Settings
- Validate Current Setup with comprehensive checks
- Show Current Configuration and system status

## 📋 Automation Scripts

The suite provides several automation scripts that work together as a cohesive system:

### Enhanced Version Management Scripts (NEW!)

```bash
# Comprehensive version manager with auto-installation
./version-manager.sh health-check      # Run health diagnostics
./version-manager.sh install-all       # Install all version managers
./version-manager.sh install-node 20.0.0  # Install specific Node version

# Advanced diagnostic system
./tools/version-diagnostic-enhanced.sh --quick        # Quick health check
./tools/version-diagnostic-enhanced.sh --full         # Comprehensive system analysis

# Advanced features and CI/CD integration
./version-advanced.sh auto-switch      # Enable automatic version switching
./version-advanced.sh lazy-load        # Optimize shell performance
./version-advanced.sh ci-all          # Generate CI/CD configurations
```

### Main Setup Scripts

```bash
# Interactive main menu with full automation
./setup.sh

# Apply professional theme with backup and validation
./setup-theme.sh professional

# Setup and validate version managers
./setup-versions.sh pro-status

# Comprehensive setup validation
./validate-setup.sh

# Generate personalized VS Code settings
./scripts/generate-vscode-settings.sh
```

### Enhanced NVM Management

```bash
# Enhanced verbose fix with detailed logging
./scripts/fix-nvm-issues.sh

# Permanent silence for nvm directory messages
./scripts/fix-terminal-issues.sh
```

### Quality & Diagnostics

```bash
# Lint all shell scripts with shellcheck
./scripts/lint-shell.sh

# Preview targets without running shellcheck
./scripts/lint-shell.sh --list-targets
```

## 🎯 VS Code Settings Template System

The automation suite includes a powerful template system for generating personalized VS Code settings:

### Template Features

- **Cross-platform settings**: Includes VS Code terminal profiles for macOS, Linux and Windows hosts; VS Code applies the one for the host it runs on
- **Dynamic path resolution**: Generates correct paths for your system
- **Font integration**: Configures MesloLGS Nerd Font automatically
- **Terminal optimization**: Sets up integrated terminal with proper shell configuration

### Usage

1. **Generate personalized settings**:

   ```bash
   ./scripts/generate-vscode-settings.sh
   ```

2. **Import into VS Code**:
   - Open VS Code Settings (⌘/Ctrl + ,)
   - Click "Open Settings (JSON)" icon in top-right
   - Copy content from generated `config/vscode-settings.json`
   - Paste into your VS Code settings

### Template System Details

The system uses `config/vscode-settings.template.json` as a base template with placeholders:

- `{{SHELL_PATH}}` - Automatically detected shell path
- `{{HOME_PATH}}` - User home directory path
- Platform-specific configurations for optimal performance

## 🎨 Terminal Theme Previews

The automation suite includes enhanced terminal themes with visual indicators for all supported version managers:

### Professional Development Theme

```text
    ~/projects/my-app   main  20.19.2  3.12.8  ⌚ 10:30:25  ✓
```

This theme features:

- Enhanced version management indicators for Go (1.23.4), Rust (1.82.0), and Java (21.0.2)
- Customizable OS, directory, and status icons
- Nerd Font integration with proper Unicode support
- Color-coded segments for different environments

## 📁 Project Structure

```text
/
├── config/
│   ├── professional-dev-p10k.zsh       # Professional theme config
│   ├── vscode-settings.template.json   # VS Code settings template
│   └── vscode-settings.json            # Generated VS Code settings
├── lib/                                # Automation library utilities
│   ├── env.sh                          # Environment detection & setup
│   ├── logger.sh                       # Centralized logging with colors
│   ├── cache.sh                        # Caching system for setup state
│   ├── theme-ops.sh                    # PowerLevel10k theme operations
│   └── backup.sh                       # Backup and restore functionality
├── setup.sh                            # Main interactive automation suite
├── setup-theme.sh                      # Enhanced theme installer
├── setup-versions.sh                   # Version manager automation
├── validate-setup.sh                   # Comprehensive setup validator
├── version-manager.sh                  # Version management CLI
└── version-advanced.sh                 # Advanced features & CI/CD
```

## 🏗️ Architecture

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                         USER INTERFACE LAYER                                │
├─────────────────────────────────────────────────────────────────────────────┤
│  setup.sh          version-manager.sh       version-advanced.sh             │
│  (Interactive)     (CLI Interface)          (CI/CD Generation)              │
└────────────────────────────┬────────────────────────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────────────────────────┐
│                         ORCHESTRATION LAYER                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  setup-theme.sh    setup-versions.sh    validate-setup.sh    fix-*.sh       │
│  (Theme Setup)     (Version Mgrs)       (Validation)         (Fixes)        │
└────────────────────────────┬────────────────────────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────────────────────────┐
│                         LIBRARY LAYER (lib/)                                │
├─────────────────┬──────────────┬──────────────┬──────────────┬──────────────┤
│   Core          │   Version    │   Theme      │   Quality    │   Utils      │
│   ───────       │   Managers   │   ─────      │   ───────    │   ─────      │
│   logger.sh     │   nvm.sh     │   theme-     │   error-     │   utils.sh   │
│   env.sh        │   pyvm.sh    │   ops.sh     │   handling   │   cache.sh   │
│   backup.sh     │   gvm.sh     │              │   .sh        │   validation │
│                 │   jenv.sh    │              │   perform-   │   .sh        │
│                 │   rustup.sh  │              │   ance.sh    │              │
└─────────────────┴──────────────┴──────────────┴──────────────┴──────────────┘
                             │
┌────────────────────────────▼────────────────────────────────────────────────┐
│                         CONFIGURATION LAYER                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│   config/professional-dev-p10k.zsh    .nvmrc    .python-version    etc.     │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **User** → Runs `setup.sh` or direct scripts
2. **Orchestration** → Coordinates multiple operations
3. **Libraries** → Provide reusable functionality
4. **Configuration** → Stores settings and version files

### Key Design Principles

- **Modular**: Each library handles one concern
- **Defensive**: `set -euo pipefail` in all scripts
- **Cross-platform**: macOS and Linux; WSL2 through the Linux code paths ([support status](docs/PLATFORM_COMPATIBILITY.md#support-status))
- **Cacheable**: TTL-based caching for performance

## 🔧 Library Utilities

The automation suite is built on a foundation of reusable library utilities:

### `lib/logger.sh` - Centralized Logging

- Color-coded output (info, success, warning, error)
- Consistent formatting across all scripts
- Debug mode support for troubleshooting

### `lib/env.sh` - Environment Detection

- OS detection: `macos`, `linux`, `wsl` (Cygwin/MSYS/Git-Bash report `windows`, which is not a supported platform)
- Shell detection and configuration
- Path resolution utilities
- System capability checks

### `lib/theme-ops.sh` - Theme Management

- PowerLevel10k installation and configuration
- Theme backup and restore operations
- Configuration validation and error handling
- Professional theme application

### `lib/backup.sh` - Backup System

- Automatic backup creation before changes
- Timestamped backup files
- Restore functionality for rollback
- Backup validation and integrity checks

### `lib/cache.sh` - State Management

- Setup state caching for performance
- Configuration change detection
- Cache invalidation and refresh
- Persistent state across script runs

## ⚙️ Requirements

- **PowerLevel10k**: Automatically installed if not present
- **Nerd Font**: MesloLGS/compatible Nerd Fonts detected and auto-configured
- **zsh**: Required shell (installation guided if needed)
- **Git, Node.js, Python**: Managed through version managers
- **Platforms**: macOS, Linux, and WSL2; native Windows is not supported ([support status](docs/PLATFORM_COMPATIBILITY.md#support-status))

## 🎯 What This Automation Suite Does

1. **Professional Theme Setup**:
   - Installs and configures PowerLevel10k with professional styling
   - Automatic backup of existing configurations
   - Validates theme installation and provides troubleshooting

2. **Version Manager Integration**:
   - Sets up Node.js (via nvm) using the version defined in `.nvmrc`
   - Configures Python (via pyenv) with version **3.12.11** (from `.python-version`)
   - Displays version information in terminal prompt
   - Handles version manager installation if missing

3. **VS Code Optimization**:
   - Generates personalized settings for your system
   - Configures integrated terminal with proper shell
   - Sets up Nerd Font integration automatically
   - Cross-platform path resolution

4. **System Validation**:
   - Comprehensive setup verification
   - Dependency checking and installation guidance
   - Configuration validation with detailed reporting
   - Performance optimization recommendations

5. **Enhanced User Experience**:
   - Interactive menus with clear options
   - Detailed logging and progress indicators
   - Error handling with recovery suggestions
   - Backup and restore capabilities

## 🐍 Python Version Update

The suite now uses **Python 3.12.11** as the default version, aligning with the project's `.python-version` file. This release builds upon the 3.11 series and brings notable improvements:

- **Performance & Security** – further optimisations in the CPython core reduce startup time and improve runtime efficiency while patching newly discovered vulnerabilities.
- **Ecosystem Compatibility** – enhanced support for modern development tooling ensures smooth integration with frameworks, linters and type checkers.
- **Language Features & Typing** – refinements to pattern matching and generics, along with clearer type hint error messages.
- **Longevity & Stability** – as a patch release on the 3.12 line, it receives full upstream support and fixes for the foreseeable future.

The automation scripts manage Python version installation via pyenv, so running `setup-versions.sh` will automatically install and activate Python 3.12.11 for your project.

## 🌐 Cross-Platform Compatibility

The automation suite provides full cross-platform support:

### macOS

- Native shell detection and configuration
- Homebrew integration for package management
- Optimized for macOS terminal applications

### Linux

- Distribution-agnostic setup procedures
- Package manager detection (apt, yum, pacman)
- WSL compatibility for Windows users

### Windows (WSL2 only)

- Runs inside a WSL2 Linux distribution through the Linux code paths (`get_os` reports `wsl`)
- Fonts are installed on the Windows side; see [WSL2 limitations](docs/PLATFORM_COMPATIBILITY.md#wsl2-windows-subsystem-for-linux)
- Native Windows shells (PowerShell, cmd, Git-Bash/MSYS, Cygwin) are not supported

## 🔧 Troubleshooting

The automation suite includes comprehensive troubleshooting capabilities:

### Font and Icon Issues

1. **Automatic font installation**: MesloLGS Nerd Fonts can be installed via `setup-fonts-enhanced.sh`
2. **VS Code integration**: Generated settings configure fonts automatically
3. **Terminal configuration**: Scripts detect and configure terminal applications

### NVM Verbose Messages

The suite provides enhanced solutions for nvm directory messages:

```bash
# For detailed fixing with logging
./scripts/fix-nvm-issues.sh

# For permanent silence (recommended)
./scripts/fix-terminal-issues.sh
```

These scripts handle:

- `Found '/path/to/.nvmrc' with version <20.19.2>`
- `Now using node v20.19.2 (npm v11.4.2)`
- Automatic version switching notifications

### Setup Validation

```bash
# Run comprehensive validation
./validate-setup.sh
```

This provides:

- Dependency verification
- Configuration validation
- Performance analysis
- Troubleshooting recommendations

### Library Utilities Debugging

All scripts support debug mode for detailed troubleshooting:

```bash
DEBUG=1 ./setup.sh
```

### Recovery and Backup

The automation suite maintains automatic backups:

- Configuration files are backed up before changes
- Restore functionality available through library utilities
- Timestamped backups for version tracking

## 🚀 Advanced Usage

### Custom Configuration

The template system allows for easy customization:

1. Modify `config/vscode-settings.template.json` for custom VS Code settings
2. Edit theme configurations in `config/professional-dev-p10k.zsh`
3. Extend library utilities for additional functionality

### Integration with Development Workflows

The automation suite integrates seamlessly with:

- CI/CD pipelines for consistent environments
- Docker containers for development
- Remote development setups
- Team onboarding processes

## 🎉 Complete Professional Setup

This automation suite transforms your development environment into a professional, efficient workspace. The interactive setup process guides you through each step, while the library utilities ensure reliability and cross-platform compatibility.

Run `./setup.sh` to begin your professional development environment transformation!
