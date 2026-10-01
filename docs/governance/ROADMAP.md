# ROADMAP — Prioritized Remediation & Evolution Plan

**Derives from:** [MASTER_AUDIT.md](MASTER_AUDIT.md) (single source of truth for findings)
**Baseline:** `ffda468` (2026-07-04)
**Rule:** Work proceeds top-to-bottom. Do not start a lower phase while a higher phase has open items, unless an item is explicitly marked deferrable. Update item status here when merged; update finding status in MASTER_AUDIT.md.

Status legend: `[ ]` open · `[~]` in progress · `[x]` done (commit ref required)

---

## Phase 1 — Immediate Safety & Release Integrity (P0)

*Nothing here changes features. Everything here closes a hole that can damage a user's machine or ship broken code.*

- [x] **1.1** Sandbox the integration test harness: export `HOME=$(mktemp -d)` + `XDG_CONFIG_HOME` in `tests/helpers.sh` `setup_test` (currently empty, `tests/helpers.sh:147-150`) and enforce in `tests/test_runner.sh` before any test sources a mutating script. Acceptance: `make test-integration` never touches the real `$HOME`. *(P0-3 — done in `d4e752d`: runner-level per-test sandbox + helpers-level sandbox for direct execution; verified via identical ~/.zshrc checksums)*
- [x] **1.2** Remove `|| true` from release lint (`release.yml:96`); encode tolerated findings in `.shellcheckrc`/inline suppressions. Acceptance: seeded lint error blocks release. *(P0-1 — done in `8f6d269`)*
- [x] **1.3** Fail release on package.json ↔ tag mismatch (`release.yml:69-72`): replace warning with `exit 1`. *(P0-2 — done in `8f6d269`)*
- [x] **1.4** Add `--dry-run` (default) + `--confirm` to `tools/update-global-node-symlinks.sh`; fix the passwordless-sudo confirmation bypass (`:37`). Add confirm + backup to the `/etc/shells` append in `scripts/fix-terminal-issues.sh:96`. *(P0-6 — done in `0c6b674`: plan-by-default on update AND restore paths; /etc/shells gets diff preview + backup + interactive/--confirm/VMS_CONFIRM consent)*
- [x] **1.5** Add pre-commit job and gitleaks secret-scan job to `test.yml`. *(P1-5, P2-10 fast wins — done in `8f6d269`; both actions SHA-pinned and verified against GitHub API)*
- [x] **1.6** Make `tools/validate-quality.sh` exit non-zero on mandatory failures; add `--advisory`. *(P1-7 — done in `78369bf`)*

**Phase gate:** CI red on any of: lint failure in release, version mismatch, secret detected, test writing outside sandbox HOME.

## Phase 2 — Execution & Injection Surface (P0-4, P0-5, P1-1, P1-2)

- [x] **2.1** Add `safe_exec_argv cmd arg...` and `safe_exec_shell_trusted "literal"` to `lib/error-handling.sh`; migrate callers of `safe_exec`/`safe_exec_backoff`; deprecate string forms (warn on use). *(Per MASTER_AUDIT §5.2 — argv arrays, NOT `bash -c`) — done in `321ae5e`; caller inventory verified empty (tests/docs only); 19 injection-regression assertions*
- [x] **2.2** Same treatment for `cache_safe_execute` (`lib/cache.sh:816,825`) and `cache_version` (`lib/performance.sh:66`). *(done in `50216cf`)*
- [x] **2.3** Atomic locking: replace check-then-write (`version-manager.sh:203-213`) with `mkdir`-based acquisition; extract to `lib/` and adopt in every mutating entry point. *(done in `026cdd3`: new `lib/lock.sh` with stale-reclaim + ownership-checked release; adopted by version-manager.sh, setup-theme.sh, setup-versions.sh)*
- [x] **2.4** Validate cache namespace `^[A-Za-z0-9_-]+$` before `rm -rf` (`lib/cache.sh:452,465`). *(done in `50216cf`; canary-tested)*
- [x] **2.5** Regenerate CI templates in `version-advanced.sh`: `actions/setup-node`/`setup-python` etc. where available; download→checksum-verify→execute otherwise. Kill all 9 pipe-to-shell lines. *(P0-5 — done in `68eb4a0`; grep-proven zero pipe-to-shell, PyYAML-validated output)*
- [x] **2.6** Deduplicate `cache_stats` (`lib/cache.sh:279` vs `:748`) and rationalize the flat-vs-namespaced cache API. *(P1-8 — done in `50216cf`)*

## Milestone Program M0–M3 (inserted 2026-10-01, per merged-audit-directive.md v3)

*Binding spec: [merged-audit-directive.md](../../merged-audit-directive.md) (frozen v3, 2026-08-12). These milestones sit ahead of Phase 3; the transactional mutation rollout is BLOCKED-ON-M2 (directive Rule 4). A/B finding IDs refer to the directive's sections.*

- [~] **M0 — Test truth.** Canonical test manifest from every runner entry point (Make/CI/direct); route all test targets through `tests/test_runner.sh`; fail-closed syntax gate incl. `zsh -n`; zero-tolerance ShellCheck in `validate-quality.sh`; remove unconditional `exit 0`s; self-contained failing tests; seeded-failure meta-tests for every gate; Linux+macOS manifest parity. *(A1, B1.4, B1.7; C-1 resolution mechanism)* — *Status 2026-10-01: steps 1–4 and Linux+macOS manifest parity DONE (Linux container + macOS, 25/25 both, `PARITY OK across 2 manifests`; commits `104e65e`→`149c464`). Remaining for GO: (1) CI-engine evidence — blocked by GitHub account billing lock (owner action); (2) `lib/auto-activate.sh` 8 SC2002 lint fixes — blocked by protected staged file (owner authorization); fix ready on branch `m0/linux-lint-parity`.*
- [ ] **M1 — Library and runtime contracts.** Strip strict mode from `lib/logger.sh`/`lib/env.sh`/`lib/backup.sh`/`lib/plugins.sh` (inverts P2-1's framing — the register records the *absence* of strict mode; the live defect is its presence); `$-`-preservation contract test per module; repo-wide `((x++))` sweep; logs→stderr for value-returning functions; `fonts.sh` `0\n0` fix; Bash version contract. *(A2, B1.5, B1.9, B2.4)*
- [ ] **M2 — Transaction primitive hardening + mutation registry.** Basename-collision rollback fix, transaction-name validation, collision-resistant dirs, hash-verified rollback (A3); publish the complete mutation-target registry (Phase 3.3's five + B1.6's nine + any further sinks). Phase 3 unblocks here.
- [ ] **M3 — Trust-boundary repair.** Plugin identifier grammar + containment + symlink rejection (B1.1); auto-activation split behind a persistent trust registry (B1.2); fail-closed validator redesign wired into destructive entry points (B1.3, A4); privileged-path tests via a recording sudo shim only.

## Phase 3 — Transactional Mutation Framework (P3-1, P1-3) — **BLOCKED-ON-M2**

*The strategic centerpiece. `setup-theme.sh:182-191` is the reference implementation pattern. Blocked by the M0–M3 milestone program above (directive Rule 4); adoption expands only after M2 exits GO.*

- [ ] **3.1** Formalize the mutation lifecycle in `lib/backup.sh` (or new `lib/mutation.sh`): plan → show → backup transaction → apply → verify → commit/rollback, plus audit-journal entry (`~/.config/version-manager/audit.log`). *(P3-2)*
- [ ] **3.2** Managed-block editing for shell rc files: `# BEGIN version-management-setup:<name>` … `# END`, replaced atomically. Fix the `NVM_SILENT=1` vs `=true` idempotency drift in `scripts/fix-nvm-issues.sh`. *(P1-3)*
- [ ] **3.3** Migrate remaining mutating scripts onto the framework: `scripts/fix-nvm-issues.sh`, `setup-versions.sh`, `scripts/emergency-recovery.sh`, `setup-fonts-enhanced.sh`, `tools/update-global-node-symlinks.sh`.
- [ ] **3.4** Every mutating script supports `--dry-run` and records a backup ID. Acceptance: failed verify triggers rollback in a sandboxed test.

## Phase 4 — Consolidation & Test Maturity (P1-9, P1-11, P2-*)

- [ ] **4.1** Canonical platform detection in `lib/env.sh`; `get_os`/`get_shell` elsewhere become wrappers; contract test pins WSL semantics (decide: `wsl` vs `linux` — currently drifted). *(P1-9)*
- [ ] **4.2** Deduplicate `command_exists`/colors/`log` shims between `version-manager.sh` and `version-advanced.sh`. *(P2 tier)*
- [ ] **4.3** Validation sweep: user-supplied params validated at all public entry points (start: `install_node_version`). *(P2-4)*
- [ ] **4.4** `setup.sh`: source `lib/error-handling.sh`, register ERR trap. Remove `sync` stub. Delete `tests/unit/test_restore.txt` + gitignore scratch. Log rotation in `lib/logger.sh`. Configurable `NVM_VERSION` single pin. *(P2-2/3/5/6/12)*
- [ ] **4.5** Real coverage (kcov or bats+kcov) replacing pseudo-coverage; scenario-based integration tests: clean-HOME bootstrap, managed-block re-run idempotency, failed-installer rollback, no-network, permission-denied. *(P1-11, P2-13, P3-3)*
- [ ] **4.6** Re-justify `.shellcheckrc` global disables; move SC2015/SC2181 to inline. *(P2-9)*
- [ ] **4.7** Dockerfile templates: multi-stage, non-root, HEALTHCHECK. *(P2-7)*

## Phase 5 — Supply Chain, Compliance & Docs (P1-6, P1-10, P2-8)

- [ ] **5.1** Artifact signing + SBOM + (optionally) GitHub artifact attestation in `release.yml`.
- [ ] **5.2** `FontPatcher/ATTRIBUTION.md` consolidating mixed glyph licenses; correct `FONT_MANIFEST.md`; include attribution in release archives.
- [ ] **5.3** `docs/SECURITY.md` (trust boundaries, installer policy, mutation policy), `docs/OPERATIONS.md` (runbooks), `config/README.md`.
- [ ] **5.4** ADR directory (`docs/governance/adr/`) seeded from MASTER_AUDIT §5 decisions.
- [ ] **5.5** Commit `package-lock.json` or drop the npm shellcheck devDependency. *(P2-11)*

## Deferred / Watch List

- **Option C hybrid** (compiled helper for planning/locking/downloads) — revisit after Phase 3 ships. *(P3-5)*
- **Windows/Git-Bash CI runner** — add when Windows support claims become load-bearing. *(P2-10 partial)*
- **Module decomposition of `lib/cache.sh` / `version-manager.sh`** — refactor around stable interfaces only after Phase 4 contracts exist; file size alone is not a trigger.
