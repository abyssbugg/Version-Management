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
| P1-1 | Lock acquisition is check-then-write (TOCTOU race) | **FIXED** (`026cdd3`, 2026-07-04); **re-fixed** `f9ae430` (2026-10-10, re-audit F3/RA-1) | `lib/lock.sh`: atomic mkdir + ownership-checked release; adopted by version-manager, setup-theme, setup-versions. The 2026-07-04 status overstated it: stale reclaim renamed a lock aside, so a reclaimer could displace a recycled live lock and a stalled claimer could co-own a newer one. Reclaim is now in-place `rmdir` of dead-owner markers only, and a claim holds only as sole owner | Concurrency-tested, 10 contenders, zero overlap; plus the three re-audit races. Residual: PID reuse between `kill -0` and `rmdir` |
| P1-2 | `cache_namespace_clear` runs `rm -rf "${CACHE_DIR:?}/${namespace:?}"` with namespace validated only as non-empty; `cache_clear_all` removes `$CACHE_DIR` wholesale | **FIXED** (`50216cf`, 2026-07-04) | `_cache_validate_namespace` enforces `^[A-Za-z0-9_-]+$`; CACHE_DIR sanity check before full clear | Canary-verified: invalid namespaces delete nothing |
| P1-3 | `fix-nvm-issues.sh` raw appends, NVM_SILENT drift and missing transactions | **FIXED** (`58b967d`, `3af0549`) | `lib/mutation.sh:mutation_nvm_block`, `scripts/fix-nvm-issues.sh`; `tests/integration/test_fix_nvm_managed.sh` | Canonical managed block and transaction-backed replacement landed in M4 |
| P1-4 | `validate_safe_path` warned on `..` and returned success | **FIXED** (`c158de3`) | `lib/validation.sh:validate_safe_path`; `tests/unit/test_path_validation.sh` | Fail-closed lexical validation and canonical containment, tracked also as A4/B1.3 |
| P1-5 | Secret scanning is one narrow regex (quoted lowercase assignments only); no secret-scan job in CI | **FIXED** (`8f6d269` 2026-07-04; `7799fe3`, `28cedee`, `f96b6ac` 2026-10-10) | gitleaks runs in CI (Buildkite `secret-scan`, part of the release gate set); its pinned tarball is SHA-256 verified before install, cross-checked against upstream `checksums.txt` and guarded by `test_ci_downloads_checksum_verified` (`7799fe3`). Local hook `scripts/check-no-secrets.sh` now matches case-insensitive names with prefixes/suffixes, `=` or `:`, quoted literals ≥4 chars, and skips `$` expansions; `tests/unit/test_secret_hook.sh` RED 7 → 0 (`28cedee`); its fixtures are built at run time so the file itself is clean, and `.gitleaksignore` entry 3 covers the placeholder lines of `28cedee` (`f96b6ac`; gitleaks 8.28.0 full history 0 findings) | gitleaks in CI stays authoritative; a gitleaks pre-commit hook was not added (it needs a Go toolchain build in the pre-commit job) |
| P1-6 | Release artifacts checksummed but not signed; no SBOM; no provenance/attestation | **FIXED in workflow; live proof pending** (`31a23aa`, `d25c637`, `cd726ec`, 2026-10-09) | `cd726ec` enables keyless cosign (GitHub OIDC; `sigstore/cosign-installer` SHA-pinned v3.10.1, cosign v2.6.1) in a dedicated `sign` job, publishes `dist/*.bundle`, and binds every release job to the attested commit (REL-PROV). The repository is public, so the Rekor identity reveals nothing new | Proven only by the first tagged release: no tag was created by this remediation |
| P1-7 | `validate-quality.sh` returns 0 even when degraded | **FIXED** (`78369bf`, 2026-07-04) | was: `tools/validate-quality.sh:53-64` | Gating by default; `--advisory` flag for report-only |
| P1-8 | `cache_stats` defined **twice** in the same file (flat + namespaced API layers); later definition silently wins | **FIXED** (`50216cf`, 2026-07-04) | single definition remains; test asserts `grep -c '^cache_stats()' lib/cache.sh` == 1 | No other duplicate functions found in the file |
| P1-9 | Platform detection duplicated with behavioral drift: `lib/utils.sh` `get_os` returns `wsl`; `version-manager.sh`, `version-advanced.sh`, `lib/env.sh` (`detect_os`) return `linux` for WSL. `get_shell` also duplicated | **FIXED** (`668f7a1` canonical API + `b7d1007` root-script wrappers, 2026-10-04) | canonical platform API in `lib/env.sh` (`get_os` = alias of `detect_os`; WSL reports `wsl` from BOTH, pinned by `tests/unit/test_platform_contract.sh`, `VMS_PROC_VERSION` seam); 13 libs' `SCRIPT_DIR` renamed `_VMS_<LIB>_DIR`; `version-manager.sh`/`version-advanced.sh` now source `lib/env.sh` and delegate — wrapper-parity cases RED at base (4 drift assertions) → GREEN 47/47; WSL-coupled consumers keyed `linux|wsl` preserving exact pre-fix behavior. Live-WSL execution unverified (no WSL host); proven by seam construction. **2026-10-11:** the seam fixture was fabricated and hid two defects, fixed as WSL-1 (WSL2 kernels misdetected as `linux`) and WSL-2 (`pyvm`/`phpenv` installers were not re-keyed); a manual live WSL2 lane exists (WSL-3) |
| P1-10 | `FONT_MANIFEST.md` presents Apache 2.0 while bundled glyph sets are mixed-license (codicons CC-BY-4.0, font-awesome CC-BY/OFL/MIT, octicons MIT, materialdesign MIT/Apache) — compliance/redistribution risk | **FIXED** (`ccc9147` docs + `31a23aa` release artifacts, 2026-10-04) | `FontPatcher/ATTRIBUTION.md` per-component license table (2 unresolvable licenses flagged, not guessed); `FONT_MANIFEST.md` mixed-license statement; attribution + SBOM now in the release artifact set with full checksum coverage |
| P1-11 | Coverage is pseudo-coverage: `.coverage` is manual function-marker tracking, can report >100%; no real line/path coverage engine | **FIXED (M5 lane C1)** (`546f063` merged `06f0a62`, 2026-10-06) | `Makefile:coverage-kcov` — real line coverage (`kcov --include-path=lib`, cobertura.xml), fail-closed when kcov absent; CI coverage lane on linux-small; manifest/coverage hooks in `tests/test_runner.sh` | Manual `.coverage` markers demoted to test-intent tracking only; the enforcing gate is kcov on the CI Linux lane |

### P2 — Medium

| ID | Finding | Verdict | Evidence | Decision |
|----|---------|---------|----------|----------|
| P2-1 | 16 sourced libraries + plugins lack strict mode (full inventory verified: all of `lib/auto-activate.sh, cache.sh, fonts.sh, gvm.sh, jenv.sh, metrics.sh, nvm.sh, performance.sh, phpenv.sh, pyvm.sh, rustup.sh, theme-ops.sh, utils.sh, validation.sh, plugins/asdf.sh, plugins/rbenv.sh`) | **RESOLVED by policy** (`cdcba9e`, 2026-10-02; status recorded 2026-10-10): ENGINEERING_RULES §3 is the documented policy and `tests/unit/test_library_contract.sh` enforces it — every `lib/*.sh` and `plugins/*.sh` is sourced under strict and non-strict callers and must leave `$-` unchanged (A2). Per-file header comments were not added: the contract test is the stronger guarantee | heads of each file | **Policy, not blanket fix:** executables get `set -euo pipefail`; sourced libraries deliberately avoid setting global strict mode (it would leak into callers) but must document this and code defensively. Record as ENGINEERING_RULES §3 |
| P2-2 | `setup.sh` has strict mode but no ERR trap and doesn't source `lib/error-handling.sh` | **FIXED** (`7df7744`, 2026-10-04) | sources `lib/error-handling.sh`, registers `setup_error_trap`, re-asserts `SCRIPT_DIR` after the source (error-handling re-derives it to `lib/`) |
| P2-3 | `sync` command is a dead stub ("Implementation would go here") | **FIXED** (`7df7744`, 2026-10-04) | stub removed from dispatch, body, and help text |
| P2-4 | Validators unused at public installer entry points | **FIXED** (`0648f2d` Node; 2026-10-08 Python/Ruby/PHP) | `version-manager.sh:install_node_version` (Node), `install_python_version`/`install_ruby_version`/`install_php_version` now each validate `$1` BEFORE any side effect; `lib/validation.sh` adds `validate_ruby_version`/`validate_php_version` (conservative injection grammar: start alnum, then `[A-Za-z0-9._+-]`); `tests/unit/test_validation.sh` pins accept-legit + reject-injection; `tests/integration/test_version_manager.sh` pins the Node rejection path | Public-entrypoint sweep for the four language installers complete; guards fire before network/installer/bootstrap |
| P2-5 | No log rotation/cleanup for `LOG_FILE` | **FIXED** (`7df7744`, 2026-10-04) | rotation/cleanup in `lib/logger.sh` |
| P2-6 | NVM pin `v0.39.7` (positional override exists, no env/config knob); pins duplicated in `lib/nvm.sh:89`, `setup-versions.sh:104` | **FIXED** (`7df7744` + `b7d1007` + `05ff686`, 2026-10-04) | single source of truth `lib/nvm.sh:24` (`NVM_VERSION` env-overridable); `setup-versions.sh` consumes `${NVM_VERSION}` (literal count 0); `version-manager.sh` sources `lib/nvm.sh` and consumes it as the `install_nvm` positional default (literal count 0); remaining repo-wide literals are test fixtures only |
| P2-7 | Generated Dockerfiles: single-stage, no `USER`, no `HEALTHCHECK` | **FIXED in templates** (`0648f2d`, merged `343afa7`; behavioral checks `e52ad44`; compose `1dabc18`) | `version-advanced.sh` Docker generators; `tests/unit/test_docker_templates.sh`, `tests/unit/test_version_advanced.sh` (171 P2-7 assertions with negative/near-miss controls; compose builds every template, maps each EXPOSEd port, no source bind mount over `/app`, unique host ports — AX-16) | Source/template tests, not fresh container runtime verification (no `docker build`/`compose up` in CI) |
| P2-8 | Missing docs: `docs/OPERATIONS.md`, `docs/SECURITY.md`, `docs/MAINTENANCE.md`, `config/README.md`, `FontPatcher/ATTRIBUTION.md`, no ADR directory | **FIXED** (`ccc9147` + `31a23aa`, 2026-10-04) | OPERATIONS/SECURITY/config README/ATTRIBUTION + ADRs 001–005 (codify §5.1–5.5); `docs/MAINTENANCE.md` runbook (pin table + verification recipe, release flow, known-gaps pointer) |
| P2-9 | `.shellcheckrc` globally disables SC2155, SC1091, SC2015, SC2181 **plus** SC2034 (duplicated at lines 14 & 41), SC2329, SC2016, SC2059, SC2012, SC2129 | **FIXED** (2026-10-08) | `.shellcheckrc`: duplicate SC2034 removed (single declaration); SC2181 removed from global and moved to 7 inline `# shellcheck disable=SC2181` suppressions with reasons (`lib/backup.sh:307`, `lib/cache.sh` ×4, `version-manager.sh` ×2); SC2015 re-justified in place (120 guard-with-fallback sites — kept global by deliberate decision, not silence); every remaining global disable carries a justification comment | High-risk SC2181 moved inline per §5; SC2015 re-justified; lint stays 0 across 115 scripts |
| P2-10 | CI gaps: no pre-commit job, no Windows/Git-Bash runner despite documented WSL/Windows support, no coverage gate | **RESOLVED** (2026-10-10) | pre-commit and kcov coverage are release-gate steps (Buildkite `pre-commit`, `coverage-kcov`; both green on #60). Windows: the claims were wrong, not the CI — `get_os` reports `windows` but no code path consumes it, and README's "path translation"/"PowerShell integration" had no implementation. Docs now state macOS/Linux supported and CI-tested, WSL2 supported through the Linux code paths (seam-tested, no live runner), native Windows unsupported (`9cc1f67`, `docs/PLATFORM_COMPATIBILITY.md` "Support status"). **2026-10-11:** manual-only live WSL2 lane `.github/workflows/wsl.yml` (WSL-3); not yet run (GitHub Actions billing lock) | Add a Windows runner only if native Windows support is ever implemented |
| P2-11 | No `package-lock.json` for `shellcheck ^3.0.0` devDependency (CI installs ShellCheck via apt, so exposure is local npm use only) | **FIXED** (`7df7744`, 2026-10-04) | lockfile decision recorded with the devDependency |
| P2-12 | `tests/unit/test_restore.txt` is a tracked 0-byte file; `test_backup.sh:28` uses the same name as scratch data — the committed empty file is a test byproduct | **FIXED** (`7df7744`, 2026-10-04) | file deleted; scratch outputs gitignored |
| P2-13 | `test_setup.sh` asserts only function existence; `test_version_manager.sh` is partly behavioral (its `health_check` case is existence-only) | **FIXED** (2026-10-08; `test_version_manager.sh` behavioral rewrite earlier on branch) | `tests/integration/test_version_manager.sh` already covers `create_version_files`/`health_check`/`install_node_version` behaviorally; `tests/integration/test_setup.sh` adds `test_show_configuration_reflects_state` (asserts both the present and absent branches of `show_configuration` under sandboxed HOME) and now calls `setup_test`/`teardown_test` so its writes never reach the real HOME | Behavioral scenarios per ROADMAP Phase 4; latent HOME leak in test_setup.sh closed in passing |

### P3 — Strategic (architecture evolution)

| ID | Item | Rationale |
|----|------|-----------|
| P3-1 | **FIXED for every user-file writer found (2026-10-09, `fix/managed-manager-config`):** M4 named set (`3af0549`, `a3b9038`, `7def705`, `50163f2`, `96c482b`, `08c3446`), terminal adopters (`96da206`, `a94b72d`, `4eb2c20`), manager rc writers and auto-activation, then AX-6a..g, AX-8, AX-18 (version-advanced generators via the new `mutation_file_publish`), AX-19 (font writers), AX-20 (pyvm legacy hook). Installer trees use the reversible `install_dir_stage`/`install_dir_restore` (journaled; directories are not transaction-registrable). Cache/metrics/log/lock/own-config writers stay `n/a` per the registry key | Static survey (`git ls-files` sweep of redirections, cp/mv/rm, sed -i, rc appends) is the evidence, not a proof that no future writer bypasses the framework |
| P3-2 | **FIXED** (`e9c9730`, 2026-10-10): every `_txn_journal` record carries `script=`/`pid=`/`mode=`, and every call site states `result=` and `exit_code=` plus `target=` (per file) or `files=` (per transaction); operations outside a transaction state `backup=`. `transaction_add_file` journals each registration (`result=backed_up`/`tracked_new`). Record layout (5 tab-separated columns) unchanged for existing readers; format in `docs/API.md` "Audit journal record". `tests/unit/test_audit_journal_schema.sh` RED 9 → 0. Rollback-with-errors now returns 1..255 (a 256 count used to wrap to 0) | Required for traceability; dry-run stays console-only (zero writes) |
| P3-3 | **Real test maturity**: Bats (or equivalent), kcov coverage, hermetic zsh-session tests for lazy-loading, plugin contract tests | **FIXED-equivalent (M5 lanes C1/R1)** (`546f063`→`06f0a62`; `40de815`→`86ddde9`, 2026-10-06): kcov line coverage adopted (fail-closed); plugin contract conformance suite (`test_plugin_conformance.sh`: sourcing, `$-`/shell-option purity, bash -n, required interface + dispatch delegates, namespacing, fail-closed when no plugins); hermetic execution = per-file sandboxed HOME in `test_runner.sh` + zsh-session context-prompt integration tests; Bats deliberately not adopted — native `test_runner`/`emit-manifest` retained as the equivalent harness |
| P3-4 | **Module API contracts**: public/private function conventions, `docs/API.md` conformance tests, plugin load validation (path containment, required functions, namespacing) | **FIXED**: plugin load validation (`c158de3`, B1.1; `test_plugin_conformance.sh`). Conventions (`491898d`, 2026-10-10): public = documented in `docs/API.md` under its owning module; `_`-prefixed = private, cross-module use only for five allow-listed framework helpers. `tests/unit/test_api_conformance.sh` enforces six rules (documented functions exist in their module; cross-module public uses documented; private cross-module uses allow-listed; no duplicate top-level definitions across `lib/`; every lib module has a section; allow-list entries exist) — RED 4 rules → 0 (159 documented, 430 cross-module references). No helper renamed | Global-namespace shell needs boundaries to keep scaling; the test keeps API.md from drifting |
| P3-5 | **Option C: DECIDED — not adopted** ([ADR-006](adr/adr-006-compiled-helper-not-adopted.md), 2026-10-10). The ADR-001 revisit point (P0–P2 and Phase 3 landed) was reached; each responsibility Option C would own (planning, JSON, locking, checksums, downloads) is implemented in shell and pinned by a regression test, and no defect there needed another language | Reopen only by new ADR: a recurring defect class a shell contract test cannot pin, native Windows support, or JSON processing that cannot keep `jq` optional |

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
| B2.1 | `.zshrc` bare appends, no managed blocks, `NVM_SILENT` drift | **FIXED for M4 named set** (`58b967d`, `3af0549`, `a3b9038`) | Editor and canonical NVM block adopted; per-adopter matrices in `test_mutation_editor.sh`, `test_fix_nvm_managed.sh`, `test_setup_versions_managed.sh`. Broader adoption remains P3-1 |
| B2.2 | `make clean` deletes unscoped `/tmp/test_*` | **FIXED** (`7df7744`, 2026-10-04) | clean scoped to `${TMPDIR:-/tmp}/version-management-setup/` + repo-local `test-results/`; unrelated `/tmp/test_*` survival probe tested |
| A5-new | `lib/validation.sh:12` clobbers the global `SCRIPT_DIR` on source (M1 library-invariant spirit: sourcing must not disturb caller state); caught live by the M4 fonts adopter — every font source silently retargeted to `lib/` | **FIXED** (`668f7a1`, 2026-10-04) | SCRIPT_DIR-hygiene pass: 13 libs renamed to `_VMS_<LIB>_DIR` with all internal references updated; caller-global `SCRIPT_DIR` preservation verified by `tests/unit/test_platform_contract.sh`; addendum `dd312b6`: `lib/cache.sh` lowercase `script_dir` clobber renamed `_VMS_CACHE_DIR` (same class, no in-repo caller affected) |
| B2.4 | Logger contaminates stdout of value-returning functions | **FIXED** (`520d533`, 2026-10-02) | all log levels → stderr (INFO/WARN/SUCCESS/DEBUG; ERROR already did); `tests/unit/test_logger_contract.sh` asserts the stream contract, gating, file logging, and M1 `$-` regression; `test_logger.sh` stdout-capture assertions updated to the stderr contract |

**Directive execution state (historical evidence, 2026-10-04):** M0 **GO**,
M1 **GO**, M2 **GO**, M3 **GO**, M4 **GO for the six named adopters**.
The recorded M5 GO covers platform consolidation (`668f7a1`, `b7d1007`),
hygiene (`7df7744`), compliance docs (`ccc9147`), release-integrity additions
(`31a23aa`) and transaction hardening (`05ff686`, `dd312b6`), with recorded
CI 7/7 builds #32–#33. These are prior evidence, not new CI execution.

**Source reconciliation at `40562ee` (2026-10-06):** broader mutation adoption
remains open, including workstation configuration in `theme-icon-manager.sh`
and `setup-slick-terminal.sh`, not only cache/state writers. The merge
`3968abe` contains plugin conformance tests but no kcov wiring; `Makefile`
coverage still reports manual markers. Signing is disabled; attestation
marker plumbing exists but operational continuity proof remains external.
Live WSL execution and the other documented SECURITY/MAINTENANCE gaps
remain unverified by this session.

Test-infrastructure durability (B1.8, `e1a8c66`, 2026-10-04): hosted macOS
test legs that hang now fail closed inside the run (watchdog, FAIL:124)
instead of dying silently at the 4h job timeout; per-file progress makes any
residual hang name its file in CI logs.

### P0-3-runtime-home — backup/test isolation follow-up (2026-10-06)

Confirmed in repository-only reproduction: `lib/backup.sh` freezes its default
root when sourced; changing HOME afterward leaves backup, transaction,
retention and restore-point operations targeting the previous HOME. A same-name
restore point in that prior root can be replaced. `test_mutation_editor.sh`
also sourced before sandboxing and used shared `/tmp` fixture names. The main
runner and current plugin-security test already sandbox before sourcing; this
is not evidence that every test leaks.

Two-HOME canary regressions reproduce 13 library failures and 9 editor-isolation
failures. The repair resolves defaults at call time, preserves positional
backup destinations and pins active transaction storage, with all editor
fixtures created under an outer sandbox before library sourcing. Fixed in
`a16e8a0` plus test lane `e8a16b7`: local lint/syntax pass, full manifest is
50 passed / 0 failed / 0 skipped / 0 errors, and all pre-commit hooks pass.
Independent review reported no project-code finding (one disposable wrapper
finding, removed with the wrapper). No real HOME was inspected, restored or
cleaned; the reported `.zshrc` loss and attribution remain unverified.

### P0-3-direct-run — cwd-relative `source ../helpers.sh` wipes the real `~/.zshrc` (2026-10-08)

**CONFIRMED, FIXED.** The runner-level and `setup_test` sandboxes only protect
a test that actually reaches `setup_test`. Sixteen tests sourced the harness
with the **cwd-relative** form `source ../helpers.sh`. Run directly from the
repo root (`bash tests/unit/<file>.sh`), that path does not resolve, so
`setup_test` is never defined, HOME is never sandboxed, and — because the
script has not yet enabled `set -e` at that point — execution continues to a
write against `$HOME/.zshrc` on the **real** HOME. `test_auto_activate_trust.sh`
(sentinel `printf 'export EDITOR=vi\n' > "$HOME/.zshrc"`) is the proven case:
reproduced in a disposable fake HOME, a sentinel rc file was replaced with
`export EDITOR=vi` (`sha aec1823…` → `11c7a4a…`). This is the mechanism behind
both real-workstation `~/.zshrc` losses on 2026-10-04 and 2026-10-06; the
earlier "ASCII BOAT" attribution was mistaken (BOAT wrapped an already-wiped
one-line file — its `export EDITOR=vi` is this test's sentinel).

Fixed on `fix/managed-manager-config`: every cwd-relative `source ../helpers.sh`
replaced with the self-locating, **fail-closed** form
`source "${BASH_SOURCE[0]%/*}/../helpers.sh" || { …exit 1; }` (16 files). The
test now finds the harness regardless of cwd (so `setup_test` sandboxes HOME),
and if the harness is ever unreachable the test aborts instead of running
unsandboxed. Re-reproduction from the repo root: sentinel rc **byte-identical**
(`aec1823…` preserved), test `rc=0`. Full gate green afterward (lint 0 ·
syntax 124/124 · unit 37/37 · integration 20/20). The other two HOME-rc writers
(`test_mutation_editor.sh`, `test_backup_home_isolation.sh`) were already safe
(they derive paths from `${BASH_SOURCE[0]}` and sandbox HOME before any write).

### test_rustup network/isolation hang (2026-10-08)

**CONFIRMED, FIXED.** `tests/unit/test_rustup.sh` exercised `rustup_detect`,
which runs `rustup --version`. Under the sandbox HOME (no `~/.rustup`), rustup
honored the repo's `rust-toolchain` pin (`1.81.0`) and attempted a network
toolchain auto-install, hanging until the B1.8 per-file watchdog killed it
(exit 124 at ≥300s). Environment-dependent (instant on hosts without rustup;
117s–300s+ where rustup is present), so it intermittently reddened the unit
gate and violated the test-isolation spirit (a unit test reaching the network
and writing a sandbox `~/.rustup`). Fixed by exporting `RUSTUP_AUTO_INSTALL=0`
in the test before sourcing the library — rustup answers immediately without
network; no assertion semantics change. Proven: `rustup --version` under an
empty HOME goes from `rc=124` (timeout) to instant; the test file runs 13/13 in
~0s; unit suite 37/37.

### External audit findings — safety primitives (2026-10-08)

An independent risk-focused audit of `6729325`/`d261e9d` surfaced six
code-level findings beyond the HOME-sandbox one above. Each was reproduced
read-only, then fixed on `fix/managed-manager-config` with the full gate green
(lint 0 · syntax 124/124 · unit 37/37 · integration 20/20).

- **AX-1 CLI arg boundaries (CONFIRMED, FIXED).** `version-manager.sh:parse_args`
  ended with `echo "$@"` and the caller does `mapfile -t args < <(parse_args …)`.
  `echo` space-joins remaining positionals onto one line, so `install-node 20.0.0`
  collapsed into `args[0]` with `args[1]` unset — every version-taking command
  mis-dispatched (and tripped `set -u`). Fixed: emit one arg per line
  (`printf '%s\n' "$@"`), empty-safe. Verified: `install-node 20.0.0` → count 2,
  cmd `install-node`, ver `20.0.0`; no-arg → count 0 (defaults to `help`).
- **AX-2 wizard increments under set -e (CONFIRMED, FIXED).** `scripts/setup-wizard.sh`
  used `((TOTAL_STEPS++))`/`((CURRENT_STEP++))` (10 sites). From 0 the pre-increment
  returns status 1 and aborts under `set -euo pipefail`, killing the custom-profile
  summary at the first item. Fixed with the `var=$((var + 1))` form (B1.5 class);
  verified the custom path completes.
- **AX-3 transaction register fail-open (CONFIRMED, FIXED).** `lib/backup.sh:transaction_add_file`
  appended the rollback record (`files.tsv` / `new_files.txt`) without checking the
  write, returning 0 even if it failed — a mutation could proceed with no usable
  rollback record. Fixed: both appends fail closed (return 1 + error). Commit's
  informational `metadata.json` write now warns on failure instead of silently
  claiming a clean commit (rollback never reads it, so the mutation is not failed).
  Regression pinned in `tests/unit/test_backup.sh`.
- **AX-4 restore-point collision + non-atomic replace (CONFIRMED, FIXED).**
  `create_restore_point` named payloads via `tr '/' '_'`, mapping `/a/b_c` and
  `/a_b/c` to the same file (one backup clobbered the other), and removed the old
  restore point before building the replacement. Fixed: collision-free index-keyed
  payloads (`f0000`, `f0001`, …; mapping file keeps the real path, so
  `restore_from_point` is unchanged) and atomic publish (build in a staging dir,
  then swap). Regression pinned in `tests/unit/test_backup.sh`.
- **AX-5 shared-rc lock contract (CONFIRMED, FIXED).** `setup-versions.sh`'s
  `configure-nvm` wrote `$HOME/.zshrc` under `workstation-mutation` while
  `version-manager.sh` and `lib/auto-activate.sh` write the same file under
  `workstation-config` — no mutual exclusion between concurrent rc writers.
  Fixed: `configure-nvm` now uses `workstation-config`; `install-*` keeps
  `workstation-mutation` (different targets). All three `.zshrc` writers share one lock.
- **AX-6 mutation adoption breadth (FIXED 2026-10-09 — seven lanes on
  `fix/managed-manager-config`, each RED on the old sources, then GREEN).**
  AX-6a `4cdd637` diagnostic `--fix` rc edits → managed blocks + transaction
  (`test_version_diagnostic_managed.sh` 84/0); AX-6b `6a24164` + `737e393`
  transactional `create-versions` with zero-write preview and guarded dispatch
  args (`test_create_versions_managed.sh` 134/0); AX-6c `5676b6f` patch-font
  `--install` transaction + `--dry-run` (88/0); AX-6d/e/f `ae8aa48` + `a87b156`
  reversible installer move-aside (custom roots outside `$HOME` supported,
  system roots refused, no `rm -rf` outside `$HOME`/`$TMPDIR`), consented sudo
  (`--confirm`/`VMS_CONFIRM=1`), fail-closed Composer; AX-6g `1544ff6`
  update-dependencies `--dry-run`, `--ff-only` pulls, EOF-safe prompt.
- **AX-7 export -f here-doc poisoned child bash (CONFIRMED, FIXED — `ef75bda`).**
  Regression introduced by the AX-3 hardening: `transaction_commit`'s metadata
  write was wrapped in an `if ! cat > file <<EOF ... EOF; then` compound. The
  transaction primitives are `export -f`'d (same hazard class as B1.13-new), so
  bash serializes them into `BASH_FUNC_*` and every child shell re-parses them at
  startup. A here-doc nested inside an if-condition does NOT round-trip through
  that serialization on the hosted Linux bash build (parsed clean on macOS bash
  5.3), so each child raised `bash: transaction_commit: line 16: syntax error near
  unexpected token 'fi'`. This broke every child bash the status CLI spawned; the
  python branch folded the child's stderr into its value via `python3 --version
  2>&1`, so `python.active` became `"bash:"` and `python.match` flipped false —
  the Linux-only, macOS-green failure that reddened builds #46–#57. Fixed by
  assembling the metadata with `printf -v` + a plain `printf > file` (no here-doc
  in the function body). Pinned by `test_transaction_hardening.sh`
  `test_exported_functions_reparse` (child bash starts noise-free with the fns
  exported; no exported transaction fn carries a here-doc in an if-condition).
  Lesson: an `export -f`'d function body must stay serialization-safe — no
  here-doc inside a compound command. main CI green at `ef75bda` (build #58:
  Tests Linux + macOS + Coverage all passed).

### Remediation sweep findings (2026-10-09, `fix/managed-manager-config`)

Each item was reproduced (or proven by a RED test) before the fix; every fix
carries a regression test. Full local gate after the sweep is recorded in the
branch handoff; hosted CI is the next proof.

- **AX-8 managed-block marker integrity (FIXED `11b8d01`).** An unterminated,
  stray or duplicate BEGIN/END marker made the strip pass delete every user
  line after the stray BEGIN and return 0 (reproduced: `export KEEP_ME=1`
  lost). Malformed markers are refused unchanged by write and remove; an
  existing block is replaced in place (moving it to EOF reordered dependent
  lines such as `nvm use 18`). `test_mutation_editor.sh` RED 15 → 0.
- **AX-9 rustup-init (FIXED `f23f217`).** Pinned rustup-init 1.29.1 with a
  SHA-256 per target triple; download → verify → execute.
- **AX-10 subshell lock trap (FIXED `8aa6c76`).** Inside a subshell bash ≥ 4
  still *displays* the parent's EXIT trap, so `lock_with_trap` chained it and
  the parent's cleanup ran when the subshell exited. An unused signal is reset
  first to discard the stale display. `test_lock.sh` RED on bash 5.3.
- **AX-11 dead global flags (FIXED `a87b156`, `286f7f9`).** `parse_args` runs in
  a process substitution, so `--silent/--debug/--no-color` never applied, and
  the consent warning named a `--confirm` flag that did not exist. Flags are
  applied before colors/logging; `--confirm` and `--dry-run` work anywhere;
  help colors are real ESC bytes (a literal `\033` was printed);
  `--auto-install` is documented as reserved (no consumer exists).
  `version-advanced.sh` had the same defects plus the AX-1 space-joining bug
  (`register <path>` was an unknown command).
- **AX-12 logger froze caller globals (FIXED `af3a928`, `fceffae`).**
  `readonly RED/GREEN/...` in `lib/logger.sh` killed `setup-wizard.sh`,
  `tools/system-diagnostics.sh` and `tools/analytics-report.sh` at startup
  ("GREEN: readonly variable") and overwrote a caller's disabled palette;
  sourcing it after a readonly partial palette (preview-nerd-fonts) died the
  same way. Per-variable `${VAR=default}`, never readonly.
- **AX-13 inherited `log_*` (FIXED `af3a928`).** `_log` and helpers are now
  exported; a child bash no longer prints `_log: command not found`.
- **AX-14 diagnostics under `set -e` (FIXED `af3a928`).** `((x++))` on a zero
  counter aborted system-diagnostics (22 sites), the version diagnostic tool
  and validate-setup; validate-setup stopped before its summary; fixed `/tmp`
  temp paths (one never used) replaced by mktemp. `test_tool_entrypoints.sh`
  RED 31 → 0 and a repo-wide `((var++))` guard.
- **AX-15 dry-run not honored by installers (FIXED `b914e0a`, `7507014`,
  `6c5bb21`).** Homebrew branches, runtime installs (nvm/pyenv/goenv/rbenv/
  phpenv/rustup versions and their npm/pip/gem/composer steps), fnm and the
  asdf/rbenv plugins acted for real under `TRANSACTION_DRY_RUN=1`; plugins also
  claimed success after a failed brew/clone. All print a `[dry-run]` plan;
  `version-manager.sh`/`setup-versions.sh` accept `--dry-run`. The former
  limitation (`install-* --dry-run` still created its own cache/XDG/lock
  directories) is removed (`8b57f56`): a preview disables file logging and
  caching and skips directory initialization and the lock, so the whole HOME
  tree is byte-identical afterwards (`test_vm_cli_install_dry_run_zero_write`,
  RED 10 → 0). Every other command keeps both, unchanged.
- **AX-16 generated compose (FIXED `1dabc18`).** `.:/app` hid each hardened
  image's `/app` artifact and two host-port pairs collided.
- **AX-17 duplicate `get_shell_config` (FIXED `11b73ed`).** One canonical copy
  in `lib/env.sh`, pinned by the platform contract test.
- **AX-18 version-advanced generators (FIXED `286f7f9`).** Dockerfiles,
  compose and CI configs were `cat >`-ed over existing project files; a
  multi-file command left a half-written set on failure; `auto-switch`/
  `lazy-load` executed `./version-manager.sh` from the *caller's* directory
  (RED: an impostor script in the project was executed). New
  `mutation_file_publish`; one transaction per command; `--dry-run`.
  `test_version_advanced_managed.sh` RED 20 → 49/0.
- **AX-19 font writers (FIXED `62ad115`).** `font_install_bundled`,
  `font_uninstall` and preview-nerd-fonts `--install` wrote fonts with no
  backup; `font_install_from_url` installed unverified bytes under a
  caller-chosen name (`../` traversal). Transactional, checksum-required.
  `test_font_writers.sh` RED 19 → 0.
- **AX-20 pyvm hook removal (FIXED `4f80105`).** `pyvm_remove_auto_activate`
  rewrote `~/.zshrc` via `/tmp` + `mv` (no backup, mode 0600, symlink lost) and
  an unterminated legacy block deleted every following line (reproduced). Now
  locked + transactional, malformed markers refused; the unreachable bare
  `cat >>` writer is deleted.
- **AX-21 BSD-first stat probes / bare cmp (FIXED `5e61277`).** On Linux
  `stat -f '%Lp' f` prints file-system data, so five rc/theme rewriters lost
  the file's mode (or aborted); two compared with a bare `cmp`, absent on the
  hosted Linux image. Repo-wide guard in `test_hygiene_smalls.sh`.
- **AX-22 found by the first hosted run of the sweep (Buildkite #59; FIXED
  `f5df759`).** (1) The version diagnostic's `--dry-run`
  timed shell startup with `zsh -i -c exit`, which runs the system and user
  rc files: on Ubuntu the global `/etc/zsh/zshrc` runs compinit, so the
  "zero-write" preview created `~/.zcompdump` (reproduced in `ubuntu:22.04`
  with the old tool). The probe is skipped in dry-run and still runs
  otherwise; case (e3) pins both. (2) `--full` aborted on `ZSH_VERSION:
  unbound variable` (the tool runs under bash) and reported the startup time
  as seconds labelled ms (`00.123`), breaking its `-gt 500` test; it now asks
  `zsh --version` and reports whole milliseconds. (3) system-diagnostics
  `--versions` exited 1 on a Mac without a JDK: `/usr/bin/java` is a stub that
  exits 1 and `java -version | head` ran under pipefail. (4) The setup-wizard
  test asserted the profile menu, which a Linux runner never reaches (zsh is
  not the login shell, so the step-1 prompt reads EOF and stops); it asserts
  step 1 instead. RED for each in `test_tool_entrypoints.sh` /
  `test_version_diagnostic_managed.sh`.
- **AX-23 content-hash checks fell open without `shasum` (FIXED `eb18556`).**
  `validate_backup` (run by `create_backup` on every backup) hashed only via
  `shasum`; on hosts that ship only `sha256sum` it silently compared sizes,
  so an equal-size different backup passed (RED: tampered=0). It now uses
  `_txn_sha256` and warns when the host has no SHA-256 tool at all (size-only
  kept). `font_validate_checksum` "assumed valid" with no tool; it now fails
  closed like the download path (AX-19). Regressions in `test_backup.sh` and
  `test_fonts.sh`. *Correction (re-audit F1, 2026-10-10):* the FIXED status
  covered a missing tool only — a tool that existed but failed or printed a
  non-digest still registered an empty hash and fell open. Closed in
  `12d5841` (see "Re-audit findings").
- **Test harness: pyenv shim hang (FIXED `4ebbd21`).** A direct run of
  `test_status_json.sh` resolved `python3` through a pyenv shim and hung
  (rc 124, also with the unmodified tool); the test now uses the interpreter
  from `sys.executable`. Test-only change.
- **REL-PROV (FIXED in workflow `cd726ec`, `88d92e4`).** Release jobs check out
  the attested SHA and assert a clean tree; actionlint 1.7.9 reports 0
  findings for both workflows. Live proof needs the first tagged release.
- **Repository hygiene (`35dbbe8`).** A redacted personal shell config was
  tracked at the root of the public repository; untracked at the tip (history
  not rewritten; a local copy is archived outside the repository) and
  `/tmp_rovodev_*` is ignored.

### Terminal safety fixes (2026-10-06, locally integrated)

- **P3-1-vscode:** `scripts/generate-vscode-settings.sh` used raw
  placeholder substitution and wrote output before validation. It now passes
  values as parser arguments, validates before atomic publication, preserves
  symlink content/mode, and uses existing locks/transactions for rollback.
  `tests/integration/test_vscode_settings_managed.sh` tests original-code
  failure via `VMS_TEST_BASELINE=1` and current-code behavior without it.
- **P3-1-preview:** transaction dry-run still created/appended audit and log
  files despite reporting zero writes. `_txn_journal` now skips preview
  writes and preview messages locally disable file logging. The original
  primitive fails all three cases in `tests/unit/test_transaction_preview.sh`;
  apply-mode auditing remains unchanged. This corrects the scope of earlier
  dry-run evidence, which checked backup directories and target bytes only.
  The symlink adopter's former expectation of a dry-run journal write is
  replaced with console visibility plus journal absence; its apply/restore
  audit checks are retained.

Local macOS verification: `make test` under sandboxed HOME/XDG/TMPDIR
reported **46 passed, 0 failed, 0 skipped, 0 errors** after updating the
contradictory symlink-preview assertion. Original-code controls
(`VMS_TEST_BASELINE=1`) exited 1 for both new suites; current implementations
exited 0. The manifest and command-output hashes are retained under
`test-results/manifest.json` and `test-results/rovodev-evidence/` (local,
gitignored evidence; not release artifacts).

Additional terminal fixes are integrated on `fix/terminal-mutation-safety`:

- **P3-1-icons** (`a94b72d`): safe literal icon assignment, atomic transaction
  publication, preserved prompt-mode names and Apple reset identity; original
  implementation fails 34 behavioral assertions.
- **P3-1-slick** (`4eb2c20`): fonts/settings/glyph demo are one rollback unit;
  original implementation fails 25 assertions (the known-blocking original
  FIFO case is excluded only from the baseline control).
- **P3-1-registration** (`a03f8e7`, follow-up on integration): duplicate
  registration retains first pre-state, dangling symlinks survive rollback,
  original permissions are restored without propagating immutable flags.
  The four original registration assertions fail before the fix. Local font
  installation now shares the workstation lock; a forced lock-denial regression
  fails twice before that repair.

These entries close the terminal-output fix, not the broader Phase 3 registry,
and do not constitute a new hosted-CI GO. The earlier 46-file run above is
historical evidence; final gate evidence is reported with this branch's handoff.

**P3-1/P3-2 manager-configuration follow-up** (`fix/managed-manager-config`,
2026-10-06): the six manager/lazy-load rc writers now share transactional
managed-block publication and fail closed on unmanaged or malformed blocks.
Sandbox regressions cover rollback, reruns, symlink/mode retention and
CLI preview initialization. NVM hooks only switch installed versions; missing
versions require explicit installation. The broader finding stays PARTIAL:
installer directories, version files and auto-switch are not closed here.

**Auto-activation/coverage follow-up (2026-10-06):** `ae1fd83` adds a
42-assertion rc safety matrix after 17 failures were reproduced against the
first delegated patch. Setup/removal use the shared workstation lock,
transactions, scoped cleanup and syntax verification. Malformed or legacy
markers fail closed; explicit legacy migration remains a user action. The
shared editor now reads permissions from the resolved symlink content target.
`514d9d4` selects kcov's Bash-script engine instead of tracing the Bash binary,
and rejects missing/empty reports or an empty test selection. Hosted coverage
verification remains pending; a skipped instrumentation run is not coverage.

Coverage verification also exposed B1.8 watchdog descendant leaks and B1.7
truncated diagnostics. The runner now terminates only its dedicated test
process group; a regression reproduced a surviving descendant before the fix.
The quality gate retains every finding rather than hiding entries after line
20, with a deterministic regression reproducing the missing diagnostic.
Coverage output is isolated per invocation so stale reports cannot pass a new
run. Existing managed auto-activation blocks refresh rather than silently
retaining obsolete payloads.

Hosted verification on 2026-10-08 (Buildkite #40) exposed SC2148 in the sourced
`lib/shell-experience.sh` after removal of its executable shebang. The local
Make lint target supplies `--shell=bash`, whereas the hosted lint invocation
does not. An explicit `# shellcheck shell=bash` directive supplies the dialect
without restoring executable permissions or suppressing the finding.

Buildkite #41 exposed two further environment-dependent defects. Its terminal
stdin made the shell-experience test wait for interactive confirmation; the
noninteractive refusal scenario now explicitly clears confirmation and closes
stdin, verified with a pseudo-terminal regression. GNU `stat -f` can emit
filesystem details before failing, contaminating the editor's fallback mode.
The editor now captures dialect probes separately, validates octal modes, and
refuses publication on mode lookup or chmod failure. New regressions reproduce
noisy probes and verify byte-identical targets after injected permission errors.
The unattended runner also explicitly redirects child stdin from `/dev/null`:
a pseudo-terminal regression proved it previously exposed terminal input,
allowing confirmation or immutable-file utilities to block CI. Tests needing
interactive input must allocate their own fixture terminal. A controlling-PTY
reproduction then isolated the remaining Linux health-check stop to Bash's
startup job-control handshake (SIGTTIN). Child tests now enter a separate
session before exec, retaining owned process-group cleanup without inheriting
the hosted controlling terminal; production interactive shell behavior stays
unchanged. The auto-activation test's own mode assertions now use Python stat
rather than repeating the defective BSD/GNU probe fallback.

### Re-audit findings (2026-10-10, `fix/reaudit-2026-10-10`)

Two external re-audits of `4b289fb` (findings F1–F7 and RA-1..RA-6) were
verified with sandboxed probes against that commit before any change; one
further supply-chain finding (SC-1) surfaced during verification. The
unpublished `v3.0.0` tag on `4b289fb` was deleted (its release run never
started: GitHub billing lock). Every fix has a RED run on `4b289fb` and a
GREEN run on the fix commit.

| ID | Finding (verified on `4b289fb`) | Status | Fix / evidence |
|----|----------------------------------|--------|----------------|
| F1 | A hash tool that failed or printed a non-digest registered an empty hash; the record misparsed and rollback could not restore (rc=1) | **FIXED** `12d5841` | `_txn_sha256` validates a 64-hex digest (0 ok / 1 tool failure / 2 no tool); registration refuses without a digest; `validate_backup` falls back to size only when no tool exists; byte-compare helpers fail closed |
| F2 | Replacing a restore point deleted the previous generation before the new one was in place | **FIXED** `12d5841` | Previous generation renamed aside, staging published, previous removed only on success; interrupted swaps recovered at the start of create/restore |
| F3 | Stale-lock reclaim (rename-aside) could displace a recycled live lock; a stalled claimer could co-own a newer lock | **FIXED** `f9ae430` | In-place reclaim by `rmdir` of dead-owner markers; claims require sole ownership; never `rm -rf` |
| F4 | Release attest-guard accepted any ancestor marker, so one marker attested every later commit | **FIXED** `d385a8a` | Guard moved to `scripts/release-attest-guard.sh`; marker accepted only when `<sha>..<tag>` changes nothing but `.release-attested-*` files; 17-assertion git-fixture test |
| F5 | Block-editor dry-run created a temp file next to the target before deciding it was a preview | **FIXED** `25d6588`, `25d2e14` | Dry-run decided before `mktemp`; the preview still fails loudly on an unwritable directory (adverse-conditions contract) without creating anything |
| F6 | A plugin without `plugin_info`/`plugin_init` inherited the previously loaded plugin's; unload ran the last plugin's cleanup | **FIXED** `24e0af5` | Interface names unset before each load; name validated; unload calls `<name>_cleanup` |
| F7 | A clone install inside a caller's transaction left the directory behind and made the caller's rollback fail | **FIXED** `8bcb7f2`, `06b748c` | Clone refused inside a caller-owned (non-dry-run) transaction |
| RA-1 | Whole-second timeout checked after a successful reclaim returned failure | **FIXED** `f9ae430` | Retry immediately after a reclaim |
| RA-2 | `tools/health-check.sh` ran checks through `eval`, including a string built from the repository's `.nvmrc` (code execution) | **FIXED** `a25058f` | Argv checks and named functions; no eval |
| RA-3 | Generated zsh hook renamed `nvm` by eval of its serialization | **FIXED** `42e04b7` | `functions[_nvm_original]=$functions[nvm]`; behavior pinned in real zsh. The re-audit's "unbalanced brace" sub-claim was not reproduced |
| RA-4 | Unused `mock_command`/`restore_command` used eval and a shared `/tmp/mocks` | **FIXED** `d721706` | Removed |
| RA-5 | Pre-commit hook repos pinned by tag only | **FIXED** `bbdc3a7`, `735b16c` | Commit SHAs with `# frozen:` comments, same versions; hygiene guard (made mawk-safe in `735b16c` after Buildkite #64 showed Ubuntu's awk has no `{n}` intervals) |
| RA-6 | A test started by hand (and the per-file Makefile targets) ran against the real HOME | **FIXED** `d721706` | `tests/helpers.sh` refuses the account's real home at source time; the runner opts out with a non-inheritable variable; Makefile targets go through the runner |
| SC-1 | Shell-experience plugin clones took the upstream default-branch tip | **FIXED** `8bcb7f2` | Pinned to reviewed release commits (zsh-autosuggestions v0.7.1, zsh-syntax-highlighting 0.8.0); installed HEAD must equal the pin |

Limitations the re-audit raised, closed in the same pass: the kcov gate now
enforces a union line-coverage floor (`2ea3ba2`, baseline 38.38% on #63,
floor 37.0); the two FontPatcher components with unverified licenses are
resolved against upstream and their license files vendored (`1cbd53b`).
Not closable here: a live WSL2 runner (no WSL host is available; WSL stays
supported through the Linux code paths with seam tests only; superseded by
WSL-3 below). Test hygiene
found on the way: `test_status_json` and `test_setup` leaked their sandbox
directories into TMPDIR on every run (`98a7d49`).

Hosted evidence: Buildkite #64 failed only on the RA-5 guard under mawk
(Linux, kcov); #65 (`735b16c`) and #66 (`98a7d49`) passed every gate —
Linux 73/73, macOS 73/73, kcov union coverage 2197/5583 = 39.35% (floor
37.0). Local gate twice: lint (132 scripts), syntax (141 files), unit 49/49,
integration 24/24, pre-commit all hooks. Status
corrections: P1-1 and AX-23 above were overstated and are annotated; P3-4
and P1-5 were re-checked and stand.

### WSL2 lane findings (2026-10-11, `feat/wsl2-lane`)

Building the live WSL2 lane meant checking what a real WSL2 guest reports,
which showed that the P1-9 seam test had been written around a fabricated
fixture. Both defects have a RED run on `c78c6a8` and a GREEN run on the
fix commit.

| ID | Finding (verified on `c78c6a8`) | Status | Fix / evidence |
|----|----------------------------------|--------|----------------|
| WSL-1 | `_vms_is_wsl` matched `Microsoft` case-sensitively; WSL2 kernels stamp only lowercase `microsoft` (`5.15.167.4-microsoft-standard-WSL2`), so every WSL2 host reported `linux`. The contract fixture appended a fabricated `Microsoft` token, and the host check used the same grep, so a live run would also have agreed with the wrong answer | **FIXED** `a49b8c2` | Case-insensitive match; fixtures are authentic banners (microsoft/WSL #7702, #12408: two WSL2 5.15 shapes, WSL2 4.19, WSL1); the host check reads `/proc/sys/kernel/osrelease` independently. RED 8 failures → GREEN |
| WSL-2 | P1-9 made `detect_os` answer `wsl`, but `pyvm_install` and `phpenv_install` kept bare `"linux")` arms, so WSL skipped the apt build-dependency plan (live for WSL1 since `668f7a1`; latent for WSL2 behind WSL-1) | **FIXED** `a49b8c2` | Arms are `"linux"\|"wsl"`, the pre-P1-9 behavior; dry-run installer cases under Linux, WSL1 and WSL2 banners. RED 2 failures → GREEN. Fixed in the same commit as WSL-1 so detecting WSL2 cannot regress it |
| WSL-3 | No live WSL2 execution anywhere (P1-9 / P2-10 residual) | **IMPLEMENTED, NOT YET RUN** `82840d9` | `.github/workflows/wsl.yml`, manual dispatch: `windows-2025`, `Vampire/setup-wsl` v7.0.0 pinned to commit `d1da7f2c`, Ubuntu-24.04 on WSL 2; asserts a WSL2 kernel and live `get_os == wsl`, then `make test` as an unprivileged user from a Linux-filesystem clone. A guard now requires every workflow action to be commit-pinned (RED on the tag-pinned draft → GREEN). Local proxy of the lane: `ubuntu:24.04` container, same package list, uid 1001, `make test` 73/73, and `get_os` under an authentic WSL2 banner → `wsl` (not a WSL kernel). Blocked from running by the GitHub Actions billing lock |

Found on the way: `tests/unit/test_lock.sh` resolved `source
../../lib/lock.sh` against the checkout's parent, so lint analysed
`lock.sh` only for checkouts two levels below a directory containing
`lib/` (true inside `.worktrees/`, where SC2032 fired). An explicit
`# shellcheck source=` makes the result location-independent (`82840d9`).

TH-1 (test hygiene, **FIXED** `4e15ee7`; found when an interrupted local run left
`vms-test-home.*`/`vms-test-out.*` behind): `tests/test_runner.sh` starts each
file in its own session, so TERM, HUP or Ctrl-C aimed at the runner never
reached the test. The test kept running as an orphan and its sandbox and
output file stayed in TMPDIR. The runner now traps INT/TERM/HUP, stops the
file's process group and removes both; parallel mode forwards TERM to every
per-file subshell. `tests/integration/test_runner_interrupt.sh`: RED 7
failures on `cedeb3b` (sequential TERM, sequential INT, parallel TERM: an
orphaned test and a leaked sandbox and output file in each case, plus the
runner ignoring a lone INT) → GREEN. The 34 directories that pre-fix runs had
left in TMPDIR were deleted.

Hosted evidence: Buildkite #68 (`82840d9`), #69 (`9fd2012`) and #70 (the
attestation-marker commit `cedeb3b`) passed every gate — Linux 73/73, macOS
73/73, kcov union coverage 2197/5583 = 39.35% (floor 37.0). Local gate in the
worktree: lint (132 scripts), syntax (141 files), unit 49/49, integration
24/24, actionlint 1.7.12 clean on all three workflows; with TH-1, lint 133
scripts, syntax 142 files, integration 25/25, and Buildkite #72 (`4e15ee7`)
passed every gate with Linux 74/74 and macOS 74/74.

## A3 follow-up audit (2026-10-11)

Baseline: `5ffb380`. Six additional defects were reproduced after the previous
closure claims. Repairs are integrated on `fix/a3-integration`, not published
or release-attested. Full integration gates are tracked separately below.

| ID | Confirmed defect | Repair and targeted evidence |
|----|------------------|------------------------------|
| A3-1 | Theme writers ignored transaction preview and backup failures; symlink targets were not protected | `e380f22`: shared whole-file publisher, owned/caller transaction handling, failed-registration refusal and symlink rollback. Integration follow-up removes preview cache/lock/log writes and resolves bundled themes from `config/`. `test_theme_safety.sh`. |
| A3-2 | Trusted Node hook performed raw writes, checked only node, and swallowed update failure | `9b797a2`: retain trust/opt-in, delegate to guarded updater with explicit selected bin directory and non-interactive sudo, propagate failure, validate all three sources. Integration adds shared lock, collision-resistant compensation backups and copy-through-link rollback repair. `test_nodelinks_subprocess_a3_2.sh`, `test_node_sync_safety.sh`, existing trust suite. |
| A3-3 | Public local-version setters bypassed file transactions; fnm installation ignored preview | `a084fd8`: shared `local-version.sh` used by seven managers; preview before side effects, argv callback in caller shell, restore file/link/target/mode on failure, reject caller-owned apply transaction (no savepoints). Identical-content callbacks still register pre-state. `test_local_versions_managed.sh`. |
| A3-4 | Interrupted restore-point recovery renamed directories during preview | `2a53f05`: discover and validate retained generation without recovery during preview; recover only in apply. Both restore modes covered by `test_restore_point_safety.sh`. |
| A3-5 | Pipe/newline filenames corrupted mapping records and missing payloads could report success | `2a53f05`: reject unsupported pipe/newline/CR/tab paths before staging; prevalidate complete mappings/payloads; process unterminated final records. Existing default partial-apply behavior remains, but failed sidecar backup now refuses that write. Repeat sidecars publish atomically. |
| A3-6 | Version contents could inject Dockerfile instructions | `c6c0e4c`: validate a single permitted image-tag token before staging all five language templates; hostile multiline/whitespace/comment inputs leave outputs unchanged. `test_docker_input_safety.sh`. |

Architecture decisions: retain shell-native primitives and pipe-format restore
compatibility rather than migrate stored records; unsupported names fail closed.
Local version APIs own their rollback boundary, preserving successful in-shell
activation but not compensating runtime installation or arbitrary manager state.
Node synchronization uses the existing updater in a separate process, never an
unsafe raw-write fallback. These restrictions are documented in `docs/API.md`.

Validation (2026-10-11): `make lint` passed (140 scripts), `make syntax-check`
passed, `make test-unit` passed 54/54 and `make test-integration` passed 26/26,
zero failures/skips/errors. Full `pre-commit run --all-files` passed after the
new module's executable mode was corrected. Gitleaks scanned the repair commit
range with no findings; changed documentation file links resolve. All five
worktrees were merged and removed, with merged lane branches deleted normally.
No host workstation installation or personal launcher was changed.

CodeRabbit completed review of 27 changed files. Its major finding (unchecked
theme transaction lifecycle when errexit is suppressed) was reproduced with four
failed assertions and fixed in `dca3981`; the regression passes. Its minor
callback-diagnostic finding was addressed in `506ee30`, with a passing regression
and applicable hooks. Integration follow-ups are in `9e35599`. Qodo failed twice
server-side; no successful Qodo result is claimed. Earlier delegated claims were
rejected against actual control flow and tests (interrupted recovery order,
symlink-target registration, transaction ownership, and last-command exit status).

**Outstanding verification:** no current-branch hosted Linux/macOS or coverage
result, live WSL2 execution, container-build proof, or signed-release result is
claimed. Local `bash tests/test_runner.sh coverage` failed before execution:
`Failed to exchange stderr for pipe: Bad file descriptor`, followed by
`kcov: error: Can't start/attach to ...` (all 54 subprocesses exited 255; runner
exited 1). Coverage was not weakened or reported as passing. Local Docker probing
also found no daemon at `/var/run/docker.sock`. Prior Buildkite #74 evidence
belongs to baseline `5ffb380`, not this integration branch. Billing/release
configuration and remote refs were not changed.

## Delivery follow-up (2026-10-11)

The preceding outstanding-verification paragraph records the A3 handoff, not
current coverage capability. Buildkite #75 passed all seven original gates for
`c7c6af9` (Linux/macOS 80 tests, hosted coverage 41.55% against 37%).

- **P1-11 native coverage repaired** (`ae30c80`, merged via `1bef1e6`): kcov43
  derives its trace FD from `RLIMIT_NOFILE / 4`; Darwin's inherited 1,048,575
  soft limit produced an invalid descriptor. A minimal probe failed with 255
  before the change and succeeded with a child-only 1,024 limit. The runner now
  caps only Darwin coverage children, preserving lower limits, hard limits,
  ordinary tests, and caller state. Behavioral tests pin those boundaries.
  A complete native run passed 54/54 files, 108 real reports, union
  **2459/5867 = 41.91%** with the unchanged 37% floor. The earlier delegated
  disable/skip patch was rejected and reverted, not used as a resolution.
- **P2-7 generated-image validation implemented** (`5b121b7`, `ceac3fd`):
  `make docker-build-check` requires an explicit Docker context, sends only
  synthetic fixture apps, checks image USER/HEALTHCHECK and actual non-root
  healthy runtime, disables runtime networking/capabilities, and removes only
  this invocation's exact named/labelled resources. Behavioral tests inject
  missing backend, build/run/health/UID failures and foreign-cleanup refusal.
  All eight release gates now include the real hosted Docker job.
- **Real builds exposed two template defects:** `Dockerfile.go` was copied into
  the Go package and parsed as source (Buildkite #76/#77); `6cd12bf` removes that
  copied non-source file before compilation. The Java default `17.0.12-jdk`
  did not exist (Buildkite #78); `3fabfb1` maps that shipped pin to published
  `17.0.12_7-jdk`/`-jre`, preserving the patch version (registry HEAD 200 for both,
  404 for the original JDK tag). Both have regression assertions.
- **Review:** CodeRabbit completed with three minor comments representing two
  issues. Empty-array cleanup under older Bash is guarded and tested; unused
  vulnerable Gunicorn/Flask fixture dependencies were removed in favor of a
  standard-library HTTP server. The synthetic Java wrapper is explicitly not
  a Maven-distribution integration test. Initial delegate outputs were rejected
  for unsafe shared-label cleanup, fabricated completion, and scope violations;
  only corrected implementations were integrated.
- **Release status honesty:** the dormant attestation job now emits
  `status=not_requested` on ordinary builds instead of rendering broken. That
  report is explicitly NOT release proof. Explicit empty/malformed SHA,
  tag-without-SHA, or missing token still fail; the actual pipeline command is
  exercised by `test_release_attest_dispatch.sh` without network calls.
- **Remaining account blocker:** fresh WSL run `38162711853` was refused before
  any step: "The job was not started because your account is locked due to a
  billing issue." No accessible self-hosted runner exists. Live WSL2 and GitHub
  keyless release signing require the owner to clear that lock. No tag, release,
  signing key, billing setting, or alternate-account workaround was created.

Both delivery worktrees were merged and removed. A dedicated `vms-delivery`
Colima VM was used without host-directory mounts or changing the active Docker
context, then stopped; its disk/cache was preserved, not deleted. Personal
launchers and the default Colima profile were not changed. Exact final hosted
results are reported separately; a running build is never called a pass.

**Reconciliation scope:** Commit/source inspection is not proof of a fresh
release, CI run or platform execution. Working-tree remediation is tracked
separately until review and merge; no finding is closed merely because its
phase or a merge-commit subject mentions it.
