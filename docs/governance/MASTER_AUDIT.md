# MASTER AUDIT — Single Source of Engineering Truth

**Status:** Authoritative. Supersedes all prior audit documents.
**Baseline commit:** `ffda468` (2026-07-04)
**Provenance:** Consolidated from two independent audits — GPT-5.5 (architecture/governance focus) and GLM-5.2 (implementation focus) — cross-verified finding-by-finding against the live codebase by three independent read-only verification passes. Original audits are preserved as historical evidence in `docs/analysis/` and MUST NOT be treated as active specifications.

**Maintenance protocol:** When a finding is remediated, update its Status here (do not edit the historical audits). Re-verify line references after any large refactor.

---

## 1. Verification Methodology

Every claim from both source audits was checked against HEAD `ffda468`. Verdicts:

- **CONFIRMED** — present as described, with current line evidence
- **PARTIAL** — present, but the original claim over/understated it (correction noted)
- **FIXED** — already remediated by prior commits (e.g. `806bf0f`)
- **REJECTED** — adjudicated as wrong or harmful advice (see §5)

Line numbers below are verified against the baseline commit, not copied from the audits.

## 2. Executive Verdict

The project is **functionally strong but pre-enterprise-hardening** (GPT-5.5's characterization adopted over GLM-5.2's "production ready with moderate risk"). The dominant correctness constraint is **safe mutation of a developer workstation**: the codebase has good backup/transaction primitives but applies them inconsistently, executes string-commands via `eval` in shared APIs, emits `curl|bash` patterns in generated artifacts, and has release gates that do not gate.

## 3. Active Finding Register

### P0 — Critical (safety, release integrity, injection surface)

| ID | Finding | Verdict | Evidence (verified) | Decision |
|----|---------|---------|---------------------|----------|
| P0-1 | Release lint is non-gating: `make lint \|\| true` | **FIXED** (`8f6d269`, 2026-07-04) | was: `.github/workflows/release.yml:96` | Lint now gates release |
| P0-2 | Release only warns on package.json ↔ git tag version mismatch | **FIXED** (`8f6d269`, 2026-07-04) | was: `.github/workflows/release.yml:69-72` | Mismatch now exits 1 |
| P0-3 | Integration test mutates the **real** `~/.zshrc`: `test_nvm_fixes.sh` calls `fix_nvm_issues` with no HOME sandbox; harness has no global sandboxing | **FIXED** (`d4e752d`, 2026-07-04) | was: `tests/integration/test_nvm_fixes.sh:7-13` → `scripts/fix-nvm-issues.sh:48,52`; `tests/helpers.sh:147-150` (empty `setup_test`) | Runner-level per-test HOME/XDG sandbox + `setup_test`/`teardown_test` sandbox for direct execution |
| P0-4 | String-command `eval` in shared APIs: `safe_exec`/`safe_exec_backoff`, `cache_safe_execute`, `cache_version` | **FIXED** (`321ae5e`, `50216cf`, 2026-07-04) | argv APIs added; string forms deprecated with warnings; `safe_exec_shell_trusted` is the sole literal escape hatch | Injection-regression tests cover spaces/;/backticks/$()/glob |
| P0-5 | Generated CI templates emit 9 pipe-to-shell installer lines (nvm/pyenv/rustup × GitHub Actions/GitLab/CircleCI), contradicting the project's own refusal of `curl\|bash` (`version-manager.sh` fnm installer) | **FIXED** (`68eb4a0`, 2026-07-04) | Templates now use official setup actions / language images; zero pipe-to-shell (grep-proven) | Generated YAML PyYAML-validated |
| P0-6 | Privileged mutations lack full consent controls: `sudo ln -sf` into `/usr/local/bin` has backup+restore but **no `--dry-run`**, and passwordless sudo bypasses its confirmation; `/etc/shells` append has no dry-run/confirm/backup | **FIXED** (`0c6b674`, 2026-07-04) | was: `tools/update-global-node-symlinks.sh:37,45,133-143,166`; `scripts/fix-terminal-issues.sh:96` | Plan-by-default + `--confirm`; /etc/shells: diff preview, backup, consent gate |

### P1 — High

| ID | Finding | Verdict | Evidence | Decision |
|----|---------|---------|----------|----------|
| P1-1 | Lock acquisition is check-then-write (TOCTOU race) | **FIXED** (`026cdd3`, 2026-07-04) | `lib/lock.sh`: atomic mkdir + stale-reclaim + ownership-checked release; adopted by version-manager, setup-theme, setup-versions | Concurrency-tested, 10 contenders, zero overlap |
| P1-2 | `cache_namespace_clear` runs `rm -rf "${CACHE_DIR:?}/${namespace:?}"` with namespace validated only as non-empty; `cache_clear_all` removes `$CACHE_DIR` wholesale | **FIXED** (`50216cf`, 2026-07-04) | `_cache_validate_namespace` enforces `^[A-Za-z0-9_-]+$`; CACHE_DIR sanity check before full clear | Canary-verified: invalid namespaces delete nothing |
| P1-3 | `fix-nvm-issues.sh` appends raw lines to `~/.zshrc`; idempotency checks are inconsistent (`NVM_SILENT=1` vs `NVM_SILENT=true`); no managed BEGIN/END blocks; no transactions | CONFIRMED | `scripts/fix-nvm-issues.sh:52,75` | Use managed blocks (`# BEGIN version-management-setup:<name>` … `# END`), replaced atomically under a backup transaction |
| P1-4 | `validate_safe_path` only **warns** on `..` and returns success | CONFIRMED | `lib/validation.sh:138` | Fail on `..` for security-critical call sites |
| P1-5 | Secret scanning is one narrow regex (quoted lowercase assignments only); no secret-scan job in CI | **PARTIALLY FIXED** (`8f6d269`, 2026-07-04) | gitleaks job added to `test.yml`; local hook regex unchanged | CI now scans with gitleaks; upgrading the local hook regex remains optional |
| P1-6 | Release artifacts checksummed but not signed; no SBOM; no provenance/attestation | CONFIRMED | `release.yml:148,237`; no cosign/gpg/sbom/attest anywhere | Add artifact signing + SBOM generation to release workflow |
| P1-7 | `validate-quality.sh` returns 0 even when degraded | **FIXED** (`78369bf`, 2026-07-04) | was: `tools/validate-quality.sh:53-64` | Gating by default; `--advisory` flag for report-only |
| P1-8 | `cache_stats` defined **twice** in the same file (flat + namespaced API layers); later definition silently wins | **FIXED** (`50216cf`, 2026-07-04) | single definition remains; test asserts `grep -c '^cache_stats()' lib/cache.sh` == 1 | No other duplicate functions found in the file |
| P1-9 | Platform detection duplicated with behavioral drift: `lib/utils.sh` `get_os` returns `wsl`; `version-manager.sh`, `version-advanced.sh`, `lib/env.sh` (`detect_os`) return `linux` for WSL. `get_shell` also duplicated | PARTIAL (env.sh uses `detect_os`, not `get_os`) | `version-manager.sh:130`, `version-advanced.sh:109`, `lib/utils.sh:188-195`, `lib/env.sh:96-107`; `get_shell` at `version-manager.sh:151`, `lib/utils.sh:222` | Canonical platform API in `lib/env.sh`; others become thin wrappers; add contract test pinning WSL behavior |
| P1-10 | `FONT_MANIFEST.md` presents Apache 2.0 while bundled glyph sets are mixed-license (codicons CC-BY-4.0, font-awesome CC-BY/OFL/MIT, octicons MIT, materialdesign MIT/Apache) — compliance/redistribution risk | PARTIAL (families listed, licenses not) | `FONT_MANIFEST.md:29,46-52`; license files under `FontPatcher/src/glyphs/*/LICENSE*` | Add consolidated `FontPatcher/ATTRIBUTION.md`; include in release artifacts |
| P1-11 | Coverage is pseudo-coverage: `.coverage` is manual function-marker tracking, can report >100%; no real line/path coverage engine | CONFIRMED | `Makefile:88-90`; `tests/helpers.sh:166-191` | Treat as test-intent tracking; adopt real coverage (kcov/bashcov) in P3 test-maturity phase |

### P2 — Medium

| ID | Finding | Verdict | Evidence | Decision |
|----|---------|---------|----------|----------|
| P2-1 | 16 sourced libraries + plugins lack strict mode (full inventory verified: all of `lib/auto-activate.sh, cache.sh, fonts.sh, gvm.sh, jenv.sh, metrics.sh, nvm.sh, performance.sh, phpenv.sh, pyvm.sh, rustup.sh, theme-ops.sh, utils.sh, validation.sh, plugins/asdf.sh, plugins/rbenv.sh`) | CONFIRMED | heads of each file | **Policy, not blanket fix:** executables get `set -euo pipefail`; sourced libraries deliberately avoid setting global strict mode (it would leak into callers) but must document this and code defensively. Record as ENGINEERING_RULES §3 |
| P2-2 | `setup.sh` has strict mode but no ERR trap and doesn't source `lib/error-handling.sh` | CONFIRMED | `setup.sh:7`; `setup_error_trap` exists at `lib/error-handling.sh:220-222` | Source error-handling and register trap |
| P2-3 | `sync` command is a dead stub ("Implementation would go here") | CONFIRMED | `version-advanced.sh:858-860` | Remove or implement; do not ship stub commands |
| P2-4 | Validators exist but unused at key call sites (`install_node_version` doesn't validate `$version`) | CONFIRMED | `version-manager.sh:792-811`; `lib/validation.sh:100` | Sweep public entry points; validate all user-supplied parameters |
| P2-5 | No log rotation/cleanup for `LOG_FILE` | CONFIRMED | `lib/logger.sh:60-63` | Age-based cleanup (retain N days) |
| P2-6 | NVM pin `v0.39.7` (positional override exists, no env/config knob); pins duplicated in `lib/nvm.sh:89`, `setup-versions.sh:104` | PARTIAL | `version-manager.sh:307,1246` | Single configurable pin (`NVM_VERSION` env + one default constant); review currency |
| P2-7 | Generated Dockerfiles: single-stage, no `USER`, no `HEALTHCHECK` | CONFIRMED | `version-advanced.sh:468,499,604,638,674` | Upgrade templates to multi-stage + non-root + healthcheck |
| P2-8 | Missing docs: `docs/OPERATIONS.md`, `docs/SECURITY.md`, `docs/MAINTENANCE.md`, `config/README.md`, `FontPatcher/ATTRIBUTION.md`, no ADR directory | CONFIRMED | paths absent | Create per ROADMAP Phase 5; ADRs start with the decisions in §5 below |
| P2-9 | `.shellcheckrc` globally disables SC2155, SC1091, SC2015, SC2181 **plus** SC2034 (duplicated at lines 14 & 41), SC2329, SC2016, SC2059, SC2012, SC2129 | CONFIRMED (broader than audits claimed) | `.shellcheckrc:7-41` | Re-justify each; move high-risk ones (SC2015, SC2181) to inline suppressions |
| P2-10 | CI gaps: no pre-commit job, no Windows/Git-Bash runner despite documented WSL/Windows support, no coverage gate | CONFIRMED | `.github/workflows/test.yml:9-40` | Add pre-commit job now; Windows runner when platform claims are load-bearing |
| P2-11 | No `package-lock.json` for `shellcheck ^3.0.0` devDependency (CI installs ShellCheck via apt, so exposure is local npm use only) | CONFIRMED (Low) | `package.json:36-37`; `test.yml:18` | Commit a lockfile or drop the npm devDependency entirely |
| P2-12 | `tests/unit/test_restore.txt` is a tracked 0-byte file; `test_backup.sh:28` uses the same name as scratch data — the committed empty file is a test byproduct | PARTIAL ("orphan" imprecise) | file is 0 bytes, tracked | Delete and gitignore test scratch outputs |
| P2-13 | `test_setup.sh` asserts only function existence; `test_version_manager.sh` is partly behavioral (its `health_check` case is existence-only) | PARTIAL | `tests/integration/test_setup.sh:9-21`; `test_version_manager.sh:14-57,67-69` | Add scenario tests per ROADMAP Phase 4 |

### P3 — Strategic (architecture evolution)

| ID | Item | Rationale |
|----|------|-----------|
| P3-1 | **Transactional mutation framework** — plan/apply/verify/commit-or-rollback wrapper adopted by every script that mutates user or system files. `lib/backup.sh` transactions (`lib/backup.sh:490+`) are the seed; `setup-theme.sh:182-191` is the reference adopter. Non-adopters verified: `fix-nvm-issues.sh`, `setup-versions.sh`, `emergency-recovery.sh`, `setup-fonts-enhanced.sh` | The project **is** configuration management; declarative plan→apply is the correct end-state |
| P3-2 | **Operation audit journal** (`~/.config/version-manager/audit.log`): timestamp, script, operation, targets, mode, backup ID, result, exit code | Required for enterprise traceability of workstation mutations |
| P3-3 | **Real test maturity**: Bats (or equivalent), kcov coverage, hermetic zsh-session tests for lazy-loading, plugin contract tests | Current coverage numbers are not trustworthy signals |
| P3-4 | **Module API contracts**: public/private function conventions, `docs/API.md` conformance tests, plugin load validation (path containment, required functions, namespacing) | Global-namespace shell at 74 files needs boundaries to keep scaling |
| P3-5 | **Option C (deferred)**: optional compiled helper for planning/JSON/locking/checksums/downloads, shell remains the UX layer | Revisit only after P0–P2 and P3-1 land; not now |

## 4. Findings Already Fixed or Neutralized (do not re-fix)

| Original claim | Reality at `ffda468` |
|----------------|----------------------|
| "Mutating scripts don't use backup transactions" (GPT §4.3) | **Stale for `setup-theme.sh`** — it uses `transaction_start/commit/rollback` (`setup-theme.sh:182-191`). Remaining non-adopters tracked as P3-1 |
| Version-manager init `eval "$(fnm env)"`, `eval "$(pyenv init -)"` flagged as injection surface | **Accepted** — hard-coded trusted-literal init patterns, standard for these tools (`version-manager.sh:485,587`). Policy boundary documented in ENGINEERING_RULES §4; no code change |
| `check_internet` pinging 8.8.8.8 as "information leak" (GLM) | Non-finding; noted only for completeness |

## 5. Adjudicated Conflicts (Architecture Decisions)

These are binding decisions. Reversing one requires a new ADR.

### 5.1 `actions/checkout` pinning — GLM recommendation REJECTED

GLM-5.2 advised moving from SHA pin to `v4` tag "for maintainability". GPT-5.5 called SHA-pinning a strength. **Verified state:** SHA-pinned with `# v4.2.2` comment (`test.yml:15`, `release.yml:40`). **Decision: keep SHA pinning.** Immutable-ref pinning is supply-chain best practice for third-party actions; a tag can be moved by an attacker. The version comment preserves maintainability.

### 5.2 `eval` remediation — GLM's `bash -c` suggestion REJECTED

GLM-5.2 suggested replacing `eval "$command"` with `bash -c "$command"`. **This is not safer** — the injection surface is the dynamic command *string*, not the evaluator. **Decision:** adopt GPT-5.5's approach — argv-array APIs (`safe_exec_argv`) plus a clearly named trusted-literal escape hatch (`safe_exec_shell_trusted`), then deprecate the string API.

### 5.3 `jq` → pure-bash JSON parser — GLM recommendation REJECTED

Hand-rolled JSON parsing in bash trades a well-audited optional dependency for a fragile one-off parser. `jq` remains optional with graceful degradation.

### 5.4 Overall posture — GPT-5.5 verdict ADOPTED

"Pre-enterprise-hardening" over "production ready with moderate risk". Rationale: unsandboxed mutating tests (P0-3), non-gating release lint (P0-1), and inconsistent transaction adoption are disqualifying for the "enterprise-ready" label regardless of feature completeness.

### 5.5 Language/rewrite question — Option B ADOPTED

Keep shell, add guardrails (GPT-5.5 trade-off analysis §13). Full rewrite rejected (loses shell-native sourcing ergonomics, duplicates version-manager behavior anyway). Compiled-helper hybrid (Option C) deferred to P3-5.

## 6. Sources

- `docs/analysis/audit-2026-07-04-gpt5.5.md` — historical, architecture/governance perspective (stronger overall; primary source for §3 P0/P3 and §5)
- `docs/analysis/audit-2026-07-04-glm5.2.md` — historical, implementation perspective (primary source for duplication/inventory findings)
- `docs/analysis/audit-2026-07-04-adjudication-chatgpt.md` — historical, cross-audit quality assessment that mandated this consolidation

---

## 6. Remediation-Program Register (merged-audit-directive.md v3 — added 2026-10-02)

Directive-scoped findings beyond the P0–P3 register above. **Correction (A2):**
P2-1 above records the *absence* of strict mode in sourced libraries as the
concern; the live defect was the **inverse** — four libraries (`logger.sh`,
`env.sh`, `backup.sh`, `plugins.sh`) set `set -euo pipefail` and leaked it into
every caller, transitively into every module sourcing them. P2-1's policy
position (libraries must not set global strict mode) is unchanged and now
enforced by contract test. P1-3 and P3-1/P3-2 remain tracked below via their
directive milestone mapping (M4).

| ID | Finding | Status | Evidence |
|----|---------|--------|----------|
| A1 | Make test targets mask failures (`for` loop last-iteration exit); release trusts them | **FIXED** (`104e65e`, `683ccbe`) | `make test*` routed through `tests/test_runner.sh` via `tests/emit-manifest.sh`; canonical manifest; seeded-failure meta-tests (`tests/unit/test_gate_meta.sh`) proven red in CI (builds #12) |
| A2 | Four sourced libraries leak strict mode (`set -euo pipefail`) into callers | **FIXED** (`cdcba9e`) | direct setters stripped; `tests/unit/test_library_contract.sh`: every lib+plugin sourced under strict AND non-strict callers, `$-` preservation asserted — 0 violations; blast radius was broader than the four named (all modules sourcing them) |
| A3 | Transaction rollback can restore wrong file contents (basename keying, name interpolation, same-second collision) | **FIXED** (`fcbc584`, 2026-10-02) | hardened primitive: index-keyed backups, hash-verified rollback (tamper-refusing), name grammar, `mktemp -d` exclusivity, dry-run zero-writes, audit journal; 8-case matrix (22 assertions) written first — 13 failures reproduced against the old primitive, then green; CI build #19 7/7 |
| A4 | Path containment accepts sibling-prefix paths; validators have zero production callers | OPEN — M3 | `lib/validation.sh`; fail-closed redesign + wiring scheduled M3 |
| B1.1 | Plugin path traversal (`plugin_install`/`plugin_remove` unvalidated names) | OPEN — M3 | single-witness critical with sandbox repro; identifier grammar + containment scheduled M3 |
| B1.2 | Auto-activation crosses trust/privilege boundaries (chpwd sources repo scripts, installs versions, sudo symlinks on cd) | OPEN — M3 | single-witness critical; split into passive switching + explicit trust-registry commands scheduled M3 |
| B1.4 | `find -exec` syntax gate can never fail; three shipped Zsh themes failed `zsh -n` | **FIXED** (`104e65e` themes `56bd20f`) | fail-closed `scripts/syntax-check.sh` (bash -n + zsh -n, 89 files); themes repaired; gate proven red under seeded failure |
| B1.5 | `((x++))` systemic under strict mode | **FIXED** (`cdcba9e`) | 57 sites swept to `var=$((var + 1))` across 19+ files; 0 residual |
| B1.6 | Mutation inventory incomplete | **FIXED** (`cdcba9e` census artifact) | full static census: 237 sinks / 41 mutating scripts / 7 critical no-backup-no-dry-run paths; registry publication scheduled M2 |
| B1.7 | Quality gate tolerates failure (<50 lines); validate fails open without shellcheck | **FIXED** (`9957d20`→`09b78a3`) | zero tolerance; fail-closed on missing shellcheck; B1.7 meta-case rejects vacuous reds |
| B1.9 | fonts.sh `0
0` on no-match; Bash 3.2 vs 4+ contract undefined | **FIXED** (`cdcba9e`) | `|| true` on grep -c (single count); Bash >= 4.0 contract documented (ENGINEERING_RULES §3.1) and enforced in test_runner |
| B2.1 | `.zshrc` bare appends, no managed blocks, `NVM_SILENT` drift | OPEN — M4 | managed-block editor + canonical NVM block scheduled M4 with per-adopter canary gates |
| B2.2 | `make clean` deletes unscoped `/tmp/test_*` | OPEN — M5 | scoped cleanup root scheduled M5 |
| B2.4 | Logger contaminates stdout of value-returning functions | OPEN — M4 | theme_detect_current symptom tolerated in tests; contract fix lands with M4's mutation-surface rework (same call sites) |

**Directive execution state (2026-10-02):** M0 **GO** (Buildkite build #16: 7/7
green; 4-way manifest parity; seeded red observed — builds #12/#13); M1 **GO**
(`cdcba9e`: 0 contract violations, 0 arithmetic residuals, both verified by
the full suite and CI). M2 next.
