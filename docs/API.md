# API Reference

## Library Modules (`lib/`)

This document provides a reference for all exported functions in the library modules.

---

## Table of Contents

1. [logger.sh](#loggersh---logging-system)
2. [env.sh](#envsh---environment-detection)
3. [backup.sh](#backupsh---backup-and-restore)
4. [cache.sh](#cachesh---caching-system)
5. [lock.sh](#locksh---atomic-locking)
6. [error-handling.sh](#error-handlingsh---error-handling)
7. [validation.sh](#validationsh---input-validation)
8. [utils.sh](#utilssh---common-utilities)
9. [performance.sh](#performancesh---performance-optimization)
10. [nvm.sh](#nvmsh---nodejs-version-management)
11. [pyvm.sh](#pyvmsh---python-version-management)
12. [gvm.sh](#gvmsh---go-version-management)
13. [jenv.sh](#jenvsh---java-version-management)
14. [rustup.sh](#rustupsh---rust-version-management)
15. [theme-ops.sh](#theme-opssh---theme-operations)

---

## logger.sh - Logging System

Provides color-coded, leveled logging with optional file output.

### Functions

| Function | Description | Usage |
|----------|-------------|-------|
| `log_info` | Log informational message (blue) | `log_info "Starting process"` |
| `log_warn` | Log warning message (yellow) | `log_warn "Config missing"` |
| `log_error` | Log error message (red, to stderr) | `log_error "Failed to connect"` |
| `log_success` | Log success message (green) | `log_success "Complete"` |
| `log_debug` | Log debug message (cyan, when DEBUG=true) | `log_debug "Value: $x"` |

### Environment Variables

- `LOG_FILE` - Path to log file (optional)
- `DEBUG` - Set to "true" to enable debug output

---

## env.sh - Environment Detection

Detects OS, shell, and environment characteristics.

### Functions

| Function | Description | Returns |
|----------|-------------|---------|
| `detect_os` | Detect operating system | `macos`, `linux`, `wsl` |
| `detect_shell` | Detect current shell | `zsh`, `bash` |
| `is_macos` | Check if running on macOS | 0 (true) or 1 (false) |
| `is_linux` | Check if running on Linux | 0 (true) or 1 (false) |
| `validate_env_var` | Validate environment variable exists | 0 or 1 |
| `vms_confirm_privileged` | Canonical consent gate for privileged (sudo) operations | 0 (confirmed) or 1 (declined) |

### `vms_confirm_privileged <subject> [<tag>]`

Canonical consent gate for anything that runs under `sudo`
(ENGINEERING_RULES 1.2: passwordless sudo is not consent; AX-6e). Used by the
installer libraries' build-dependency steps and the Composer publish step;
`lib/shell-experience.sh` delegates its apt gate to it.

- `<subject>` completes the interactive prompt `Install <subject> on this system? [y/N]:`.
- `<tag>` (optional) prefixes the interactive-decline message (`<tag>: skipped <subject>`;
  without a tag: `Skipped <subject>`).

| Condition | Result |
|-----------|--------|
| `VMS_CONFIRM=1` | returns 0, no prompt, no output |
| stdin is a TTY | prompts; `y`/`yes` (any case) returns 0, anything else (including EOF) logs the skip at INFO and returns 1 |
| stdin is not a TTY | `log_warn "Confirmation required to install <subject>; re-run with --confirm or VMS_CONFIRM=1"`, returns 1 |
| empty `<subject>` | logs an error, returns 1 (fails closed) |

Callers must treat any non-zero return as "do not run the privileged
command"; installers then log the exact command for the user to run
themselves and continue with the user-space part of the install. Under
`TRANSACTION_DRY_RUN=1` callers print the planned command instead of calling
the gate.

---

## backup.sh - Backup and Restore

Creates timestamped backups with integrity verification.

Transaction callers use `transaction_start`, `transaction_add_file`, and
`transaction_commit` or `transaction_rollback`. Setting `TRANSACTION_DRY_RUN=1`
when starting a transaction selects a zero-write preview: registration,
commit and rollback emit console diagnostics without appending to `LOG_FILE`
or the audit journal. Apply transactions retain their normal audit trail.
Callers remain responsible for not performing their own writes in preview mode.

Default backup and restore-point storage is resolved from the current absolute
`HOME` when the operation starts (`$HOME/.config-backups`), not when the library
is sourced. An active transaction retains its original directory through commit
or rollback if `HOME` changes. Explicit positional backup-directory arguments
still take precedence. `DEFAULT_BACKUP_DIR` remains a source-time compatibility
snapshot, not an operational override; entry-point-specific `BACKUP_DIR` variables
are not interpreted by this library. Empty or relative HOME fails closed when a
default storage path is required.

### Functions

| Function | Description | Usage |
|----------|-------------|-------|
| `create_backup` | Create timestamped backup | `create_backup "/path/to/file"` |
| `restore_backup` | Restore from backup | `restore_backup "/path/to/backup"` |
| `list_backups` | List available backups | `list_backups` |
| `verify_backup` | Verify backup integrity (SHA-256) | `verify_backup "/path/to/backup"` |
| `install_dir_stage` | Move an existing install directory aside before a fresh install (AX-6d) | `install_dir_stage "$HOME/.pyenv" "$HOME/.pyenv.bak.$ts"` |
| `install_dir_restore` | Undo `install_dir_stage` after a failed install (AX-6d) | `install_dir_restore "$HOME/.pyenv" "$HOME/.pyenv.bak.$ts"` |

### `install_dir_stage <target_dir> <staged_path>` / `install_dir_restore <target_dir> <staged_path>`

Reversible move-aside for installers that replace a whole version-manager
tree (`~/.pyenv`, `~/.nvm`, `~/.goenv`, `~/.jenv`, `~/.phpenv`, `~/.rbenv`).
Installers stage immediately before their git-clone sequence (never before a
Homebrew path, which does not use the directory) and call
`install_dir_restore` on any failure of that sequence. On success the staged
copy is kept as the backup.

- `install_dir_stage`: if `target_dir` exists it is moved to `staged_path`
  (the parent of `staged_path` is created if needed); if it is absent nothing
  happens. Returns 0 on move, absent target, or dry-run; 1 on invalid input,
  an already-existing `staged_path` (never overwritten), or a failed move —
  in every failure case `target_dir` is left exactly where it was.
- `install_dir_restore`: removes a partial `target_dir` (if present), then
  moves `staged_path` back (if `staged_path` is non-empty and exists; an empty
  or missing `staged_path` means nothing was staged). Returns 0 when the
  pre-install state is back; non-zero with a loud error otherwise. The staged
  copy is never deleted, so a failed restore leaves it in place and the error
  names its path.

Validation (both functions, before any `rm`/`mv`; ENGINEERING_RULES 1.5):
`target_dir` must be non-empty, absolute, free of newline/tab and of `.`/`..`
components, not `/`, not `$HOME` or `$TMPDIR` themselves (trailing slashes
normalized), and strictly under `$HOME` or `$TMPDIR` — installers therefore
refuse a custom root such as `PYENV_ROOT=/opt/pyenv`. `staged_path` must be
non-empty, absolute, free of newline/tab and `.`/`..` components, not `/`,
not `$HOME`/`$TMPDIR`, and must not equal, contain, or lie inside
`target_dir`.

Under `TRANSACTION_DRY_RUN=1` both print their plan and touch nothing. Every
real move/removal is appended to the audit journal (`TXN_AUDIT_LOG`, default
`$HOME/.config/version-manager/audit.log`) as `install_dir_stage`,
`install_dir_remove_partial` or `install_dir_restore`; journaling works with
or without an active transaction and never blocks the operation.

`lib/backup.sh` is re-source-safe: sourcing it again (the installer libraries
source it unconditionally) preserves an active transaction's state.

---

## cache.sh - Caching System

File-based caching with TTL and automatic cleanup.

### Functions

| Function | Description | Usage |
|----------|-------------|-------|
| `cache_set` | Store value with TTL | `cache_set "key" "value" 300` |
| `cache_get` | Retrieve cached value | `value=$(cache_get "key")` |
| `cache_delete` | Delete cache entry | `cache_delete "key"` |
| `cache_clear` | Clear all cache | `cache_clear` |
| `cache_cleanup` | Remove expired entries | `cache_cleanup` |
| `cache_namespace_get` | Retrieve namespaced cached value | `value=$(cache_namespace_get "commands" "node")` |
| `cache_namespace_set` | Store namespaced value | `cache_namespace_set "commands" "node" "1"` |
| `cache_namespace_clear` | Clear one namespaced entry or namespace | `cache_namespace_clear "commands" "node"` |
| `cache_namespace_clear_all` | Clear all namespaced cache data | `cache_namespace_clear_all` |
| `cache_exec_argv` | Execute argv and cache successful output | `cache_exec_argv "key" 300 git status --short` |
| `cache_safe_execute` | Compatibility wrapper for `cache_exec_argv` | `cache_safe_execute "key" 300 git status --short` |

### Namespace Safety

- Cache namespaces must match `^[A-Za-z0-9_-]+$`; invalid namespaces are rejected before any deletion.
- `cache_exec_argv` and `cache_safe_execute` accept `key ttl cmd [args...]`. Command arguments are argv values and are inert, not shell strings.

### TTL Defaults (seconds)

- `TTL_VERSION_CHECK` - 600 (10 min)
- `TTL_COMMAND_CHECK` - 3600 (1 hour)
- `TTL_FILE_CHECK` - 60 (1 min)

---

## lock.sh - Atomic Locking

Atomic mkdir-based locks for workstation-mutating entry points.

### Functions

| Function | Description | Usage |
|----------|-------------|-------|
| `lock_acquire` | Acquire an atomic mkdir lock; name must match `^[A-Za-z0-9_-]+$`; stale locks from dead processes are auto-reclaimed | `lock_acquire "setup" 30` |
| `lock_release` | Release a lock only when owned by the current process pid | `lock_release "setup"` |
| `lock_with_trap` | Acquire a lock and chain release onto the EXIT trap; **must be the last EXIT-trap registration in the script** | `lock_with_trap "setup" 30` |

### Environment Variables

- `VMS_STATE_DIR` - State directory override (default: `~/.local/state/version-manager`); locks live under `$VMS_STATE_DIR/locks/`

### Trap Contract

A later `trap ... EXIT` replaces the chain installed by `lock_with_trap` and leaks the lock until stale reclaim.

---

## error-handling.sh - Error Handling

Standardized error handling with retry logic.

### Functions

| Function | Description | Usage |
|----------|-------------|-------|
| `handle_error` | Handle and log errors | `trap 'handle_error $LINENO' ERR` |
| `safe_exec_argv` | Execute argv with retry (preferred; args are inert) | `SAFE_EXEC_RETRIES=3 safe_exec_argv curl -fsSL "$url"` |
| `safe_exec_backoff_argv` | Argv retry with exponential backoff | `safe_exec_backoff_argv git clone "$repo"` |
| `safe_exec_shell_trusted` | Trusted-literal shell string (pipes ok; literals ONLY) | `safe_exec_shell_trusted "ls \| wc -l"` |
| `safe_exec` | DEPRECATED — use `safe_exec_argv` | `safe_exec "curl url" 3 2` |
| `safe_exec_backoff` | DEPRECATED — use `safe_exec_backoff_argv` | `safe_exec_backoff "cmd" 5` |
| `require_command` | Validate command exists | `require_command "git"` |
| `require_file` | Validate file exists | `require_file "/path"` |
| `setup_error_trap` | Enable error trapping | `setup_error_trap` |

### Environment Variables

- `SAFE_EXEC_RETRIES` - Max attempts for `safe_exec_argv` and `safe_exec_backoff_argv`
- `SAFE_EXEC_DELAY` - Linear delay for `safe_exec_argv`; initial delay for `safe_exec_backoff_argv`

### Deprecation Notes

- `safe_exec` and `safe_exec_backoff` are string-command compatibility APIs. They emit a one-time deprecation warning on stderr per shell session; new code should use argv APIs.

---

## validation.sh - Input Validation

Security-focused input validation functions.

### Functions

| Function | Description | Usage |
|----------|-------------|-------|
| `validate_not_empty` | Check string not empty | `validate_not_empty "$var" "name"` |
| `validate_semver` | Validate semantic version | `validate_semver "1.2.3"` |
| `validate_safe_path` | Check path for dangerous chars | `validate_safe_path "$path"` |
| `validate_file_readable` | Check file is readable | `validate_file_readable "$f"` |
| `validate_positive_int` | Validate positive integer | `validate_positive_int "$n"` |
| `validate_option` | Validate against allowed options | `validate_option "$x" "a" "b"` |

---

## utils.sh - Common Utilities

General-purpose utility functions.

### Functions

| Function | Description | Usage |
|----------|-------------|-------|
| `has_command` | Check if command exists | `has_command "git"` |
| `file_exists` | Check if file exists | `file_exists "/path"` |
| `dir_exists` | Check if directory exists | `dir_exists "/path"` |
| `ensure_dir` | Create directory if missing | `ensure_dir "/path"` |
| `trim` | Trim whitespace | `result=$(trim "  text  ")` |
| `version_compare` | Compare semantic versions | `version_compare "1.2" "1.3"` |
| `get_os` | Get OS type | `os=$(get_os)` |
| `is_zsh` | Check if running zsh | `is_zsh && echo "zsh"` |
| `has_internet` | Check internet connectivity | `has_internet && curl ...` |

---

## performance.sh - Performance Optimization

Shell startup optimization and monitoring.

### Functions

| Function | Description | Usage |
|----------|-------------|-------|
| `setup_nvm_lazy` | Enable NVM lazy loading | `setup_nvm_lazy` |
| `setup_pyenv_lazy` | Enable pyenv lazy loading | `setup_pyenv_lazy` |
| `measure_shell_startup` | Measure shell startup time | `ms=$(measure_shell_startup)` |
| `perf_report` | Generate performance report | `perf_report` |
| `detect_version_managers_parallel` | Detect all version managers | `detect_version_managers_parallel` |

---

## nvm.sh - Node.js Version Management

Node.js version management via nvm.

### Functions

| Function | Description | Usage |
|----------|-------------|-------|
| `nvm_detect` | Check if nvm installed | `nvm_detect && echo "yes"` |
| `nvm_install` | Install nvm | `nvm_install` |
| `nvm_list_versions` | List installed versions | `nvm_list_versions` |
| `nvm_install_version` | Install specific version | `nvm_install_version "20.10.0"` |
| `nvm_set_global` | Set global default | `nvm_set_global "20.10.0"` |
| `source_nvm_if_available` | Source nvm if present | `source_nvm_if_available` |

---

## pyvm.sh - Python Version Management

Python version management via pyenv.

### Functions

| Function | Description | Usage |
|----------|-------------|-------|
| `pyvm_detect` | Check if pyenv installed | `pyvm_detect` |
| `pyvm_install` | Install pyenv | `pyvm_install` |
| `pyvm_list_versions` | List installed versions | `pyvm_list_versions` |
| `pyvm_install_version` | Install specific version | `pyvm_install_version "3.12.0"` |
| `pyvm_set_global` | Set global default | `pyvm_set_global "3.12.0"` |

---

## gvm.sh - Go Version Management

Go version management via goenv.

### Functions

| Function | Description | Usage |
|----------|-------------|-------|
| `gvm_detect` | Check if goenv installed | `gvm_detect` |
| `gvm_install_version` | Install Go version | `gvm_install_version "1.21.0"` |
| `gvm_is_go_project` | Check for Go project files | `gvm_is_go_project` |

---

## jenv.sh - Java Version Management

Java version management via jenv.

### Functions

| Function | Description | Usage |
|----------|-------------|-------|
| `jenv_detect` | Check if jenv installed | `jenv_detect` |
| `jenv_add_version` | Add Java installation | `jenv_add_version "/path"` |
| `jenv_is_java_project` | Check for Java project files | `jenv_is_java_project` |

---

## rustup.sh - Rust Version Management

Rust toolchain management via rustup.

### Functions

| Function | Description | Usage |
|----------|-------------|-------|
| `rustup_detect` | Check if rustup installed | `rustup_detect` |
| `rustup_install_version` | Install Rust version | `rustup_install_version "1.75.0"` |
| `rustup_is_rust_project` | Check for Rust project files | `rustup_is_rust_project` |

---

## theme-ops.sh - Theme Operations

PowerLevel10k theme management.

### Functions

| Function | Description | Usage |
|----------|-------------|-------|
| `theme_validate` | Validate theme exists | `theme_validate "professional"` |
| `theme_detect_current` | Detect active theme | `current=$(theme_detect_current)` |
| `theme_switch` | Switch to theme | `theme_switch "professional"` |
| `theme_list_available` | List available themes | `theme_list_available` |
| `theme_reset` | Reset to default theme | `theme_reset` |

---

## auto-activate.sh - Runtime Hooks and Trust

`auto_activate_setup` installs the zsh runtime hook into `${ZDOTDIR:-$HOME}/.zshrc`;
`auto_activate_remove` removes only its managed block. Both retain their no-argument
API. Set `TRANSACTION_DRY_RUN=1` for a console-only, zero-write plan.

Apply mode requires the shared `workstation-config` lock and uses the existing
backup transaction plus managed-block editor. Generated and resulting files are
checked with `zsh -n`; failures roll back registered content and symlinks. Nested
transactions, non-regular targets, duplicate/unbalanced markers and old
`# >>> dev auto-activate hook <<<` delimiters are refused without changing the rc
file. Legacy blocks require explicit review/migration; they are never silently
removed. Trust-registry APIs and runtime capability decisions are unchanged.
Dependencies: logger, backup, mutation, validation and lock libraries; zsh for
apply verification. Nonzero status means refusal or failed application/rollback.

## Usage Example

```bash
#!/usr/bin/env bash
# Example script using library modules

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/logger.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/error-handling.sh"

setup_error_trap

log_info "Starting process..."

if has_command "node"; then
    log_success "Node.js found"
else
    log_warn "Node.js not found"
fi
```
