# Development Tools

This directory contains utility scripts for maintaining and troubleshooting the Professional Development Environment Suite.

## Available Tools

| Tool | Purpose | Usage |
|------|---------|-------|
| [health-check.sh](#health-checksh) | Quick environment validation | `./tools/health-check.sh` |
| [check-dependencies.sh](#check-dependenciessh) | Verify core dependencies | `./tools/check-dependencies.sh` |
| [system-diagnostics.sh](#system-diagnosticssh) | Comprehensive system scan | `./tools/system-diagnostics.sh` |
| [preview-nerd-fonts.sh](#preview-nerd-fontssh) | Test Nerd Font rendering | `./tools/preview-nerd-fonts.sh` |
| [update-dependencies.sh](#update-dependenciessh) | Update all version managers | `./tools/update-dependencies.sh` |
| [update-global-node-symlinks.sh](#update-global-node-symlinkssh) | Fix Node.js access for desktop apps | `./tools/update-global-node-symlinks.sh` |
| [validate-quality.sh](#validate-qualitysh) | Run shellcheck validation | `./tools/validate-quality.sh` |
| [analytics-report.sh](#analytics-reportsh) | Usage analytics dashboard | `./tools/analytics-report.sh` |

---

## Tool Details

### health-check.sh

Quick validation of your development environment.

```bash
./tools/health-check.sh
```

**Checks:**

- Shell configuration (zsh)
- PowerLevel10k theme
- Version managers (nvm, pyenv, etc.)
- Required tools (git, curl)

---

### check-dependencies.sh

Verifies all required dependencies are installed.

```bash
./tools/check-dependencies.sh
```

**Checks:**

- Core utilities (git, curl, wget)
- Shell requirements (zsh)
- Optional tools (shellcheck, jq)

---

### system-diagnostics.sh

Comprehensive diagnostic tool with multiple output formats.

```bash
# Quick check
./tools/system-diagnostics.sh --quick

# Full diagnostic
./tools/system-diagnostics.sh --full

# Interactive dashboard
./tools/system-diagnostics.sh --dashboard

# JSON output (for CI)
./tools/system-diagnostics.sh --json

# View diagnostic history
./tools/system-diagnostics.sh --history
```

**Features:**

- Health scoring (0-100%)
- Version manager status
- Configuration validation
- Automatic fix suggestions
- History tracking

---

### preview-nerd-fonts.sh

Tests Nerd Font icon rendering in your terminal.

```bash
# Full preview with troubleshooting
./tools/preview-nerd-fonts.sh

# Icon preview only
./tools/preview-nerd-fonts.sh --preview

# Check installed fonts
./tools/preview-nerd-fonts.sh --check

# Auto-install fonts
./tools/preview-nerd-fonts.sh --install
```

**Features:**

- Icon category preview (dev, files, folders, status)
- Terminal detection (VS Code, iTerm2, Terminal.app)
- Auto-detection of installed Nerd Fonts
- One-click font installation

---

### update-dependencies.sh

Updates all version managers and their packages.

```bash
# Update all version managers
./tools/update-dependencies.sh

# Update specific manager
./tools/update-dependencies.sh --nvm
./tools/update-dependencies.sh --pyenv
./tools/update-dependencies.sh --goenv
./tools/update-dependencies.sh --rustup
./tools/update-dependencies.sh --jenv
./tools/update-dependencies.sh --npm

# Preview: print every planned mutating command (git pull, nvm install,
# rustup update, npm update) without running any of them
./tools/update-dependencies.sh --dry-run
./tools/update-dependencies.sh --dry-run --pyenv
```

At most one target may be given. Under `--dry-run`, read-only version
queries still run and `npm audit` is skipped (it uploads the dependency
tree). Version-manager git checkouts are updated with `git pull --ff-only`:
a diverged checkout is skipped with a warning, never merged into.

**Supported Managers:**

- **nvm** - Node.js version manager
- **pyenv** - Python version manager
- **goenv** - Go version manager
- **rustup** - Rust toolchain manager
- **jenv** - Java version manager
- **npm** - Node.js package manager

---

### update-global-node-symlinks.sh

Creates global symlinks for NVM-managed Node.js.

```bash
# Update symlinks to current NVM version
./tools/update-global-node-symlinks.sh

# Check current status
./tools/update-global-node-symlinks.sh status

# Restore from backup
./tools/update-global-node-symlinks.sh restore /tmp/backup-dir
```

**Why use this?**

Desktop apps (Electron, VS Code extensions, etc.) often look for Node.js in `/usr/local/bin/` instead of using NVM. This creates symlinks so those apps use your NVM-managed Node.js.

**Safety features:**

- Automatic backup before changes
- Sudo access verification
- Restore capability
- Path validation

---

### validate-quality.sh

Runs code quality checks on shell scripts.

```bash
./tools/validate-quality.sh
```

**Checks:**

- ShellCheck static analysis
- Syntax validation
- Best practice compliance

---

### analytics-report.sh

Generates usage analytics reports.

```bash
# Text report
./tools/analytics-report.sh

# JSON format
./tools/analytics-report.sh -f json

# Markdown format
./tools/analytics-report.sh -f markdown -o report.md

# Interactive dashboard
./tools/analytics-report.sh --dashboard

# Privacy information
./tools/analytics-report.sh --privacy
```

**Features:**

- Session and command tracking
- Health scoring
- Usage patterns analysis
- Multiple output formats

---

## Quick Reference

### Daily Use

```bash
# Check environment health
./tools/health-check.sh

# Update all tools
./tools/update-dependencies.sh
```

### Troubleshooting

```bash
# Full diagnostic
./tools/system-diagnostics.sh --full

# Check fonts
./tools/preview-nerd-fonts.sh

# Validate scripts
./tools/validate-quality.sh
```

### Desktop App Issues

```bash
# If desktop apps can't find Node.js
./tools/update-global-node-symlinks.sh
```

---

## Adding New Tools

When creating new tools:

1. Place script in `tools/` directory
2. Add shebang: `#!/usr/bin/env bash`
3. Source logger: `source "$SCRIPT_DIR/lib/logger.sh"`
4. Add `--help` option
5. Update this README
6. Add to Makefile if appropriate

---

## See Also

- [Main README](../README.md) - Project overview
- [API Reference](../docs/API.md) - Library function documentation
- [Contributing](../CONTRIBUTING.md) - Development guidelines
