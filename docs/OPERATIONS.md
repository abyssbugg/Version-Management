# Operations Runbook

Operational procedures for running, verifying, and recovering the
Professional Development Terminal Setup on a workstation, plus the CI and
release paths. Security context: [SECURITY.md](SECURITY.md). Mutation
inventory: [governance/MUTATION_REGISTRY.md](governance/MUTATION_REGISTRY.md).

## Operator quick map

| Task | Command |
|------|---------|
| Interactive setup (menu) | `./setup.sh` |
| Install/apply the theme | `./setup-theme.sh professional` |
| Configure version managers | `./setup-versions.sh` |
| Install fonts | `./setup-fonts-enhanced.sh --dry-run` first, then without the flag |
| Diagnose terminal issues | `./scripts/fix-terminal-issues.sh` |
| Validate the whole setup | `./validate-setup.sh` |
| Version-manager health check | `./version-manager.sh health-check` |
| Recover a broken setup | `./scripts/emergency-recovery.sh` |
| Inspect backups | `ls ~/.config-backups` |

Prerequisites: bash >= 4.0 (the test suite enforces this; macOS `/bin/bash`
3.2 is not sufficient), `make` for gate targets, `shellcheck` and
`pre-commit` for lint gates.

## Golden rule: dry-run first

Every mutating script honors planning. Prefer a plan over a direct apply:

```bash
./scripts/fix-terminal-issues.sh --dry-run fix-p10k     # zero writes
./setup-fonts-enhanced.sh --dry-run                     # zero writes
./tools/update-global-node-symlinks.sh                  # plan-by-default; --confirm applies
```

Dry-run is implemented by `TRANSACTION_DRY_RUN=1`: the transaction
primitive reports the plan and performs **zero filesystem writes**
(`lib/backup.sh`).

## Setup

1. `./setup.sh` — interactive menu (theme, version managers, validation,
   fonts, icon management, rollback).
2. Theme: `./setup-theme.sh professional` installs PowerLevel10k and
   applies `config/professional-dev-p10k.zsh`.
3. Version managers: `./version-manager.sh install-all`, or individually
   (`install-node`, `install-python`, `install-ruby`, `install-php`, …).
   `./setup-versions.sh` configures the managed set.
4. Fonts: place the four `MesloLGS NF *.ttf` files at the repository root
   (see `FONT_MANIFEST.md`), then `./setup-fonts-enhanced.sh`.
5. Terminal fixes: `./scripts/fix-terminal-issues.sh fix-all`
   (diagnose | fix-shell | fix-p10k | fix-fonts | fix-all | test).
   The `/etc/shells` append requires `--confirm` or an interactive yes.

## Verify

- `./validate-setup.sh` — read-only end-to-end validation (PowerLevel10k,
  Nerd Fonts, zsh config, nvm, pyenv, theme display).
- `./version-manager.sh health-check` — version-manager runtime health.
- `./tools/health-check.sh` and `./tools/system-diagnostics.sh` —
  additional diagnostics (read-only).
- Icon rendering: `./tools/preview-nerd-fonts.sh`.

## Recover

`./scripts/emergency-recovery.sh` offers a menu:

- Restore `~/.zshrc`, `~/.p10k.zsh`, or VS Code settings from the newest
  matching backup (each restore runs under a transaction; the pre-restore
  state is itself backed up as `.emergency-<timestamp>`).
- Reset to defaults (requires typing `RESET`).
- List and restore from named restore points.

Manual recovery paths:

- Timestamped file backups live in `~/.config-backups/`
  (`<file>.backup.<timestamp>`). Restore with `cp` after confirming the
  file is the one you want, or use `list_backups` / `restore_backup` from
  `lib/backup.sh` in a shell.
- Privileged symlink backups made by `tools/update-global-node-symlinks.sh`
  are printed by that tool at apply time and can be restored with
  `tools/update-global-node-symlinks.sh --confirm restore <backup-dir>`.

## Backups, transactions, and the audit journal

| Location | Contents |
|----------|----------|
| `~/.config-backups/<file>.backup.<timestamp>` | Per-file backups; retention defaults to 10 per file / 30 days (`BACKUP_MAX_FILES`, `BACKUP_MAX_AGE`) |
| `~/.config-backups/transactions/<name>.XXXXXX/` | One directory per transaction (exclusive `mktemp -d`); see below |
| `~/.config-backups/restore_points/<name>/` | Named restore points (`create_restore_point`, `restore_from_point`) |
| `~/.config/version-manager/audit.log` | Audit journal (override `TXN_AUDIT_LOG`) |
| `~/.local/share/version-manager/logs/` | Runtime logs, `version-manager-<date>.log` |
| `~/.config/version-manager/trusted-projects` | Auto-activation trust registry (M3) |

### How to inspect a transaction

A transaction directory contains:

```text
~/.config-backups/transactions/fix_terminal_fonts.a1B2c3/
├── metadata.json      # name, started_at, status, layout, files count
├── files.tsv          # tab-delimited registry: kind, index, sha256, path
├── new_files.txt      # files created by the operation (removed on rollback)
└── files/<NNNN>/data  # hash-recorded pre-state payload per entry
```

- `metadata.json` `status` is one of `active`, `committed`, `rolled_back`,
  or `rolled_back_with_errors` (the last one means the restore did NOT
  fully succeed — treat the machine as dirty and reconcile manually).
- `files.tsv` maps each entry index to the original path and its SHA-256;
  `files/<index>/data` holds the pre-transaction bytes (for `symlink`
  kind, the link target).
- The audit journal records the same lifecycle
  (`start` / `commit` / `rollback` with mode, files, and error counts):

```bash
tail -n 20 ~/.config/version-manager/audit.log
grep -c "rollback" ~/.config/version-manager/audit.log
```

## CI

- **Buildkite is the sole automatic CI engine**
  (`.buildkite/pipeline.yml`, hosted queues `linux-small` /
  `macos-medium`). Gate set: ShellCheck lint, fail-closed syntax check
  (`bash -n` + `zsh -n`), pre-commit, gitleaks secret scan, and the Linux +
  macOS test matrix. Every test step emits the canonical test manifest via
  `tests/emit-manifest.sh` and uploads it as a per-OS artifact; the
  artifact paths are fail-closed (an empty artifact fails the step).
- **GitHub Actions `test.yml` is a manual-only fallback**
  (`workflow_dispatch`) so the two engines never double-fire. Third-party
  actions are SHA-pinned with version comments.
- Local equivalents: `make lint`, `make syntax-check`, `make test-unit`,
  `make test-integration`, `make test` (all routed through
  `tests/test_runner.sh`, which emits the canonical manifest), and
  `pre-commit run --all-files`.
- Platform note for tests: bash >= 4.0 required (ENGINEERING_RULES §3.1).

## Release path

1. Release gates run first: lint is **gating** (no `|| true`), and the
   release job fails on a `package.json` ↔ git-tag version mismatch.
2. Trigger: push a tag `v*.*.*` (`.github/workflows/release.yml`), or run
   the workflow manually with an explicit version input.
3. Artifacts ship with SHA-256 checksums. Signing, SBOM, and attribution
   packaging are ROADMAP Phase 5 items (5.1, 5.2) — not yet present.
4. A release freeze is in effect whenever a remediation milestone gate is
   open (remediation directive rule 1); check
   [governance/ROADMAP.md](governance/ROADMAP.md) before tagging.

## Troubleshooting pointers

- Icons render as boxes: check the installed font and terminal font family
  (`MesloLGS Nerd Font`), restart the terminal; see `FONT_MANIFEST.md`
  troubleshooting.
- A mutation half-applied: check `metadata.json` status of the newest
  transaction directory and the audit journal; re-run the script
  (mutations are idempotent) or use the emergency-recovery menu.
- Lock contention: `lib/lock.sh` uses atomic `mkdir` acquisition with
  stale-reclaim; a crashed run leaves no permanent lock.
