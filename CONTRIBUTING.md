# Contributing Guide

Thank you for your interest in contributing to the Professional Development Environment Automation Suite!

## Table of Contents

1. [Getting Started](#getting-started)
2. [Development Setup](#development-setup)
3. [Code Standards](#code-standards)
4. [Testing](#testing)
5. [Pull Request Process](#pull-request-process)
6. [Architecture Overview](#architecture-overview)

---

## Getting Started

### Prerequisites

- macOS, Linux, or Windows (WSL)
- Zsh shell
- Git
- ShellCheck (for linting)

### Clone the Repository

```bash
git clone https://github.com/user/version-management-setup.git
cd version-management-setup
```

---

## Development Setup

### 1. Install Development Dependencies

```bash
# macOS
brew install shellcheck

# Ubuntu/Debian
sudo apt-get install shellcheck

# Or use npm
npm install -g shellcheck
```

### 2. Run the Test Suite

```bash
make test
```

### 3. Lint Your Code

```bash
make lint
```

---

## Code Standards

### Shell Script Guidelines

1. **Shebang**: Use `#!/usr/bin/env bash` for portability
2. **Strict Mode**: Include `set -euo pipefail` at the top
3. **ShellCheck**: All scripts must pass ShellCheck (warnings allowed)

```bash
#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

# Your code here
```

### Naming Conventions

| Type | Convention | Example |
|------|------------|---------|
| Scripts | kebab-case | `setup-theme.sh` |
| Functions | snake_case | `install_nvm()` |
| Variables | UPPER_SNAKE | `CACHE_DIR` |
| Local vars | lower_snake | `local file_path` |

### Library Functions

When adding to `lib/`:

1. **Source dependencies** at the top
2. **Document functions** with comments
3. **Export public functions** at the bottom
4. **Validate inputs** before processing

```bash
# Example function template
# Description: Brief description of what this does
# Args: $1 - argument description
# Returns: 0 on success, 1 on failure
my_function() {
    local arg="$1"
    
    if [[ -z "$arg" ]]; then
        log_error "Argument required"
        return 1
    fi
    
    # Implementation
    return 0
}

export -f my_function
```

### Logging

Use the centralized logger (`lib/logger.sh`):

```bash
source "$SCRIPT_DIR/lib/logger.sh"

log_info "Starting process"
log_warn "Config not found, using defaults"
log_error "Failed to complete"
log_success "Done!"
log_debug "Debug info" # Only shown when DEBUG=true
```

---

## Testing

### Test Structure

```
tests/
├── helpers.sh          # Test utilities and assertions
├── test_runner.sh      # Main test orchestrator
├── unit/               # Unit tests for lib/ modules
│   ├── test_env.sh
│   ├── test_logger.sh
│   └── ...
└── integration/        # Integration tests
    ├── test_setup.sh
    └── ...
```

### Writing Tests

```bash
#!/usr/bin/env bash
source ../helpers.sh
source ../../lib/module.sh

test_my_function_success() {
    local result=$(my_function "valid_input")
    assert_equals "expected" "$result" "my_function returns expected value"
}

test_my_function_failure() {
    if ! my_function ""; then
        assert_equals "true" "true" "my_function rejects empty input"
    else
        assert_equals "rejected" "accepted" "Should reject empty input"
    fi
}

# Run tests
echo "=== My Module Tests ==="
test_my_function_success
test_my_function_failure
```

### Running Tests

```bash
# Run all tests
make test

# Run specific test suite
make test-env
make test-logger
make test-gvm

# Run with verbose output
DEBUG=true make test
```

---

## Pull Request Process

### 1. Create a Feature Branch

```bash
git checkout -b feature/your-feature-name
```

### 2. Make Your Changes

- Follow code standards above
- Add/update tests as needed
- Update documentation if applicable

### 3. Test Your Changes

```bash
# Lint
make lint

# Syntax check
make syntax-check

# Run tests
make test
```

### 4. Commit with Clear Messages

```bash
git commit -m "feat: add support for rbenv

- Add lib/rbenv.sh with standard interface
- Add tests/unit/test_rbenv.sh
- Update README with rbenv documentation"
```

### Commit Message Format

- `feat:` New feature
- `fix:` Bug fix
- `docs:` Documentation only
- `test:` Adding tests
- `refactor:` Code refactoring
- `perf:` Performance improvement

### 5. Push and Create PR

```bash
git push origin feature/your-feature-name
```

Then create a Pull Request on GitHub with:

- Clear description of changes
- Link to any related issues
- Screenshots if UI changes

---

## Architecture Overview

### Adding a New Version Manager

1. **Create library module** (`lib/new-manager.sh`):

```bash
#!/usr/bin/env bash
source "${SCRIPT_DIR}/logger.sh"
source "${SCRIPT_DIR}/cache.sh"

newmgr_detect() { ... }
newmgr_install() { ... }
newmgr_list_versions() { ... }
newmgr_install_version() { ... }
newmgr_set_global() { ... }
newmgr_get_current() { ... }
newmgr_is_project() { ... }

export -f newmgr_detect newmgr_install ...
```

2. **Add tests** (`tests/unit/test_new_manager.sh`)

3. **Update Makefile** with test target

4. **Update documentation** (README, docs/API.md)

### Module Dependencies

```
logger.sh (no deps)
    └── env.sh
        └── cache.sh
            └── backup.sh
                └── version managers (nvm.sh, pyvm.sh, etc.)
```

---

## Questions?

If you have questions or need help:

1. Check existing issues on GitHub
2. Review the [API documentation](docs/API.md)
3. Open a new issue with details

Thank you for contributing!
