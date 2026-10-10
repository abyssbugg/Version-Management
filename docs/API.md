# API Reference

## Library Modules (`lib/`)

This document is the library's public API. It is enforced, not
aspirational: `tests/unit/test_api_conformance.sh` (P3-4) fails the build when
the code and this file disagree.

## Conventions

- **Public** — a function listed in the table of its owning module's section
  below. Only public functions may be called outside the module that defines
  them (by other modules, entry scripts, tools or plugins).
- **Module-internal** — any other function. A `_` prefix marks it private; an
  unprefixed but unlisted function is internal too (legacy naming) and must
  not be called from outside its module. To use one elsewhere, document it
  here first.
- **Framework-internal helpers** — the few private functions the framework's
  own adopters share are listed, with their owner, in
  [Framework-internal helpers](#framework-internal-helpers). They are stable
  for in-repository code only; no other private function may be referenced
  outside its module.
- **One owner per name** — a function name is defined at top level by one
  `lib/` module (ENGINEERING_RULES 5.2). Fallback shims inside an
  `if ! declare -f name` block are indented and exempt.
- **Every module is documented** — each `lib/*.sh` has a section here
  (ENGINEERING_RULES 5.3), so adding a module or calling an undocumented
  function from another file fails `test_api_conformance.sh`.

The check is static. Definitions and calls inside here-documents (the plugin
template, generated scripts) are ignored, as are functions nested inside other
functions (the lazy-load `nvm`/`node` command shims in `performance.sh`).

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
16. [auto-activate.sh](#auto-activatesh---runtime-hooks-and-trust)
17. [mutation.sh](#mutationsh---managed-mutations)
18. [fonts.sh](#fontssh---font-management)
19. [metrics.sh](#metricssh---local-usage-metrics)
20. [phpenv.sh](#phpenvsh---php-version-management)
21. [fnm.sh](#fnmsh---fast-node-manager)
22. [plugins.sh](#pluginssh---plugin-system)
23. [shell-experience.sh](#shell-experiencesh---shell-experience-tools)
24. [Framework-internal helpers](#framework-internal-helpers)

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
| `detect_shell` | Detect the running shell (`$SHELL`, then `ps`, then version variables) | `zsh`, `bash` |
| `get_os` | Canonical OS name (alias of `detect_os`; P1-9) | `macos`, `linux`, `wsl`, `windows`, `unknown` |
| `get_shell` | Login-shell name: basename of `$SHELL`, default `bash` (distinct from `detect_shell`) | `zsh`, `bash`, ... |
| `validate_env_var` | Validate environment variable exists | 0 or 1 |
| `command_exists` | `command -v` probe (shared shim, ROADMAP 4.2; a caller's own definition wins) | 0 or 1 |
| `log` | Level wrapper over the logger: `log ERROR\|WARN\|INFO\|SUCCESS\|DEBUG <message>` (shared shim) | — |
| `check_nvm_installed` | nvm available (command, or `$NVM_DIR/nvm.sh`) | 0 or 1 |
| `check_pyenv_installed` | pyenv available | 0 or 1 |
| `check_nvm_silent_configured` | `NVM_SILENT` set in the environment or the shell rc files | 0 or 1 |
| `get_shell_config` | rc file the managed blocks target (canonical, AX-17) | `~/.zshrc`; bash: `~/.bashrc` if present else `~/.bash_profile`; others (incl. fish): `~/.profile` |
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
| `validate_backup` | Check a backup against its original: same size and same SHA-256 (`sha256sum` or `shasum`; size only, with a warning, when the host has neither) | `validate_backup "$orig" "$backup"` |
| `transaction_start` | Start a backup transaction (name: `[A-Za-z0-9][A-Za-z0-9_-]{0,62}`; `TRANSACTION_DRY_RUN=1` = zero-write preview) | `transaction_start "theme_install"` |
| `transaction_add_file` | Register a file's pre-state (backup, or "did not exist") before changing it | `transaction_add_file "$HOME/.zshrc"` |
| `transaction_commit` | Finish the transaction; backups are kept | `transaction_commit` |
| `transaction_rollback` | Restore every registered file hash-verified; non-zero (1..255) when any restore fails | `transaction_rollback` |
| `transaction_is_active` | A transaction is open in this shell | `transaction_is_active && ...` |
| `create_restore_point` | Snapshot named files under a restore-point name | `create_restore_point "before_theme" "$HOME/.zshrc"` |
| `list_restore_points` | List restore points | `list_restore_points` |
| `restore_from_point` | Restore a restore point (`RESTORE_ALL_OR_NOTHING=1`: transactional, all-or-nothing) | `restore_from_point "before_theme"` |
| `delete_restore_point` | Delete a restore point | `delete_restore_point "before_theme"` |
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
components, not `/`, and not `$HOME` or `$TMPDIR` themselves (trailing
slashes normalized). `staged_path` must be non-empty, absolute, free of
newline/tab and `.`/`..` components, not `/`, not `$HOME`/`$TMPDIR`, and must
not equal, contain, or lie inside `target_dir`.

A custom root outside `$HOME`/`$TMPDIR` (`PYENV_ROOT=/opt/pyenv`,
`NVM_DIR=/usr/local/nvm`) is supported conservatively: an absent target needs
no staging (a fresh install proceeds); a present one is moved aside unless it
is a system root (a top-level directory, a second-level directory under an
OS-owned root such as `/usr/local`, a package-manager prefix such as
`/opt/homebrew`, or an ancestor of `$HOME`/`$TMPDIR`), which is refused; and
`install_dir_restore` never `rm -rf`s outside `$HOME`/`$TMPDIR` — a partial
install there is left in place with the staged copy, the manual steps are
logged, and it returns 1.

Under `TRANSACTION_DRY_RUN=1` both print their plan and touch nothing. Every
real move/removal is appended to the audit journal (`TXN_AUDIT_LOG`, default
`$HOME/.config/version-manager/audit.log`) as `install_dir_stage`,
`install_dir_remove_partial` or `install_dir_restore`; journaling works with
or without an active transaction and never blocks the operation.

`lib/backup.sh` is re-source-safe: sourcing it again (the installer libraries
source it unconditionally) preserves an active transaction's state.

### Audit journal record (P3-2)

Applied operations append one line to `TXN_AUDIT_LOG` (default
`$HOME/.config/version-manager/audit.log`); previews append nothing.

```text
<ISO-8601 time> TAB <event> TAB <transaction> TAB <transaction dir = backup id> TAB <detail>
```

`<detail>` is space-separated `key=value`. Every record carries
`script=<entry point> pid=<pid> mode=apply result=<outcome> exit_code=<n>`
and either `target=<path>` (per-file events) or `files=<n>` (transaction
events); operations outside a transaction (`install_dir_*`) state
`backup=<path|none>`. Events: `start`, `register` (`result=backed_up` or
`tracked_new`), `commit` (`committed`), `rollback` (`rolled_back`, or
`rolled_back_with_errors` with a non-zero `exit_code`), `mutation_write`,
`mutation_remove`, `mutation_publish`, `install_dir_stage`,
`install_dir_remove_partial`, `install_dir_restore`, `shellxp_*`. Pinned by
`tests/unit/test_audit_journal_schema.sh`.

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
| `cache_key` | Build a cache key from namespace, identifier and optional context | `key=$(cache_key "versions" "node")` |
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
| `validate_identifier` | Strict identifier grammar (alnum first, then `[A-Za-z0-9._-]`, no `..`; max length, default 64) | `validate_identifier "$name" 48` |
| `path_validate_containment` | Canonical (symlink-resolved) path lies inside a base directory; sibling-proof | `path_validate_containment "$p" "$base"` |
| `validate_node_version` | Node.js version format (optional `v`) | `validate_node_version "20.10.0"` |
| `validate_python_version` | Python version format | `validate_python_version "3.12.0"` |
| `validate_ruby_version` | rbenv version name: alnum first, then `[A-Za-z0-9._+-]` (injection guard) | `validate_ruby_version "3.3.0"` |
| `validate_php_version` | phpenv version name, same grammar as Ruby | `validate_php_version "8.3.0"` |

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
| `is_macos` | `get_os` is `macos` (platform API lives in `env.sh`) | `is_macos && ...` |
| `is_linux` | `get_os` is `linux` | `is_linux && ...` |
| `contains` | String contains a substring | `contains "hello world" "world"` |
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
| `cache_version` | Cached output of an argv command (args are inert) | `v=$(cache_version "node" node --version)` |

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

| Function | Description | Usage |
|----------|-------------|-------|
| `auto_activate_setup` | Install the zsh runtime hook as a managed block (locked, transactional) | `auto_activate_setup` |
| `auto_activate_remove` | Remove only that managed block | `auto_activate_remove` |

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

---

## mutation.sh - Managed Mutations

The one editor for user files (P3-1/B2.1): managed blocks
(`# BEGIN version-management-setup:<name>` ... `# END ...`) and whole-file
publication. Every writer requires an active transaction, registers the
pre-state before writing, writes atomically (same-directory temp + rename,
symlinks kept), verifies, is idempotent, and plans only under
`TRANSACTION_DRY_RUN=1`. Sources `backup.sh` and `validation.sh`.

| Function | Description | Usage |
|----------|-------------|-------|
| `mutation_block_write` | Insert or replace a managed block; refuses malformed markers (AX-8) | `mutation_block_write "$rc" nvm "$content_file"` |
| `mutation_block_remove` | Remove a managed block (`MUTATION_REMOVE_TOLERANT=1`: absent is OK) | `mutation_block_remove "$rc" nvm` |
| `mutation_block_has` | The file contains a well-formed block of that name | `mutation_block_has "$rc" nvm` |
| `mutation_block_get` | Print a block's body | `mutation_block_get "$rc" nvm` |
| `mutation_file_publish` | Publish a whole generated file (see below) | `mutation_file_publish "$file" "$content_file"` |
| `mutation_files_identical` | Byte-identical check (`cmp` when present, else SHA-256) | `mutation_files_identical "$a" "$b"` |
| `mutation_resolve_content_target` | Resolve a symlink chain to its content file; sets `_MUTATION_RESOLVED_TARGET` | `mutation_resolve_content_target "$rc"` |
| `mutation_begin_marker` | Print the BEGIN marker line for a block name | `mutation_begin_marker nvm` |
| `mutation_end_marker` | Print the END marker line | `mutation_end_marker nvm` |
| `mutation_nvm_block` | Print the canonical NVM block body (`NVM_SILENT=true`, P1-3) | `mutation_nvm_block > "$tmp"` |

### `mutation_file_publish <file> <content-file>` (`lib/mutation.sh`)

Publishes a whole generated file (AX-18; used by the `version-advanced.sh`
Dockerfile, docker-compose and CI generators). Requires an active
transaction. The pre-state — including "did not exist" — is registered
before the write, so `transaction_rollback` restores or removes the file
byte-identically. A symlinked target stays a link (the atomic rename lands
on the resolved file); a target that exists but is not a regular file is
refused; the existing mode is kept (new files get 0644); identical content
is a no-op (nothing registered, mtime unchanged); the published bytes are
verified. Under `TRANSACTION_DRY_RUN=1` it prints `[dry-run] would
create|replace: <file>` and writes nothing, not even the parent directory.

---

## fonts.sh - Font Management

Nerd Font detection and installation. Writers (`font_install_bundled`,
`font_install_from_url`, `font_uninstall`) are transactional (AX-19); the
caller holds the `workstation-mutation` lock.

| Function | Description | Usage |
|----------|-------------|-------|
| `font_install_bundled` | Install the repository's MesloLGS fonts; a failed publish rolls back the whole call | `font_install_bundled` |
| `font_install_from_url` | Install one font: https URL, plain `.ttf`/`.otf` name, required SHA-256 | `font_install_from_url "$url" "Name.ttf" "$sha256"` |
| `font_uninstall` | Remove installed fonts transactionally | `font_uninstall` |
| `font_is_installed` | A font of that name is installed | `font_is_installed "MesloLGS NF"` |
| `font_status` | Print the font status report | `font_status` |

---

## metrics.sh - Local Usage Metrics

Opt-in, local-only usage statistics (`tools/analytics-report.sh`).

| Function | Description | Usage |
|----------|-------------|-------|
| `metrics_init` | Create the metrics store | `metrics_init` |
| `metrics_record` | Record an event: category, action, optional label/value | `metrics_record command run` |
| `metrics_get_stat` | Print one statistic | `metrics_get_stat total_commands` |
| `metrics_dashboard` | Print the analytics dashboard | `metrics_dashboard` |
| `metrics_export_json` | Export metrics as JSON | `metrics_export_json` |
| `metrics_privacy` | Print what is collected and where it stays | `metrics_privacy` |
| `metrics_enable` | Enable collection | `metrics_enable` |
| `metrics_disable` | Disable collection | `metrics_disable` |

---

## phpenv.sh - PHP Version Management

PHP version management via phpenv, plus Composer.

| Function | Description | Usage |
|----------|-------------|-------|
| `phpenv_detect` | phpenv available | `phpenv_detect` |
| `phpenv_install` | Install phpenv (reversible move-aside, AX-6d) | `phpenv_install` |
| `phpenv_install_version` | Install a PHP version (plan only under dry-run) | `phpenv_install_version "8.3.12"` |
| `phpenv_set_global` | Set the global PHP version | `phpenv_set_global "8.3.12"` |
| `composer_detect` | Composer available | `composer_detect` |
| `composer_install` | Install Composer; fails closed on a missing/mismatched signature, verifies the binary, consent-gated `sudo` (AX-6f) | `composer_install` |

---

## fnm.sh - Fast Node Manager

| Function | Description | Usage |
|----------|-------------|-------|
| `fnm_detect` | fnm available | `fnm_detect` |
| `fnm_install` | Install fnm (package manager; no `curl \| bash`) | `fnm_install` |
| `fnm_install_version` | Install a Node.js version | `fnm_install_version "20.19.2"` |
| `fnm_set_global` | Set the default Node.js version | `fnm_set_global "20.19.2"` |

---

## plugins.sh - Plugin System

Loads, validates and runs `plugins/*.sh` (contract: [PLUGINS.md](PLUGINS.md)).
Plugin names pass `validate_identifier` and paths `path_validate_containment`
before anything is loaded, written or removed (B1.1); installs and removals
are transactional. The per-plugin interface (`plugin_info`, `plugin_init`,
`plugin_detect`, `plugin_install`, ...) is defined by each plugin, not here.

| Function | Description | Usage |
|----------|-------------|-------|
| `plugin_system_init` | Create the plugin directories and load enabled plugins | `plugin_system_init` |
| `plugin_load` | Load one plugin file after validation | `plugin_load "/path/to/plugin.sh"` |
| `plugin_load_all` | Load every enabled plugin | `plugin_load_all` |
| `plugin_list_available` | List available plugins | `plugin_list_available` |
| `plugin_run` | Run a plugin function (both names grammar-checked) | `plugin_run asdf install` |
| `plugin_install_from_file` | Install a plugin file into the enabled directory | `plugin_install_from_file "./my.sh" my` |
| `plugin_remove` | Remove an installed plugin | `plugin_remove my` |
| `plugin_create_template` | Write a new plugin skeleton | `plugin_create_template my_plugin ./my_plugin.sh` |

---

## shell-experience.sh - Shell-Experience Tools

Provisions shell tools (fzf, zoxide, eza, bat, fd, ripgrep, direnv,
zsh-autosuggestions, zsh-syntax-highlighting) and manages the zsh
`plugins=( ... )` array. Plan by default; `--confirm` applies, `--dry-run`
plans; every change is transactional.

| Function | Description | Usage |
|----------|-------------|-------|
| `shellxp_list_tools` | List the tool registry | `shellxp_list_tools` |
| `shellxp_status` | Print which tools are present | `shellxp_status` |
| `shellxp_install` | Install a tool: plan by default, `--confirm` to apply, `--dry-run` | `shellxp_install fzf --confirm` |
| `shellxp_plugins_list` | Print the zsh `plugins=()` entries | `shellxp_plugins_list` |
| `shellxp_plugins_add` | Add an entry to `plugins=()` (managed, transactional) | `shellxp_plugins_add zsh-autosuggestions --confirm` |
| `shellxp_plugins_remove` | Remove an entry from `plugins=()` | `shellxp_plugins_remove zsh-autosuggestions --confirm` |

---

## Framework-internal helpers

Private functions that the framework's own adopters share. Stable for code
in this repository only; scripts outside it must use the public API.

| Function | Owner | Shared with | Purpose |
|----------|-------|-------------|---------|
| `_txn_journal` | `lib/backup.sh` | `mutation.sh`, `shell-experience.sh`, VS Code/icon/slick-terminal writers | Append one audit-journal record (format above) |
| `_txn_sha256` | `lib/backup.sh` | `mutation.sh`, VS Code/icon/slick-terminal writers, node symlink tool | SHA-256 of a file (`sha256sum` or `shasum -a 256`) |
| `_mutation_preserve_mode` | `lib/mutation.sh` | `shell-experience.sh`, rc writers in `version-manager.sh`, `setup-versions.sh`, `fix-nvm-issues.sh` | Copy a file's mode onto its replacement before the rename |
| `_vms_privileged_steps` | `lib/env.sh` | `phpenv.sh`, `pyvm.sh`, `version-manager.sh` | Plan, confirm (`vms_confirm_privileged`), then run privileged argv commands |
| `_path_realpath` | `lib/validation.sh` | `plugins.sh` | Resolve symlinks fully; fails closed |

---

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
