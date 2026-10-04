# Security Model

This suite's prime engineering constraint is the **safe mutation of a
developer workstation**: it edits shell rc files, fonts, IDE settings,
version managers, and system paths. This document describes what the suite
is allowed to touch, the gates every mutation passes through, and how to
report a problem. The binding rules live in
[ENGINEERING_RULES.md](governance/ENGINEERING_RULES.md); the mutation
inventory lives in [MUTATION_REGISTRY.md](governance/MUTATION_REGISTRY.md).

## Trust boundaries — what mutates what

| Surface | Path | Written by | Safeguards |
|---------|------|------------|------------|
| Shell rc files | `~/.zshrc` | `scripts/fix-nvm-issues.sh`, `version-manager.sh` (lazy-load/auto-switch blocks) | Managed blocks `# BEGIN version-management-setup:<name>` … `# END` edited atomically under a backup transaction (`lib/mutation.sh`) |
| Prompt configuration | `~/.p10k.zsh` | `setup-theme.sh`, `scripts/fix-terminal-issues.sh fix-p10k` | Whole-file replace under a transaction; byte-compare idempotency; atomic rename |
| Fonts | `~/Library/Fonts` (macOS) or `~/.local/share/fonts` (Linux) | `setup-fonts-enhanced.sh`, `scripts/fix-terminal-issues.sh fix-fonts` | Transaction-routed installs; dry-run plans network installers without launching them |
| VS Code settings | `settings.json`, `keybindings.json`, `snippets`, `extensions.json` under the platform User dir | `scripts/generate-vscode-settings.sh`, theme setup | Backed up via `create_vscode_backup` before changes |
| Version managers | `$HOME/.nvm`, `~/.pyenv`, `~/.rbenv`, `~/.gvm`, `~/.jenv`, `~/.rustup`, `~/.phpenv`, `~/.fnm` | `version-manager.sh`, `setup-versions.sh` | Locked installs (`lib/lock.sh`); version pins; no pipe-to-shell |
| Auto-activation hook | shell `chpwd` hook, per project | `lib/auto-activate.sh` | Trust registry (see below): untrusted projects get version *switching* only — no installs, no repo-script sourcing, no symlink sync |
| Global node symlinks | `/usr/local/bin/{node,npm,npx}` | `tools/update-global-node-symlinks.sh` | Plan-by-default (`--dry-run` is the default), explicit `--confirm` to apply, backup + restore of replaced links |
| `/etc/shells` | append zsh path | `scripts/fix-terminal-issues.sh fix-shell` | Diff preview, timestamped backup, consent gate (interactive prompt, `--confirm`, or `VMS_CONFIRM=1`); skipped otherwise |
| Default shell | `chsh -s` | `scripts/fix-terminal-issues.sh fix-shell` | Only after the `/etc/shells` gate passes |

Anything not in this table is read-only. The authoritative per-script
mutation census (237 sinks across 41 mutating scripts) is published in
[MUTATION_REGISTRY.md](governance/MUTATION_REGISTRY.md).

## The gate model

Every mutation passes through four gates. The invariant (remediation
directive "Mutation invariant"): every workstation mutation is
**plan-visible**, **idempotent**, **reversible**, and **journaled**.

1. **Plan / dry-run.** `TRANSACTION_DRY_RUN=1` (or the script's
   `--dry-run` flag) makes the whole apply path write-free: plans and diffs
   are printed, zero filesystem writes occur. Mutating scripts default to
   plan output where the mutation is privileged.
2. **Confirm.** Interactive prompts, `--confirm` flags, or typed
   confirmation (the emergency-recovery `RESET` prompt). A passwordless
   sudo environment is **not** implicit consent (ENGINEERING_RULES §1.2).
3. **Transaction.** `transaction_start` / `transaction_add_file` /
   `transaction_commit` / `transaction_rollback` (`lib/backup.sh`): each
   registered file gets a hash-recorded backup in an exclusive
   `mktemp -d` directory; new files are recorded for removal. Rollback is
   **hash-verified and tamper-refusing** — a corrupted backup payload is
   never presented as a successful restore, and a partial rollback exits
   nonzero with status `rolled_back_with_errors` instead of claiming
   success.
4. **Audit journal.** Every transaction start/commit/rollback and every
   managed-block write/remove records an entry (see below).

## Installer policy

- **Never `curl | bash` / `curl | sh`** — in project code or generated
  templates (ENGINEERING_RULES §2.3). The version-manager installer
  actively refuses remote-script execution for fnm
  (`version-manager.sh`: "Refusing to execute remote install scripts
  (curl|bash)") and falls back to the package manager.
- Preferred installation channels, in order: platform package manager
  (`brew`, `apt`), official setup tooling (language setup actions in
  generated CI), then download → **checksum-verify** → execute.
- Vendored assets (`FontPatcher/`) keep their upstream license files;
  attribution is consolidated in
  [../FontPatcher/ATTRIBUTION.md](../FontPatcher/ATTRIBUTION.md).
- Font files are checksum-verified locally (`lib/fonts.sh`:
  `font_generate_checksums`); the four MesloLGS `.ttf` files are
  user-supplied, never downloaded by this suite.
- Remote installer invocations that exist (oh-my-posh font installer,
  Homebrew casks in `setup-fonts-enhanced.sh`) are third-party official
  tools and are **plan-only under dry-run** — they are not launched when
  planning.

## Privilege model

- `sudo` is used in exactly two places: `sudo ln -sf` /
  `sudo cp -P` into `/usr/local/bin`
  (`tools/update-global-node-symlinks.sh`) and
  `sudo tee -a /etc/shells` (`scripts/fix-terminal-issues.sh`). Both are
  consent-gated as described above. `sudo` package installs are limited to
  well-known distro packages (ENGINEERING_RULES §7.3).
- **Auto-activation trust registry (M3).** The shell `chpwd` hook may only
  switch between already-installed versions by default. Capabilities
  beyond that — sourcing a project venv, installing a missing Node
  version, syncing symlinks — require the project to be trusted in the
  per-project registry at `~/.config/version-manager/trusted-projects`
  (canonical-path SHA-256 keyed, symlink-proof). Grant or revoke with
  `auto_trust <dir> <capability>` / `auto_untrust <dir> <capability>`.
  `auto_is_trusted` fails closed: any doubt (missing registry,
  unresolvable directory, unknown capability, no sha256 tool) means *not
  trusted*.

## Audit journal and logs

- **Audit journal:** `~/.config/version-manager/audit.log`
  (override: `TXN_AUDIT_LOG`). Tab-delimited records:
  ISO-8601 timestamp, event (`start`, `commit`, `rollback`,
  `mutation_write`, `mutation_remove`), transaction name, transaction
  directory, detail (mode, file, block, file counts, rollback status and
  error count). Journaling is best-effort: a journal failure is surfaced
  as a warning but never blocks rollback safety.
- **Application logs:** `~/.local/share/version-manager/logs/`
  (`version-manager-<date>.log`; override `LOG_FILE`). All human-facing
  log output goes to stderr so value-returning functions keep clean
  stdout.
- **Backups:** `~/.config-backups/` — timestamped file backups,
  `transactions/<name>.XXXXXX/` transaction state, and
  `restore_points/<name>/` named restore points.

## Reporting

Do **not** open a public issue for a security vulnerability. Use the
repository host's private security-advisory channel (GitHub: the
repository's *Security* tab → *Report a vulnerability*) or contact the
maintainers directly. Include: affected script, the mutation involved, and
—if possible—a dry-run transcript that reproduces the unsafe plan in a
sandboxed `$HOME`.

## Known gaps (honest state)

- Transaction adoption covers the six directive-named mutators
  (fix-nvm-issues, setup-versions, fix-terminal-issues,
  update-global-node-symlinks, setup-fonts-enhanced, emergency-recovery)
  plus the theme path; the broader cache/state-writer class is scheduled
  for continued adoption (see MUTATION_REGISTRY.md).
- `tools/system-diagnostics.sh` still prints historical pipe-to-shell
  snippets as advisory *text* in its output; it executes nothing, but the
  snippets are scheduled for replacement (remediation directive §B, item
  8).
- `make clean` cleanup scope (B2.2) and the SCRIPT_DIR-hygiene pass
  (A5-new) are open M5 items; see
  [ROADMAP.md](governance/ROADMAP.md) for current status.
