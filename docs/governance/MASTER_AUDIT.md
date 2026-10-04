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
| P1-9 | Platform detection duplicated with behavioral drift: `lib/utils.sh` `get_os` returns `wsl`; `version-manager.sh`, `version-advanced.sh`, `lib/env.sh` (`detect_os`) return `linux` for WSL. `get_shell` also duplicated | **FIXED** (`668f7a1` canonical API + `b7d1007` root-script wrappers, 2026-10-04) | canonical platform API in `lib/env.sh` (`get_os` = alias of `detect_os`; WSL reports `wsl` from BOTH, pinned by `tests/unit/test_platform_contract.sh`, `VMS_PROC_VERSION` seam); 13 libs' `SCRIPT_DIR` renamed `_VMS_<LIB>_DIR`; `version-manager.sh`/`version-advanced.sh` now source `lib/env.sh` and delegate — wrapper-parity cases RED at base (4 drift assertions) → GREEN 47/47; WSL-coupled consumers keyed `linux|wsl` preserving exact pre-fix behavior. Live-WSL execution unverified (no WSL host); proven by seam construction |
| P1-10 | `FONT_MANIFEST.md` presents Apache 2.0 while bundled glyph sets are mixed-license (codicons CC-BY-4.0, font-awesome CC-BY/OFL/MIT, octicons MIT, materialdesign MIT/Apache) — compliance/redistribution risk | **FIXED** (`ccc9147` docs + `31a23aa` release artifacts, 2026-10-04) | `FontPatcher/ATTRIBUTION.md` per-component license table (2 unresolvable licenses flagged, not guessed); `FONT_MANIFEST.md` mixed-license statement; attribution + SBOM now in the release artifact set with full checksum coverage |
| P1-11 | Coverage is pseudo-coverage: `.coverage` is manual function-marker tracking, can report >100%; no real line/path coverage engine | CONFIRMED | `Makefile:88-90`; `tests/helpers.sh:166-191` | Treat as test-intent tracking; adopt real coverage (kcov/bashcov) in P3 test-maturity phase |

### P2 — Medium

| ID | Finding | Verdict | Evidence | Decision |
|----|---------|---------|----------|----------|
| P2-1 | 16 sourced libraries + plugins lack strict mode (full inventory verified: all of `lib/auto-activate.sh, cache.sh, fonts.sh, gvm.sh, jenv.sh, metrics.sh, nvm.sh, performance.sh, phpenv.sh, pyvm.sh, rustup.sh, theme-ops.sh, utils.sh, validation.sh, plugins/asdf.sh, plugins/rbenv.sh`) | CONFIRMED | heads of each file | **Policy, not blanket fix:** executables get `set -euo pipefail`; sourced libraries deliberately avoid setting global strict mode (it would leak into callers) but must document this and code defensively. Record as ENGINEERING_RULES §3 |
| P2-2 | `setup.sh` has strict mode but no ERR trap and doesn't source `lib/error-handling.sh` | **FIXED** (`7df7744`, 2026-10-04) | sources `lib/error-handling.sh`, registers `setup_error_trap`, re-asserts `SCRIPT_DIR` after the source (error-handling re-derives it to `lib/`) |
| P2-3 | `sync` command is a dead stub ("Implementation would go here") | **FIXED** (`7df7744`, 2026-10-04) | stub removed from dispatch, body, and help text |
| P2-4 | Validators exist but unused at key call sites (`install_node_version` doesn't validate `$version`) | CONFIRMED | `version-manager.sh:792-811`; `lib/validation.sh:100` | Sweep public entry points; validate all user-supplied parameters |
| P2-5 | No log rotation/cleanup for `LOG_FILE` | **FIXED** (`7df7744`, 2026-10-04) | rotation/cleanup in `lib/logger.sh` |
| P2-6 | NVM pin `v0.39.7` (positional override exists, no env/config knob); pins duplicated in `lib/nvm.sh:89`, `setup-versions.sh:104` | **FIXED** (`7df7744` + `b7d1007` + `05ff686`, 2026-10-04) | single source of truth `lib/nvm.sh:24` (`NVM_VERSION` env-overridable); `setup-versions.sh` consumes `${NVM_VERSION}` (literal count 0); `version-manager.sh` sources `lib/nvm.sh` and consumes it as the `install_nvm` positional default (literal count 0); remaining repo-wide literals are test fixtures only |
| P2-7 | Generated Dockerfiles: single-stage, no `USER`, no `HEALTHCHECK` | CONFIRMED | `version-advanced.sh:468,499,604,638,674` | Upgrade templates to multi-stage + non-root + healthcheck |
| P2-8 | Missing docs: `docs/OPERATIONS.md`, `docs/SECURITY.md`, `docs/MAINTENANCE.md`, `config/README.md`, `FontPatcher/ATTRIBUTION.md`, no ADR directory | **FIXED** (`ccc9147` + `31a23aa`, 2026-10-04) | OPERATIONS/SECURITY/config README/ATTRIBUTION + ADRs 001–005 (codify §5.1–5.5); `docs/MAINTENANCE.md` runbook (pin table + verification recipe, release flow, known-gaps pointer) |
| P2-9 | `.shellcheckrc` globally disables SC2155, SC1091, SC2015, SC2181 **plus** SC2034 (duplicated at lines 14 & 41), SC2329, SC2016, SC2059, SC2012, SC2129 | CONFIRMED (broader than audits claimed) | `.shellcheckrc:7-41` | Re-justify each; move high-risk ones (SC2015, SC2181) to inline suppressions |
| P2-10 | CI gaps: no pre-commit job, no Windows/Git-Bash runner despite documented WSL/Windows support, no coverage gate | CONFIRMED | `.github/workflows/test.yml:9-40` | Add pre-commit job now; Windows runner when platform claims are load-bearing |
| P2-11 | No `package-lock.json` for `shellcheck ^3.0.0` devDependency (CI installs ShellCheck via apt, so exposure is local npm use only) | **FIXED** (`7df7744`, 2026-10-04) | lockfile decision recorded with the devDependency |
| P2-12 | `tests/unit/test_restore.txt` is a tracked 0-byte file; `test_backup.sh:28` uses the same name as scratch data — the committed empty file is a test byproduct | **FIXED** (`7df7744`, 2026-10-04) | file deleted; scratch outputs gitignored |
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
| A4 | Path containment accepts sibling-prefix paths; validators have zero production callers | **FIXED** (`c158de3`, 2026-10-02) | sibling-proof canonical containment (`path_validate_containment`), fail-closed lexical (`validate_safe_path`), nearest-existing-ancestor canonicalization for install targets; 11-failure red matrix → green |
| B1.1 | Plugin path traversal (`plugin_install`/`plugin_remove` unvalidated names) | **FIXED** (`5c92004`, 2026-10-02) | identifier grammar at every entry point; canonical containment on every write/delete sink; symlink-escape rejection; installs/removes transaction-routed; 30/47 red → 47/47 |
| B1.2 | Auto-activation crosses trust/privilege boundaries (chpwd sources repo scripts, installs versions, sudo symlinks on cd) | **FIXED** (`76dc3b9`, 2026-10-02) | cd hook reduced to version-switching; venv_source/node_install/symlink_sync behind persistent per-project capability registry; passwordless-sudo path asserted against a recording shim (no real elevation); rc rewrites transaction-backed; 12/12 red (3 live-vuln demos) → 51/51 |
| B1.3 | `validate_safe_path` broken by construction (NUL check dead code; '..' warn-and-pass) | **FIXED** (`c158de3`, 2026-10-02) | lexical/containment separation per B1.3's own redesign recommendation; dead NUL check replaced with newline/tab + metacharacter + '..' fail-closed checks (was folded into A4 at registration) |
| B1.4 | `find -exec` syntax gate can never fail; three shipped Zsh themes failed `zsh -n` | **FIXED** (`104e65e` themes `56bd20f`) | fail-closed `scripts/syntax-check.sh` (bash -n + zsh -n, 89 files); themes repaired; gate proven red under seeded failure |
| B1.5 | `((x++))` systemic under strict mode | **FIXED** (`cdcba9e`) | 57 sites swept to `var=$((var + 1))` across 19+ files; 0 residual |
| B1.6 | Mutation inventory incomplete | **FIXED** (`cdcba9e` census artifact) | full static census: 237 sinks / 41 mutating scripts / 7 critical no-backup-no-dry-run paths; registry publication scheduled M2 |
| B1.7 | Quality gate tolerates failure (<50 lines); validate fails open without shellcheck | **FIXED** (`9957d20`→`09b78a3`) | zero tolerance; fail-closed on missing shellcheck; B1.7 meta-case rejects vacuous reds |
| B1.8 | Test runner can hang indefinitely on a test file: per-file output capture waits on every descendant holding the inherited pipe, and no bound kills a hung file — hosted macOS test legs hung/died silently at the job timeout (exit −1 after ~4h04, zero output; hang directly observed on build #26's macOS leg — 10+ min with no output on a file that normally passes in seconds — and consistent with #24/#25 long-runner deaths; #22's macOS leg passed, its listing was imprecise) | **FIXED** (`e1a8c66`, 2026-10-04) | per-file output redirected to a temp file (runner waits only on the direct child); portable poll watchdog kills hung files at `VMS_TEST_FILE_TIMEOUT` (default 300s) recording FAIL:124; emit-manifest emits one progress line per file; meta-case 6 proves red-on-hang in seconds |
| B1.10-new | `mutation_block_write`/`mutation_block_remove` renamed the tmp file over the target path: a symlinked rc (→ user dotfiles file) was replaced by a regular file on the commit path — link type destroyed, contradicting M2 "preserve the LINK itself"; adopter strip-legacy helpers had the same rename-over-link defect | **FIXED** (`05ff686` primitives + `dd312b6` strip helpers, 2026-10-04) | `mutation_resolve_content_target` follows the chain (≤40 hops, relative targets, fail-closed on dangling/non-regular); atomic rename lands on the RESOLVED content file; both pre-states registered (link + content) so rollback restores user bytes (A3); pinned by `tests/integration/test_adverse_conditions.sh` symlink group — RED 6 assertions at base → GREEN 19/19 |
| B1.11-new | `transaction_rollback`'s symlink branch ran a bare `rm -f`: under an adopter's `set -e` an EACCES unlink aborted the rollback after the WARN but before the journal/metadata record — the rollback record was silently lost | **FIXED** (`05ff686`, 2026-10-04) | branch guards rm/ln like the file branch; partial restores still write `rolled_back_with_errors` + journal record and surface nonzero; hostile-unlink case pinned in `tests/unit/test_transaction_hardening.sh` case 9 (strict caller via child `bash -c` — `(... ) || rc=$?` ignores errexit, honest wiring note in the test) |
| B1.12-new | `lib/cache.sh` ran `cache_init` at source time with an unredirected `mkdir -p`: a read-only (555) HOME killed ANY executable sourcing the chain (setup-versions → nvm.sh → cache.sh) at load, before any mutation path | **FIXED** (`05ff686`, 2026-10-04) | source-time init degrades: stderr-only warn (B2.4), `_CACHE_OPERATIONAL` flag, setters no-op/getters miss; `bash -c 'set -euo pipefail; source lib/cache.sh; echo SURVIVED'` exits 0 under 555 HOME; writable-HOME behavior unchanged (`test_cache.sh` green); pinned by the adverse cache-source case |
| B1.13-new | `lib/backup.sh` export -f's all transaction functions; `mutation.sh`/`auto-activate.sh` guarded their backup.sh source with `declare -f transaction_start` — a grandchild inheriting the exported copies satisfied the guard, backup.sh never sourced, `_TRANSACTION_ACTIVE` never initialized, and the first transaction call died under `set -u` (`environment: line 1: _TRANSACTION_ACTIVE: unbound variable`; reproduced by the adverse suite's post-editor cases) | **FIXED** (`dd312b6`, 2026-10-04) | backup.sh re-source-safe (readonly config block guarded, functions re-declared every source); mutation.sh + auto-activate.sh source unconditionally per the M4 clean-function-slate lesson; pinned by the adverse strip cases (RED at base: unbound-variable death → GREEN 19/19) |
| B1.9 | fonts.sh double-zero on no-match (grep -c + `\|\| echo 0`); Bash 3.2 vs 4+ contract undefined | **FIXED** (`cdcba9e`) | `|| true` on grep -c (single count); Bash >= 4.0 contract documented (ENGINEERING_RULES §3.1) and enforced in test_runner |
| B2.1 | `.zshrc` bare appends, no managed blocks, `NVM_SILENT` drift | OPEN — M4 | managed-block editor + canonical NVM block scheduled M4 with per-adopter canary gates |
| B2.2 | `make clean` deletes unscoped `/tmp/test_*` | **FIXED** (`7df7744`, 2026-10-04) | clean scoped to `${TMPDIR:-/tmp}/version-management-setup/` + repo-local `test-results/`; unrelated `/tmp/test_*` survival probe tested |
| A5-new | `lib/validation.sh:12` clobbers the global `SCRIPT_DIR` on source (M1 library-invariant spirit: sourcing must not disturb caller state); caught live by the M4 fonts adopter — every font source silently retargeted to `lib/` | **FIXED** (`668f7a1`, 2026-10-04) | SCRIPT_DIR-hygiene pass: 13 libs renamed to `_VMS_<LIB>_DIR` with all internal references updated; caller-global `SCRIPT_DIR` preservation verified by `tests/unit/test_platform_contract.sh`; addendum `dd312b6`: `lib/cache.sh` lowercase `script_dir` clobber renamed `_VMS_CACHE_DIR` (same class, no in-repo caller affected) |
| B2.4 | Logger contaminates stdout of value-returning functions | **FIXED** (`520d533`, 2026-10-02) | all log levels → stderr (INFO/WARN/SUCCESS/DEBUG; ERROR already did); `tests/unit/test_logger_contract.sh` asserts the stream contract, gating, file logging, and M1 `$-` regression; `test_logger.sh` stdout-capture assertions updated to the stderr contract |

**Directive execution state (2026-10-04):** M0 **GO**, M1 **GO**, M2 **GO**,
M3 **GO**, M4 **GO for the directive-named adopter set** (all six: fix-nvm-issues,
setup-versions, fix-terminal-issues, update-global-node-symlinks,
setup-fonts-enhanced, emergency-recovery — each transaction-routed with
red→green per-adopter matrices; registry published). **M5 GO** (2026-10-04):
platform consolidation + root-script wrappers (`668f7a1`, `b7d1007`), hygiene
smalls (`7df7744`), docs compliance (`ccc9147`), release integrity
(`31a23aa`), transaction-primitive robustness (`05ff686`, `dd312b6`) — all
lanes verified (red→green where applicable; manifest 41/41 twice locally,
CI 7/7 builds #32–#33). Remaining: M4-continuation adoption of the broader
registry (cache/state-writer class, lower risk); documented known gaps in
SECURITY/MAINTENANCE (vendored font-patcher gitleaks finding, upload-artifact
version drift, keyless-signing decision, live-WSL verification).

Test-infrastructure durability (B1.8, `e1a8c66`, 2026-10-04): hosted macOS
test legs that hang now fail closed inside the run (watchdog, FAIL:124)
instead of dying silently at the 4h job timeout; per-file progress makes any
residual hang name its file in CI logs.
