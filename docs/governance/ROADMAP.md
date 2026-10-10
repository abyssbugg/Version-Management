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

- [x] **1.1 follow-up — P0-3-runtime-home:** runtime backup roots (`a16e8a0`) and direct editor-test isolation (`e8a16b7`, integrated via `fix/terminal-mutation-safety`). The runner already sets HOME before launching tests, but direct/source-before-sandbox use could retain an old HOME. Two-HOME regressions reproduced 13 library failures and 9 editor-isolation failures; repaired suites pass. Local full gate: 50/50 files, lint/syntax and all pre-commit hooks pass. No real HOME was inspected or changed, and attribution for the reported real `.zshrc` loss is not established.
- [x] **1.1 follow-up — P0-3-direct-run (2026-10-08):** 16 tests sourced the harness via cwd-relative `source ../helpers.sh`; run directly from the repo root the source failed, `setup_test` never ran, HOME was never sandboxed, and `test_auto_activate_trust.sh` overwrote the **real** `$HOME/.zshrc` (sentinel `export EDITOR=vi`) — the actual mechanism behind both 2026-10-04/10-06 workstation `.zshrc` losses (the ASCII BOAT attribution was mistaken). Replaced every occurrence with the self-locating fail-closed form `source "${BASH_SOURCE[0]%/*}/../helpers.sh" || exit 1`. Re-reproduction from repo root: sentinel rc byte-identical, test rc=0. See MASTER_AUDIT P0-3-direct-run. Also fixed `test_rustup` network auto-install hang (`RUSTUP_AUTO_INSTALL=0`). Full gate green: lint 0 · syntax 124/124 · unit 37/37 · integration 20/20.

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

- [x] **M0 — Test truth.** Canonical test manifest from every runner entry point (Make/CI/direct); route all test targets through `tests/test_runner.sh`; fail-closed syntax gate incl. `zsh -n`; zero-tolerance ShellCheck in `validate-quality.sh`; remove unconditional `exit 0`s; self-contained failing tests; seeded-failure meta-tests for every gate; Linux+macOS manifest parity. *(A1, B1.4, B1.7; C-1 resolution mechanism)* — *Status 2026-10-02: **GO — all conditions met.** Build #16: 7/7 jobs green (first fully green CI build); steps 1–4 DONE; **CI engine migrated to Buildkite** (`abyssbugg/version-management`, hosted queues linux-small/macos-medium; GitHub Test workflow demoted to manual-only fallback, `dd92d5f`). Evidence: build #10 green matrix (lint/syntax/gitleaks/tests on both OSes); seeded-failure red OBSERVED (build #12: seeded exit 7 propagated verbatim into the manifest) and seed-specific green (build #13); **4-way manifest parity `PARITY OK across 4 manifests`** (Buildkite-Linux, Buildkite-macOS, container-Linux, direct-macOS). Meta-tests also caught and closed a real fail-open defect en route: `make validate` passed vacuously without shellcheck (builds #4–#8) — now fails closed, and the B1.7 meta-case rejects vacuous reds. Staged set landed (`a38f282`), auto-activate lint hunk applied (`4f20739`), pre-commit conformance complete (`9957d20`) — pre-commit and ShellCheck lint now green on both hosted OSes.*
- [x] **M1 — Library and runtime contracts.** Strip strict mode from `lib/logger.sh`/`lib/env.sh`/`lib/backup.sh`/`lib/plugins.sh` (inverts P2-1's framing — the register records the *absence* of strict mode; the live defect is its presence); `$-`-preservation contract test per module; repo-wide `((x++))` sweep; logs→stderr for value-returning functions; `fonts.sh` `0\n0` fix; Bash version contract. *(A2, B1.5, B1.9, B2.4)* — *Status 2026-10-02: DONE in `cdcba9e`. Contract test found the leak's blast radius broader than the four named libraries (every module sourcing them); 0 violations under both postures after stripping the four direct setters. 57-site `((x++))` sweep, 0 residual. `fonts.sh` double-zero fixed. Bash >= 4.0 contract documented (ENGINEERING_RULES §3.1) and enforced in test_runner. B2.4 logger-stdout contract: deferred to M4's managed-block work (its mutation-surface rework touches the same call sites); the theme_detect_current symptom is already tolerated in tests.*
- [x] **M2 — Transaction primitive hardening + mutation registry.** Basename-collision rollback fix, transaction-name validation, collision-resistant dirs, hash-verified rollback (A3); publish the complete mutation-target registry (Phase 3.3's five + B1.6's nine + any further sinks). Phase 3 unblocks here. — *Status 2026-10-02: **GO.** Registry published (`docs/governance/MUTATION_REGISTRY.md`, `ff7ce62`). Primitive hardened in `fcbc584`: path-preserving index layout + hash-verified rollback (tamper-refusing), exclusive `mktemp -d` dirs (concurrent same-named transactions asserted filesystem-distinct and byte-isolated), restrictive name grammar, tab-delimited registry with newline/tab rejection, symlink semantics defined (link preserved), partial-restore failure loud (`rolled_back_with_errors`, nonzero), `TRANSACTION_DRY_RUN` zero-writes, per-operation audit journal (P3-2 seed). Test matrix written FIRST — 13 failures reproduced against the old primitive, 0 after; root-proof failure injection. CI: build #19 7/7.*
- [x] **M3 — Trust-boundary repair.** Plugin identifier grammar + containment + symlink rejection (B1.1); auto-activation split behind a persistent trust registry (B1.2); fail-closed validator redesign wired into destructive entry points (B1.3, A4); privileged-path tests via a recording sudo shim only. — *Status 2026-10-02: **GO.** Three lanes: foundation validators (`c158de3`, 11 reds → 0), plugin trust (`5c92004`, 30/47 red → 47/47; traversal + symlink-escape + canary deletion all reproduced then closed; installs transaction-routed), auto-activation split (`76dc3b9`, 12/12 red with three live-vuln demonstrations → 51/51; venv/node/sudo capabilities behind persistent per-project registry; sudo recording shim; rc rewrites transaction-backed). Integration verified: build #21 7/7, 30-record manifest. Lock-concurrency CI flake hardened (timeouts separated from violations).*

- [x] **M4 — Managed mutation adoption.** Managed-block editor + canonical NVM block first (B2.1/P1-3), then the directive's six named adopters in risk order, each with red→green per-adopter matrices (byte-identical reruns, root-proof injected-failure rollback, dry-run, audit journal). — *Status 2026-10-04: **GO for the named set.** Editor `58b967d`; adopters `3af0549` (fix-nvm-issues), `a3b9038` (setup-versions), `7def705` (fix-terminal-issues), `50163f2` (update-global-node-symlinks), `96c482b` (setup-fonts-enhanced), `08c3446` (emergency-recovery); build #30 7/7. Registry's broader cache/state-writer class remains lower-risk ongoing adoption.*
- [x] **M5 — Validation, portability, delivery.** Scoped `make clean` (B2.2); clean-HOME/no-network/permission/symlink scenarios; consolidated platform API + WSL contract; gitleaks+pre-commit in release path; SHA-pin generated workflows; checksum-verified installers; SCRIPT_DIR-hygiene pass (A5-new); SBOM/signing/attribution/ADR/security docs.*
  — *Status 2026-10-04: **GO.** Platform consolidation `668f7a1` (canonical `get_os`/`get_shell`, WSL reports `wsl` from both, pinned by `tests/unit/test_platform_contract.sh`; SCRIPT_DIR hygiene across 13 libs = A5-new FIXED) + root-script wrappers `b7d1007` (P1-9 CLOSED; wrapper-parity RED 4 → GREEN 47/47). Hygiene smalls `7df7744` (B2.2 scoped clean; ERR trap; log rotation; single NVM pin; SHA-pinned generated workflows; pipe-to-shell removal). Docs compliance `ccc9147` (ATTRIBUTION/SECURITY/OPERATIONS/config README, ADRs 001–005). Release integrity `31a23aa` (gitleaks+pre-commit as pre-build gates; attribution + deterministic SPDX-lite SBOM + full-coverage checksums in release artifacts; two phantom action SHAs fixed, 11/11 SHA-pinned upstream-verified; signing decision recorded: SHA256SUMS now, keyless cosign documented follow-up). Transaction-primitive robustness `05ff686` + `dd312b6` (B1.10/11/12/13-new FIXED — symlink-preserving block writes, guarded rollback recording, degraded source-time cache init, exported-transaction-function slate). Adverse-condition suite `4d3053d` (clean-HOME/no-network/permission/symlink, 19 cases + 4 negative controls; RED→GREEN each class). Lane H verified post-hoc (agent died on quota before reporting); all manifests 41/41 twice locally; CI 7/7 builds #31–#33. Known residual gaps live in SECURITY/MAINTENANCE (vendored font-patcher gitleaks finding, upload-artifact version drift, live-WSL verification, root/Linux adverse paths unverified on those platforms).*

## Phase 3 — Transactional Mutation Framework (P3-1, P1-3) — **UNBLOCKED (M2 GO)**

*The strategic centerpiece. `setup-theme.sh:182-191` is the reference implementation pattern. M0–M3 milestones completed; M4 completed directive-named adopter set.*

- [x] **3.1** Formalize the mutation lifecycle in `lib/backup.sh` (or new `lib/mutation.sh`): plan → show → backup transaction → apply → verify → commit/rollback, plus audit-journal entry (`~/.config/version-manager/audit.log`). *(P3-2)* — **DONE for the primitives (2026-10-09):** transactions + `_txn_journal` (`fcbc584`, `05ff686`, `dd312b6`); managed blocks (`58b967d`, in-place replace + malformed-marker refusal `11b8d01`); whole-file publication `mutation_file_publish` (`286f7f9`: pre-state registered, atomic, symlink/mode kept, verified, dry-run plans only); reversible installer trees `install_dir_stage`/`install_dir_restore` (`ae8aa48`, `a87b156`). Every adopter below uses them. Per-operation metadata (P3-2) completed in `e9c9730`: every journal record carries script/pid/mode, result, exit code and target or file count (`test_audit_journal_schema.sh`).
- [x] **3.2** Managed-block editing for shell rc files: `# BEGIN version-management-setup:<name>` … `# END`, replaced atomically. Fix the `NVM_SILENT=1` vs `=true` idempotency drift in `scripts/fix-nvm-issues.sh`. *(P1-3)* — `58b967d` editor, `3af0549` fix-nvm-issues, `a3b9038` setup-versions; per-adopter tests pin the canonical block and rerun behavior.
- [x] **3.3** Migrate the five named scripts onto the framework: `scripts/fix-nvm-issues.sh` (`3af0549`), `setup-versions.sh` (`a3b9038`), `scripts/emergency-recovery.sh` (`08c3446`), `setup-fonts-enhanced.sh` (`96c482b`), `tools/update-global-node-symlinks.sh` (`50163f2`). The directive also added `scripts/fix-terminal-issues.sh` (`7def705`). This closes the named list, not the broader registry.
- [x] **3.4** Every mutating script supports `--dry-run` and records a backup ID. Acceptance: failed verify triggers rollback in a sandboxed test. — **DONE for every user-file writer found (2026-10-09, `fix/managed-manager-config`):** terminal adopters (`96da206`, `a94b72d`, `4eb2c20`), manager rc writers, auto-activation (`ae1fd83`), then the 2026-10-09 sweep — diagnostic `--fix` (`4cdd637`), `create-versions` (`6a24164`), patch-font (`5676b6f`), installers (`ae8aa48`, `a87b156`, `b914e0a`, `7507014`), update-dependencies (`1544ff6`), rustup (`f23f217`), version-advanced generators (`286f7f9`), font writers (`62ad115`), pyvm hook removal (`4f80105`), plugins (`6c5bb21`). Each has a sandboxed RED→GREEN regression; the transactional ones (diagnostic `--fix`, `create-versions`, patch-font, version-advanced, font writers) also exercise rollback on an injected failure, and update-dependencies/runtime installers/plugins are dry-run-only. Boundaries: runtime installs (`nvm install`, `pyenv install`, …) are previewed, not rolled back (installing software is not a file transaction); the evidence is a static writer survey, not a proof against future bypasses. (The former `install-* --dry-run` cache/XDG/lock boundary is removed in `8b57f56`: the preview is zero-write for the whole HOME tree.)

## Phase 4 — Consolidation & Test Maturity (P1-9, P1-11, P2-*)

- [x] **4.1** Canonical platform detection in `lib/env.sh`; `get_os`/`get_shell` elsewhere become wrappers; contract test pins WSL semantics (decide: `wsl` vs `linux` — currently drifted). *(P1-9)* — **DONE (M5)**: `668f7a1` canonical API + WSL contract test; `b7d1007` root-script wrappers; SCRIPT_DIR hygiene (`668f7a1` A5-new); wrapper-parity RED 4 → GREEN 47/47.
- [x] **4.2** Deduplicate `command_exists`/colors/`log` shims between `version-manager.sh` and `version-advanced.sh`. *(P2 tier)* — **DONE (2026-10-08)**: `command_exists` and the `log()` level wrapper were byte-identical in both entry scripts; consolidated into `lib/env.sh` (both already source it after `lib/logger.sh`), guarded with `declare -f … ||` so a caller override still wins, and exported. Local copies removed from both scripts; neither uses them before the `lib/env.sh` source. Colors already came from `lib/logger.sh` (no local color blocks). Verified: single canonical definition, both scripts resolve and exercise both functions correctly, full gate green.
- [x] **4.3** Validation sweep: user-supplied params validated at all public entry points (start: `install_node_version`). *(P2-4)* — **DONE (2026-10-08)**: Node guard landed in `0648f2d`; Python/Ruby/PHP public installer guards added (`validate_python_version`/`validate_ruby_version`/`validate_php_version`, each applied in `version-manager.sh` before any side effect). `tests/unit/test_validation.sh` pins accept-legit + reject-injection for the new validators; `tests/integration/test_version_manager.sh` pins the rejection path. The four public language installers are now guarded.
- [x] **4.4** `setup.sh`: source `lib/error-handling.sh`, register ERR trap. Remove `sync` stub. Delete `tests/unit/test_restore.txt` + gitignore scratch. Log rotation in `lib/logger.sh`. Configurable `NVM_VERSION` single pin. *(P2-2/3/5/6/12)* — **DONE (M5)**: `7df7744` (ERR trap, sync removed, test_restore.txt deleted, rotation, single pin, package-lock decision).
- [x] **4.5** Real coverage (kcov or bats+kcov) replacing pseudo-coverage; scenario-based integration tests: clean-HOME bootstrap, managed-block re-run idempotency, failed-installer rollback, no-network, permission-denied. *(P1-11, P2-13, P3-3)* — **DONE (M5 lane C1)**: scenarios landed (`4d3053d`, `0648f2d`); real kcov coverage landed — `546f063` merged via `06f0a62` (ancestor of PR head `86ddde9`); `Makefile:coverage-kcov` is real line coverage (`kcov --include-path=lib`, cobertura.xml) and fails closed without kcov installed; CI coverage lane on linux-small. Manual `.coverage` markers remain only as test-intent tracking. Bats deliberately not adopted — the native `test_runner` + `emit-manifest` harness with per-file sandboxed HOME is the retained equivalent.
- [x] **4.6** Re-justify `.shellcheckrc` global disables; move SC2015/SC2181 to inline. *(P2-9)* — **DONE (2026-10-08)**: duplicate SC2034 removed; SC2181 moved from global to 7 inline suppressions (reasoned) in `lib/backup.sh`, `lib/cache.sh`, `version-manager.sh`; SC2015 re-justified in place (120 guard-with-fallback sites — kept global by deliberate decision, documented, rather than 120 inline suppressions on mutation-critical code); every remaining global disable carries a justification. Lint stays 0 across 115 scripts.
- [x] **4.7** Dockerfile templates: multi-stage, non-root, HEALTHCHECK. *(P2-7)* — **DONE (M5 lane C2)**: `343afa7`/`0648f2d` hardened Docker templates (multi-stage, non-root USER, HEALTHCHECK).

## Phase 5 — Supply Chain, Compliance & Docs (P1-6, P1-10, P2-8)

- [~] **5.1** Artifact signing + SBOM + (optionally) GitHub artifact attestation in `release.yml`. — **DONE in the workflow, pending live proof:** `31a23aa` release-path gates + SBOM + checksums; `d25c637` attestation marker; `cd726ec` keyless cosign signing enabled (SHA-pinned installer, `dist/*.bundle` published), every job bound to the attested commit, Buildkite gate set includes `coverage-kcov`; `88d92e4` actionlint-clean. Stays `[~]` until the first tagged release produces and verifies bundles — no tag was created.
- [x] **5.2** `FontPatcher/ATTRIBUTION.md` consolidating mixed glyph licenses; correct `FONT_MANIFEST.md`; include attribution in release archives. — **DONE (M5)**: `ccc9147` per-component license table + mixed-license statement; `31a23aa` attribution + SBOM in release artifacts.
- [x] **5.3** `docs/SECURITY.md` (trust boundaries, installer policy, mutation policy), `docs/OPERATIONS.md` (runbooks), `config/README.md`. — **DONE (M5)**: `ccc9147` compliance set (SECURITY/OPERATIONS/config README); `31a23aa` MAINTENANCE runbook.
- [x] **5.4** ADR directory (`docs/governance/adr/`) seeded from MASTER_AUDIT §5 decisions. — **DONE (M5)**: `ccc9147` ADRs 001–005 (keep-shell, argv-not-bash-c, actions-SHA-pinned, jq-optional, platform-governance).
- [x] **5.5** Commit `package-lock.json` or drop the npm shellcheck devDependency. *(P2-11)* — **DONE (M5)**: `7df7744` removed the npm ShellCheck devDependency; `package.json` has no npm dependency to lock.

## Deferred / Watch List

- **Option C hybrid** (compiled helper for planning/locking/downloads) — revisited after Phase 3 and **not adopted** ([ADR-006](adr/adr-006-compiled-helper-not-adopted.md), 2026-10-10). *(P3-5 decided)*
- **Windows/Git-Bash CI runner** — only if native Windows support is ever implemented; today native Windows is documented as unsupported (`9cc1f67`). *(P2-10 resolved)*
- **Module decomposition of `lib/cache.sh` / `version-manager.sh`** — refactor around stable interfaces only after Phase 4 contracts exist; file size alone is not a trigger.

---

## Reconciliation Note (2026-10-06)

Source and commit inspection at `40562ee` distinguishes completed named work
from remaining acceptance criteria. Earlier M4/M5 GO entries are historical,
scoped evidence, not proof that every registry mutator is adopted or that
coverage/signing is enabled. Remaining adoption includes workstation files,
not just disposable caches. Phase 3 safety work remains the next priority.

Signing is still hard-disabled pending an owner decision; the attestation
marker workflow exists but its release/CI continuity needs operational proof.
No new CI run, release, tag or commit is claimed by this reconciliation.
Working-tree changes require review and merge before their items become done.

Terminal-output safety fix integrated on `fix/terminal-mutation-safety`:
VS Code generator and preview repair (`96da206`), icon editor (`a94b72d`),
slick-terminal bundle (`4eb2c20`), and shared rollback/lock corrections
(`a03f8e7`). The original CLI defaults and output locations are retained.
See MASTER_AUDIT and MUTATION_REGISTRY for regression evidence and boundaries.
The broader registry, coverage instrumentation and release-signing decisions
remain separate roadmap work; completing this fix does not mark them done.

## Reconciliation Note (2026-10-09)

The remediation sweep on `fix/managed-manager-config` (base `6a9f1c4`) closes
AX-6a..g and AX-8..AX-21 plus REL-PROV/P1-6 in the workflow (see MASTER_AUDIT
"Remediation sweep findings"). 3.1 and 3.4 are ticked with the boundaries
stated above; 5.1 stays in progress until a tagged release proves signing.
Still open by design: P3-2 complete per-operation metadata, P3-4 API
conformance tests, the deferred watch list (P2-10 Windows runner, P3-5).
Linux-only behaviour (AX-21 stat/cmp, AX-7 class) is proven only by hosted CI.
The first hosted run of the sweep (Buildkite #59) failed on Linux, macOS and
kcov; the causes (AX-22: dry-run shell-startup probe, `--full` abort, macOS
java stub, a Linux-unreachable wizard assertion) were reproduced, the Linux
ones in `ubuntu:22.04`, and fixed with regressions.

## Reconciliation Note (2026-10-10)

Closes the items left open on 2026-10-09, each with a RED→GREEN regression:
P3-2 per-operation audit metadata (`e9c9730`); P3-4 API conventions and the
`test_api_conformance.sh` gate (`491898d`); P1-5 broadened local secret hook
(`28cedee`, `f96b6ac`) and SHA-256-verified gitleaks install (`7799fe3`); the 3.4
`install-* --dry-run` boundary (`8b57f56`); AX-23 content-hash checks that
fell open without `shasum` (`eb18556`). P2-10 is resolved by correcting the
platform claims (`9cc1f67`), not by adding a Windows runner. The expected
`broken` state of the dormant `release-attest` step is documented in
`docs/RELEASE_CHECKLIST.md` (`5a0167d`). P3-5 was revisited, since its
ADR-001 trigger had fired, and decided: Option C is not adopted (ADR-006).
P2-1 is recorded as resolved by policy (ENGINEERING_RULES §3, enforced by
`test_library_contract.sh`). SECURITY.md's audit-journal format and
known-gaps list are current (`86792f8`); kcov `coverage/` is ignored
(`8f83c42`). The only open item is 5.1 live signing proof, which closes
with the first tagged release (an owner action).
