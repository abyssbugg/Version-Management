# Platform Compatibility Matrix

This document outlines platform support for the Professional Development Terminal Setup.

## Supported Platforms

### Operating Systems

| Feature | macOS 12+ | macOS 13+ | macOS 14+ | Ubuntu 22.04 | Ubuntu 24.04 | Debian 12 | Fedora 39+ | Arch Linux | WSL2 |
|---------|-----------|-----------|-----------|--------------|--------------|-----------|------------|------------|------|
| Core Setup | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| PowerLevel10k | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Nerd Fonts | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ |
| VS Code Integration | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

### Version Managers

| Manager | macOS | Ubuntu | Debian | Fedora | Arch | WSL2 | Notes |
|---------|-------|--------|--------|--------|------|------|-------|
| **nvm** (Node.js) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Full support |
| **pyenv** (Python) | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ | WSL: needs build deps |
| **goenv** (Go) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Full support |
| **rustup** (Rust) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Full support |
| **jenv** (Java) | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ | WSL: manual JDK install |
| **rbenv** (Ruby) | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ | WSL: needs build deps |
| **asdf** (Universal) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | Plugin-dependent |

### Shell Support

| Shell | Support | Notes |
|-------|---------|-------|
| **zsh** | ✅ Required | Primary shell, full feature support |
| **bash** | ⚠️ Partial | Scripts work, but P10k requires zsh |
| **fish** | ❌ | Not supported (P10k zsh-only) |

### Terminal Emulators

| Terminal | macOS | Linux | WSL | Nerd Font Support |
|----------|-------|-------|-----|-------------------|
| **iTerm2** | ✅ | - | - | ✅ Excellent |
| **Terminal.app** | ✅ | - | - | ✅ Good |
| **Alacritty** | ✅ | ✅ | ✅ | ✅ Excellent |
| **Kitty** | ✅ | ✅ | ✅ | ✅ Excellent |
| **GNOME Terminal** | - | ✅ | - | ✅ Good |
| **Konsole** | - | ✅ | - | ✅ Good |
| **Windows Terminal** | - | - | ✅ | ✅ Excellent |
| **VS Code Terminal** | ✅ | ✅ | ✅ | ✅ Good |
| **Hyper** | ✅ | ✅ | ✅ | ⚠️ Limited |

## Legend

- ✅ **Fully supported** - Tested and working
- ⚠️ **Partial support** - Works with known limitations
- ❌ **Not supported** - Does not work or untested

## Platform-Specific Notes

### macOS

**Homebrew Recommended**

```bash
# Install Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install common dependencies
brew install git curl wget zsh
```

**Font Installation**

- Double-click `.ttf` files or use Font Book
- Fonts install to `~/Library/Fonts/` or `/Library/Fonts/`

### Ubuntu / Debian

**Required Packages**

```bash
# Core dependencies
sudo apt update
sudo apt install -y git curl wget zsh

# For pyenv (Python building)
sudo apt install -y build-essential libssl-dev zlib1g-dev \
  libbz2-dev libreadline-dev libsqlite3-dev libffi-dev

# For font cache
sudo apt install -y fontconfig
```

**Font Installation**

- Copy fonts to `~/.local/share/fonts/`
- Run `fc-cache -f -v`

### Fedora

**Required Packages**

```bash
# Core dependencies
sudo dnf install -y git curl wget zsh

# For pyenv
sudo dnf install -y gcc zlib-devel bzip2 bzip2-devel \
  readline-devel sqlite sqlite-devel openssl-devel \
  tk-devel libffi-devel xz-devel
```

### Arch Linux

**Required Packages**

```bash
# Core dependencies
sudo pacman -S git curl wget zsh

# For pyenv
sudo pacman -S base-devel openssl zlib xz tk

# AUR helpers available for many tools
yay -S nvm pyenv
```

### WSL2 (Windows Subsystem for Linux)

**Limitations**

1. **Font Installation**
   - Fonts must be installed on Windows side
   - Copy `.ttf` files to `C:\Windows\Fonts\` or user fonts folder
   - Configure Windows Terminal font settings

2. **GUI Applications**
   - Desktop apps may not work without WSLg
   - Use Windows-side VS Code with Remote WSL extension

3. **Performance**
   - File system operations slower on Windows drives
   - Keep projects in Linux filesystem (`~/`)

4. **Build Dependencies**
   - pyenv requires Linux build dependencies
   - jenv needs JDK installed manually

**Recommended Setup**

```bash
# Install in WSL Ubuntu
sudo apt update
sudo apt install -y git curl wget zsh build-essential

# Install Windows Terminal from Microsoft Store
# Configure font in Windows Terminal settings
```

## Architecture Support

| Architecture | Support | Notes |
|--------------|---------|-------|
| x86_64 (Intel/AMD) | ✅ | Primary development target |
| ARM64 (Apple Silicon) | ✅ | Full support on M1/M2/M3 |
| ARM64 (Linux) | ⚠️ | Most features work, some binaries limited |
| ARM32 | ❌ | Not supported |

## Browser-Based IDEs

| IDE | Support | Notes |
|-----|---------|-------|
| **GitHub Codespaces** | ⚠️ | Limited P10k support in web terminal |
| **Gitpod** | ⚠️ | Limited P10k support |
| **VS Code Web** | ⚠️ | Font support depends on browser |

## Minimum Requirements

### Hardware

- 1 GB RAM (2+ GB recommended)
- 500 MB disk space for tools
- Internet connection for installation

### Software

- Git 2.x+
- curl or wget
- zsh 5.0+ (5.8+ recommended)

## Testing Your System

Run the built-in compatibility check:

```bash
./tools/system-diagnostics.sh --full
```

Or run the cross-platform test:

```bash
./tests/integration/test_cross_platform.sh
```

## Reporting Compatibility Issues

If you encounter platform-specific issues:

1. Run diagnostics: `./tools/system-diagnostics.sh --json > diagnostic.json`
2. Check your platform: `uname -a`
3. Open an issue with the diagnostic output

## See Also

- [Installation Guide](../README.md)
- [Troubleshooting](../README.md#troubleshooting)
- [Contributing](../CONTRIBUTING.md)
