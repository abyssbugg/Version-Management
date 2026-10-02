# Mutation-Target Registry (directive M2, finding B1.6)

**Provenance:** full static census at 2026-10-02 (`census of all 50 in-scope
.sh` files read end-to-end + cross-verification greps; raw census preserved in
the remediation evidence store, artifact `b1.6-mutation-census.md`).
**Status key:** `legacy` = not yet adopted by the transaction framework;
`adopted` = flows through plan/dry-run/backup/verify/rollback (M4); `n/a` =
writes confined to its own cache/state directory (tracked, not adoption
targets).

**Totals:** 237 mutation sinks across 41 mutating scripts of 50 in-scope
files. Read-only scripts: `validate-setup.sh`, `lib/env.sh`, `lib/utils.sh`,
`lib/validation.sh`, `scripts/lint-shell.sh`, `scripts/check-no-secrets.sh`,
`tools/check-dependencies.sh`, `tools/health-check.sh`,
`tools/validate-quality.sh`.

## Critical adoption queue (mutates state with NO backup AND NO dry-run)

(see census artifact)

## Registry — mutating scripts (adoption risk order per directive M4)

The M4 migration order (risk order): `scripts/fix-nvm-issues.sh` →
`setup-versions.sh` → `scripts/fix-terminal-issues.sh` →
`tools/update-global-node-symlinks.sh` → `setup-fonts-enhanced.sh` →
`scripts/emergency-recovery.sh` → remaining registry entries.

Root (7): `setup.sh`, `setup-theme.sh`, `setup-versions.sh`, `setup-fonts-enhanced.sh`, `setup-slick-terminal.sh`, `version-manager.sh`, `version-advanced.sh`
lib (17): `backup.sh`, `theme-ops.sh`, `lock.sh`, `cache.sh`, `logger.sh`, `metrics.sh`, `plugins.sh`, `error-handling.sh`, `performance.sh`, `auto-activate.sh`, `fonts.sh`, `nvm.sh`, `gvm.sh`, `jenv.sh`, `rustup.sh`, `pyvm.sh`, `phpenv.sh` (also `fnm.sh` — 18 with fnm)
plugins (2): `asdf.sh`, `rbenv.sh`
scripts (9): `emergency-recovery.sh`, `fix-nvm-issues.sh`, `fix-terminal-issues.sh`, `generate-vscode-settings.sh` (in-repo only), `patch-font.sh`, `release.sh`, `setup-wizard.sh`, `theme-icon-manager.sh`, `lint-shell.sh` excluded — so (8): `emergency-recovery.sh`, `fix-nvm-issues.sh`, `fix-terminal-issues.sh`, `generate-vscode-settings.sh`, `patch-font.sh`, `release.sh`, `setup-wizard.sh`, `theme-icon-manager.sh`
tools (7): `analytics-report.sh`, `preview-nerd-fonts.sh`, `system-diagnostics.sh`, `update-dependencies.sh`, `update-global-node-symlinks.sh`, `version-diagnostic-enhanced.sh` — that is 6; plus none.

Read-only (no sinks): `validate-setup.sh`, `lib/env.sh`, `lib/utils.sh`, `lib/validation.sh`, `scripts/lint-shell.sh`, `scripts/check-no-secrets.sh`, `tools/check-dependencies.sh`, `tools/health-check.sh`, `tools/validate-quality.sh`.

## Per-operation metadata contract (M2 exit criterion)

Every adoption must record: target, mode (dry-run/apply), backup ID, result,
exit code — into the audit journal (`~/.config/version-manager/audit.log`,
finding P3-2) via the hardened transaction primitive (A3).
