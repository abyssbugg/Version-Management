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

## Terminal adoption update (2026-10-06, integration branch)

`scripts/generate-vscode-settings.sh` now renders JSON before publication,
previews without writes, preserves existing symlinks/modes, and uses the
existing lock and backup transaction for atomic publication and verified
rollback. `tests/integration/test_vscode_settings_managed.sh` covers parser
fallback, hostile string values, idempotency, failed publication/verification,
new-file rollback and link preservation. Its default remains the repo-local
`vscode-settings.json`; it does not install settings into a live VS Code profile.

Three terminal adopters are now integrated: the generator (`96da206`),
`theme-icon-manager.sh` (`a94b72d`) and `setup-slick-terminal.sh` (`4eb2c20`).
The icon editor handles literal input without evaluating configuration, retains
prompt mode names, and preserves theme identity on repeated resets. Slick
terminal publishes its fonts, JSON and executable glyph demo as one rollback
unit, preserving the original locations and settings values. Their regression
matrices cover zero-write previews, idempotency, symlinks/modes and injected
post-publication failure, including new-file removal.

Shared follow-up `a03f8e7` preserves first-registration state, dangling symlinks
and original modes during transaction rollback, and coordinates local font
installation using the existing `workstation-mutation` lock. Transaction
preview auditing is console-only; apply events retain backup IDs. Fontconfig
cache is derived state: refresh is scoped to the destination and retried after
file rollback; refresh failure remains a nonzero result, not a success claim.

This closes the terminal-output fix, not every mutator in the broader registry.

## Manager rc adoption (2026-10-06, `fix/managed-manager-config`)

The six `version-manager.sh` configuration writers for NVM, FNM, pyenv,
rbenv, phpenv and lazy loading now use managed blocks with transaction
registration, syntax verification, rollback and a shared configuration lock.
Existing unmanaged configuration is refused unchanged for explicit migration.
`configure <manager> --dry-run` bypasses installer and cache initialization.
The NVM directory hook no longer installs a missing version implicitly.
`tests/integration/test_manager_config_managed.sh` exercises reruns, symlinks,
modes, failed edits, malformed markers, new rc files and zero-write previews.
Installer directories, project version files and auto-switch adoption remain
outside this slice; this is not closure of every `version-manager.sh` sink.

## Auto-activation rc follow-up (2026-10-06)

`auto_activate_setup` and `auto_activate_remove` now share locked,
transactional managed-block publication with syntax verification and rollback.
Preview returns a console-only plan before locks, temporary files or journals.
Legacy `# >>> dev auto-activate hook <<<` blocks and malformed managed markers
are refused unchanged rather than silently migrated. The existing trust
registry and runtime capability gates are unchanged. The 44-assertion regression
covers partial-write and failed-verification rollback, links/modes, reruns,
marker refusal, lock denial, caller traps and zero-write previews.

## Per-operation metadata contract (M2 exit criterion)

Every adoption must record: target, mode (dry-run/apply), backup ID, result,
exit code — into the audit journal (`~/.config/version-manager/audit.log`,
finding P3-2) via the hardened transaction primitive (A3).
