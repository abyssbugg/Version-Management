# DIRECTIVE: Release-Integrity Remediation — version-management-setup

**Status: FINAL (v3, frozen 2026-08-12). This document is the binding specification. Do not propose revisions to it; execute it. Deviations require escalation per Rule 8.**

## ROLE

You are the principal engineer executing a remediation program derived from two independent repository audits (both dated 2026-08-12). Your job is not to re-audit — do not reopen the discovery phase, re-review already-settled findings, or search for new issues beyond what fixing surfaces naturally. "Do not re-audit" does NOT waive the verification this directive explicitly requires: Section A findings are settled fact (fix without re-validation); Section B findings require the scoped independent reproduction defined in that section before work begins. Two reviewers have already reproduced the critical defects in sandboxes. Your job is to fix, prove the fix with adversarial tests, and keep an auditable trail. Operate at the rigor of an architecture review board: every fix ships with evidence, every milestone has a go/no-go gate, and no gate is self-certified — it must be proven by a seeded failure turning the gate red.

## NON-NEGOTIABLE OPERATING RULES

1. **Release freeze is in effect.** No tags, no release workflow runs, no version bumps until Milestone 0 exits green.
2. **The 38 pre-existing staged files are user-owned.** Do not commit, unstage, modify, or clean them. Verify `git status` parity before and after every work session.
3. **No architecture rewrite.** Both audits independently rejected a Go/Rust/Python rewrite. The binding decision is incremental shell hardening. Do not propose otherwise.
4. **Fix trust before adoption.** Phase 3 (transaction framework rollout) remains BLOCKED until Milestones 0–2 exit. Do not migrate any mutator onto the transaction framework early, even opportunistically.
5. **Every gate must fail closed under a seeded failure.** A gate that has never been observed red is not a gate. For each CI/test/quality gate you repair, commit a meta-test that injects a deliberate failure and asserts nonzero exit.
6. **Evidence discipline.** For every finding you close: cite file:line of the fix, the test that proves it, and the command + exit code demonstrating both the red (pre-fix or seeded) and green (post-fix) states.
7. **No opportunistic refactors.** No aesthetic cleanup, no renaming, no API redesign, no restructuring beyond what a stated invariant requires. If a fix seems to demand a redesign, state the invariant that forces it and get explicit approval before proceeding. The failure mode this rule prevents: M1 quietly becoming a mini-rewrite.
8. **No silent reclassification.** No finding may be downgraded, removed, split, or reclassified without a recorded negative repro or rationale in the session report. "Solved by reclassification" is a program failure.
9. **Session snapshot.** At session start and end, record `git ls-files --stage | sha256sum` and `git diff | sha256sum` (plus `git diff --cached | sha256sum`). Post-session values must match pre-session values for the 38 protected staged files' blobs. Status parity alone is insufficient — a file can be modified and restored while status appears clean.
10. **Evidence ledger.** Maintain a per-session append-only log (outside the repo, e.g. `../remediation-evidence/session-<n>.log`): one record per evidence-bearing command — `timestamp | command | exit_code | sha256(stdout+stderr artifact)` — with raw output artifacts stored alongside, named by their hash. Append at execution time, never retrospectively. At session close, record `sha256` of the completed log; open the next session by verifying the prior log's hash. This makes evidence tamper-evident across sessions and fabrication structurally harder than execution; all red/green claims in reports must cite ledger records.

---

## BINDING INVARIANTS (write tests against these, not against individual bug reports)

Each critical subsystem gets its invariant stated before any code changes. Fixes are complete only when the invariant's adversarial tests pass, not when the originally reported symptom disappears.

- **Gate invariant:** Any deliberately seeded failure — failing test file (in any position), invalid Bash syntax, invalid Zsh syntax, ShellCheck finding, quality-score breach — turns every dependent gate (Make target, CI job, release job) nonzero. A gate that has never been observed red is not a gate. This includes the manifest comparator itself (see M0): a seeded manifest mismatch must fail the parity check.
- **Transaction invariant:** Given any sequence of successful and failed mutations, rollback either restores every pre-existing target byte-for-byte (hash-verified) or exits nonzero without claiming success. No two transactions — including concurrent same-named ones — ever share a transaction directory or backup namespace; assert this from the filesystem (distinct inodes/paths observed), not inferred from test completion.
- **Path invariant:** No operation resolves a target outside its authorized root — via `..`, sibling prefixes (`/root2` vs `/root`), absolute-path injection, or symlink traversal. Security validators fail closed; destructive APIs accept only validated inputs.
- **Library invariant:** Sourcing any `lib/*.sh` or plugin file leaves the caller's shell options (`$-`), traps, positional parameters, and stdout contract unchanged, under both strict and non-strict callers.
- **Mutation invariant:** Every workstation mutation is plan-visible (dry-run = zero writes), idempotent (rerun = zero diff), reversible (backup ID + verified rollback), and journaled (target, mode, backup ID, result, exit code).

## SECTION A — CONSENSUS FINDINGS (both audits independently reproduced; treat as settled fact, fix without re-validation)

### A1. CRITICAL — Make test targets mask failures; release trusts them
- `Makefile` unit/integration targets use `for f in tests/...; do (bash ...); done` — loop exit status is the **last** iteration only. Reproduced by both audits: an early failing test with a passing final test returns 0.
- `.github/workflows/release.yml` (~:93–99) runs `make test`, so broken code can currently ship.
- The correct orchestrator already exists: `tests/test_runner.sh` aggregates per-file exit codes. Make, package scripts, and CI simply don't call it.
- **Fix:** route `test-unit` / `test-integration` / `test` exclusively through `tests/test_runner.sh`. Delete the loop pattern everywhere. Add seeded-failure meta-test (early failing file + passing final file ⇒ `make test` exits nonzero). Exit criterion: `make test`, CI, and the direct runner emit and agree on the canonical test manifest (defined in M0) — console output comparison is not the criterion.

### A2. CRITICAL — Four sourced libraries leak strict mode into callers
- `lib/logger.sh:34`, `lib/env.sh:29`, `lib/backup.sh:25–26`, `lib/plugins.sh:15` unconditionally enable `set -euo pipefail`. Both audits probed `$-` before/after sourcing and observed `hBc → ehuBc`.
- Violates the binding library contract (ENGINEERING_RULES.md:22–24, "sourced libraries must not set global strict mode").
- Downstream blast radius: legitimately-false detector returns (`phpenv_detect`, `rustup_detect`) and `((counter++))` arithmetic kill caller shells and tests.
- **Fix:** remove global strict-mode activation from all `lib/*.sh` and plugin files. Library functions must validate arguments and propagate errors explicitly. Add a per-module contract test: capture `$-` before and after `source`, assert equality; run under both strict and non-strict callers.
- **Governance correction:** MASTER_AUDIT.md currently records the *absence* of strict mode in libraries as the concern. The live defect is the inverse. Correct the register after implementation.

### A3. CRITICAL — Transaction rollback can restore wrong file contents
- `lib/backup.sh:537–543`: backups keyed by `basename` only. Registering `/a/config` and `/b/config` collapses to one `config.backup`; second registration overwrites first; rollback restores one file's content into another. Reproduced by both audits — the second audit's repro ended with both files containing B's content while the framework logged "Rollback completed successfully."
- `lib/backup.sh:498`: transaction directory is `${name}_$(date +%Y%m%d_%H%M%S)` — two same-named transactions in the same second collide; the transaction primitive itself is unlocked.
- `transaction_start` interpolates an unvalidated `name` into filesystem paths and JSON metadata (path escape / metadata corruption).
- **Fix:** restrictive identifier grammar for names (reject separators, quotes, `.`/`..`); exclusive directory creation via `mktemp -d`; collision-resistant backup IDs or path-preserving encoded layout; reject or make idempotent duplicate registrations; write metadata via a safe encoder, never string interpolation; rollback verifies content hashes against recorded pre-state. Test matrix: same-basename files, concurrent same-name transactions, new files, missing files, permission failure, partial restore failure — all must restore byte-identical hashes or fail loudly.

### A4. MEDIUM→HIGH — Path containment accepts sibling-prefix paths
- `lib/validation.sh` (~:153/167): raw prefix comparison, so `/tmp/base2/file` passes containment for base `/tmp/base`.
- **Fix:** `[[ "$abs_path" == "$abs_base" || "$abs_path" == "$abs_base/"* ]]` with symlink canonicalization before comparison for any destructive operation. Both audits also agree these validators currently have **zero production callers** — wiring them into destructive entry points is part of the fix, not optional.

### A5. STRATEGIC CONSENSUS
- Architecture verdict: shell-native is correct; harden incrementally; rewrite rejected (one-way door, doesn't solve sourced-shell ergonomics).
- Roadmap verdict: transactional mutation remains the right centerpiece, but the primitive must be hardened (A3) before any adoption expands.
- Test hygiene: many test files rely on accidental strict-mode leakage or end in unconditional `exit 0` / last-command status; every test must either use its own strict mode with guarded expected-failures, or accumulate failures through an explicit summary.

---

## SECTION B — SINGLE-SOURCE FINDINGS (found by one audit only; independently reproduce before fixing, then treat as in-scope)

Reproduction is bounded by **scope, not elapsed time**: perform the minimum independent reproduction necessary to establish or falsify the finding as described. Trust-boundary and privilege findings may legitimately take longer than trivial ones — that is acceptable. **Privilege-boundary reproductions must use mocks/shims (e.g., a fake `sudo` on PATH that records its argv and grants nothing) and must never exercise real elevation.** If a finding cannot be reproduced as described, apply Rule 8: record the negative repro and escalate; do not drop or downgrade it.

### B1. From Audit 2 only — highest priority of this section

1. **CRITICAL — Plugin path traversal.** `plugin_install` (plugins.sh:~300) and `plugin_remove` (:~325) accept unvalidated `target_name`/`plugin_name`; `../escaped.sh` was written outside `PLUGIN_ENABLED_DIR` and `plugin_remove "../escaped"` deleted it. Constrain identifiers to strict basename grammar, canonicalize parents, enforce A4-style containment, reject symlink escapes, route install/remove through transactions.
2. **CRITICAL — Auto-activation crosses trust and privilege boundaries.** `lib/auto-activate.sh`: `chpwd` sources repo-controlled `.venv/bin/activate` (:57, :375), auto-installs missing Node versions (:415), and an opt-in hook runs `ln -sf` / passwordless `sudo -n ln -sf` into `/usr/local/bin` (:229). This is code execution triggered by `cd`, bypasses the plan/confirm/backup lifecycle, and silently reintroduces the P0-6 privileged-symlink problem via a new path. Directory hooks may only *switch between already-installed versions*; installation, repo-script sourcing, and privileged symlink sync become separate explicit commands gated by a persistent trust registry.
3. **HIGH — `validate_safe_path` is broken by construction.** The NUL check (validation.sh:~127) rejects every ordinary path because Bash strings cannot contain NUL — the validator cannot be adopted as-is. Redesign: separate lexical validation from containment; security validators fail closed; destructive APIs accept only validated path objects.
4. **HIGH — Second false-green mechanism: syntax gate.** `Makefile:~106` uses `find -exec bash -n ... -print`; `find` returns 0 despite parse failures (seeded-invalid-file repro). Also: syntax checking is Bash-only while three shipped Zsh themes (`apple-style-p10k.zsh:78`, `minimal-p10k.zsh:71`, `rainbow-p10k.zsh:105`) fail `zsh -n` yet sit in the active catalog; the installer only accepts `professional`; `theme_get_description` indexes a numeric array with a string. Add `zsh -n` to the syntax gate; fix or delist the three themes; fix catalog drift.
5. **HIGH — `((counter++))` is systemic**, not test-local: release, recovery, diagnostics, setup wizard, fonts, symlinks, cache, themes, metrics. Sweep repo-wide to `counter=$((counter + 1))` (or explicit status handling) and test each affected control path. Do NOT treat A2's leakage removal as sufficient — executables with legitimate strict mode still hit this.
6. **HIGH — Mutation inventory incomplete.** ROADMAP 3.3 lists 5 targets; static sink inspection found at least 9 more: `lib/auto-activate.sh`, `lib/plugins.sh`, `version-manager.sh`, `tools/version-diagnostic-enhanced.sh`, `scripts/theme-icon-manager.sh`, `scripts/fix-terminal-issues.sh`, `setup-slick-terminal.sh`, `lib/pyvm.sh`, `scripts/generate-vscode-settings.sh`. Build a complete mutation-target registry before claiming any adoption percentage.
7. **MEDIUM — Quality gate tolerates failure.** `tools/validate-quality.sh:26,34` accepts up to 49 ShellCheck output lines as passing — contradicts gating policy; reopens P1-7 in substance. Set tolerance to zero (with explicit, per-rule suppressions only).
8. **MEDIUM — Supply chain in generated artifacts.** `version-advanced.sh:164,417` emits workflows with floating action tags (violates the repo's own SHA-pin policy); `lib/rustup.sh:77` executes network content after size+shebang checks only; `curl | bash` guidance emitted at `system-diagnostics.sh:504` and documented in `PLUGINS.md:77`; generated CI builds a 32-combination matrix running both `npm ci` and `pip install` unconditionally.
9. **MEDIUM — Misc.** `fonts.sh:104` emits `0\n0` on no-match causing arithmetic errors; `generate-vscode-settings.sh:99,235` does unescaped JSON substitution and overwrites before validation; `test_runner.sh:64` mutates repo file modes via `chmod +x`; `health-check.sh:17` lacks strict mode and uses dynamic `eval`; Bash 3.2 vs 4+ contract (mapfile/associative arrays) is undefined — either bootstrap Bash 4+ formally or remove the constructs.

### B2. From Audit 1 only

1. **HIGH — `.zshrc` mutation drift (P1-3, open).** `scripts/fix-nvm-issues.sh:50–51, 73–92, 109–135` does bare appends: no transaction, no atomic replace, no dry-run, no managed BEGIN/END block, conflicting `NVM_SILENT=1` vs `NVM_SILENT=true`, three independently drifting fragments; `setup-versions.sh:413–437` appends a fourth. Zero occurrences of the mandated `# BEGIN/END version-management-setup:<n>` markers repo-wide. Implement ONE atomic managed-block editor and ONE canonical NVM block; repeated runs must be byte-identical. Tests: first install, identical rerun, block update, coexistence with unmanaged user config, write-failure rollback, symlinked rc files.
2. **HIGH — `make clean` deletes unrelated `/tmp` data.** `Makefile:118` runs `rm -rf /tmp/test_*` — unscoped to project or user. Replace with a validated, project-owned root (`${TMPDIR}/version-management-setup/`); no global wildcards.
3. **MEDIUM — Release workflow omits gates.** Release runs version/syntax/ShellCheck/`make test` but not gitleaks, pre-commit, the macOS matrix, or coverage; a directly pushed tag bypasses them. Either run the full check set release-locally or verify an immutable successful CI run for the exact release SHA.
4. **MEDIUM — Logger contaminates stdout return values.** `theme_detect_current` emits `[WARN]` into command substitution alongside the machine value. Contract: logs → stderr; value-returning functions own a clean stdout.
5. **MEDIUM — Hollow integration tests.** `tests/integration/test_setup.sh` asserts only symbol existence, then `exit 0` (:24–27); no dispatch, clean-HOME, rollback, rerun, dry-run, cancellation, or permission-failure coverage.
6. **LOW — Standing debt (accepted, later phases):** duplicated platform APIs (`get_os`/`detect_os`/`get_shell`, WSL drift), pseudo-coverage (`.coverage` intent-tracking; 266%/120% outputs observed), single-stage root Docker templates without HEALTHCHECK, no dependency lockfile, duplicated NVM version pin, no log rotation, no plugin conformance tests, missing ADR/security/ops docs, incomplete consolidated font attribution, dead sync stub in `version-advanced.sh`, no workstation mutation audit journal.

---

## SECTION C — DISAGREEMENTS AND DISCREPANCIES (resolve; do not paper over)

1. **Failing test count: 4 vs 2.** Audit 1's sandboxed runner: `test_phpenv`, `test_rustup`, `test_theme_ops`, `test_cross_platform` fail. Audit 2's "canonical filtered runner": only `test_theme_ops`, `test_cross_platform`. Likely cause: differing runner invocation/environment plus the fact that `test_phpenv`/`test_rustup` failures are strict-mode-leakage artifacts (A2). **Resolution mechanism:** Milestone 0's canonical manifest — `make test`, CI, and the direct runner must emit identical normalized manifests on Linux and macOS. Do not hand-reconcile beforehand; make the harness incapable of disagreeing with itself. Expect `test_phpenv`/`test_rustup` to flip green once made self-contained (M0 step 3), which also empirically settles the 4-vs-2 question.
2. **Blast-radius framing of the strict-mode fix.** Audit 1 implies fixing A2 clears the arithmetic failures; Audit 2 shows `((x++))` also lives in executables with *legitimate* strict mode (B1.5). Adopt Audit 2's wider scope: A2 removal AND a repo-wide arithmetic sweep are both required.
3. **Validator status.** Audit 1: validators are weak and uncalled. Audit 2: one validator (`validate_safe_path`) is unusable by construction. Adopt Audit 2's stronger claim — plan for redesign, not just wiring-in.
4. **Coverage of trust boundaries.** Audit 1 has no equivalent of B1.1 (plugin traversal) or B1.2 (auto-activation) despite reviewing the same files. These are not "disputed" — they are single-witness Criticals with sandbox repros. Verify then fix; do not deprioritize because only one audit saw them.
5. **Audit 2 caveat:** its planned Kimi K3 subagent validation layer never executed (provider 429s), so all its findings are single-reviewer. Its critical claims each carry a repro, so confidence remains high — but this is why every B-section item gets a quick independent repro before work begins.
6. **Milestone shape.** Audit 1: 6 milestones ending in delivery hardening. Audit 2: 5 phases inserting trust-boundary repair before runtime correctness. Merged order below is binding.

---

## SECTION D — BINDING EXECUTION ORDER

Work strictly in order. Each milestone ends with an explicit GO/NO-GO evaluated against its listed evidence. NO-GO ⇒ stop, report, do not start the next milestone.

**M0 — Test truth (release frozen throughout).**
**Session 1 is scoped to steps 1–2 only.** Complete them, produce the session report per REPORTING FORMAT, and stop. Do not begin step 3 (modifying failing test files) until the session-1 report has been reviewed and continuation is explicitly authorized. M0 is not "make everything green" — it is four separate jobs: establish trustworthy measurement, repair false-green gates, make tests self-contained, and prove every gate fails under seeded attack. The GO condition requires all four.
1. Define the **canonical test manifest**: every runner entry point emits one machine-readable record per test file — `test_id`, `platform`, `status`, `exit_code`, `duration` — to a well-known path. Make, CI, and direct invocation all produce it; gate parity is a comparison of normalized manifests, never console output.
2. Route all test targets through `tests/test_runner.sh`; fix the `find -exec` syntax gate; add `zsh -n` for shipped Zsh assets; zero-tolerance ShellCheck gate in `validate-quality.sh`; remove unconditional `exit 0`s.
3. Repair the four failing test files **by making each test self-contained** — its own strict-mode posture, guarded expected-false returns (`if phpenv_detect; then ...; fi` patterns), explicit failure accumulation. Note the ordering constraint: `test_phpenv` and `test_rustup` currently fail *because of* the A2 library leakage that M1 removes. Do NOT fix them by touching the libraries (that is M1 work); fix them so they pass regardless of library strict-mode behavior. If a test cannot be made independent of A2, document it and defer that single test's green state to M1 exit — do not pull M1 forward.
4. Seeded-failure meta-tests for every gate: failing test file in a non-final position, invalid Bash file, invalid Zsh file, ShellCheck finding, and a **deliberately mismatched manifest** (proving the comparator itself can fail — an always-equal comparator is a new false-green vector).
5. Run on Linux + macOS.
GO: every seeded failure turns Make, CI, and release jobs red; normalized manifests identical across Make/CI/direct runner on both platforms. NO-GO: any manifest discrepancy, or any seeded failure that stays green.

**M1 — Library and runtime contracts.**
Strip strict mode from the four libraries; `$-` preservation contract test per module under strict and non-strict callers; repo-wide `((x++))` sweep with per-path tests; logs to stderr with clean stdout contracts for value-returning functions; fix `fonts.sh` `0\n0`; define and enforce the Bash version contract.
GO: sourcing any library leaves caller flags unchanged; no module depends on leaked strict mode; arithmetic sweep verified on affected control paths.

**M2 — Transaction primitive hardening + mutation registry.**
Everything in A3, plus the complete mutation-target registry (ROADMAP 3.3's five + B1.6's nine + any further sinks found by static inspection). Symlink semantics defined. Audit-journal metadata recorded per operation.
GO: same-basename, concurrent, and failure-injection rollback tests restore byte-identical hashes; concurrency isolation asserted from the filesystem (concurrent same-named transactions observed using distinct directories and backup namespaces — not inferred from test exit codes); dry-run produces zero writes; registry published in governance docs. NO-GO: any rollback can target an ambiguous file, or any observed directory/namespace sharing.

**M3 — Trust-boundary repair.**
Plugin identifier grammar + containment + symlink rejection; redesigned fail-closed validators wired into every destructive entry point; auto-activation split (passive version switching only; installs, repo-script sourcing, and privileged symlinks behind explicit plan/confirm commands + persistent trust registry).
All privileged-path tests (the `sudo -n ln -sf` behavior, `/usr/local/bin` writes) run against a mock `sudo` shim placed first on PATH that records invocations and performs no real elevation — never against actual privilege. The assertion target is the recorded argv and the code path taken, not a real system mutation.
GO: traversal, symlink-escape, untrusted-repository, and passwordless-sudo tests all fail closed, with the sudo-path assertions made against shim-recorded invocations.

**M4 — Managed mutation adoption.**
Atomic managed-block editor with canonical NVM block (B2.1) first, then migrate the full registry in risk order: `fix-nvm-issues.sh` → `setup-versions.sh` → `fix-terminal-issues.sh` → `update-global-node-symlinks.sh` → `setup-fonts-enhanced.sh` → `emergency-recovery.sh` → remaining registry entries. Canary: one script per iteration; sandbox acceptance before the next adopter. Each adopter supports plan/dry-run, explicit apply, backup ID, apply verification, automatic rollback, idempotent rerun, audit-journal record.
GO per adopter: rerun is byte-identical; injected failure rolls back byte-identically.

**M5 — Validation, portability, delivery.**
Scoped `make clean` root; clean-HOME / no-network / permission-denied / symlink scenarios; consolidated platform API + WSL contract test; gitleaks + pre-commit in the release path (or verified CI attestation per release SHA); SHA-pin generated workflows; checksum/signature-verified remote installers; remove pipe-to-shell guidance from tools and docs; SBOM, artifact signatures, provenance; lockfile decision; font attribution; ADR/security/ops docs.

**Safety SLIs (program-level, report at every milestone exit):**
- 100% of registry mutations flow through the framework (measurable only after M2's registry).
- 100% byte-for-byte rollback under injected failures.
- 0 writes during dry-run; 0 diff on idempotent rerun.
- 0 release-gate false positives under seeded failures.
- Every mutation records target, mode, backup ID, result, exit code.

**Governance updates (do before M0 implementation):** add findings register entries for the consensus items (A1–A4) and verified B-section Criticals; correct the MASTER_AUDIT strict-mode inversion (A2); insert M0–M3 ahead of existing ROADMAP Phase 3; mark Phase 3 BLOCKED-ON-M2.

## REPORTING FORMAT

After each work session, report: findings closed (ID → fix location → proving test → red/green evidence citing ledger records per Rule 10), findings opened (anything new discovered while fixing), any reclassifications with recorded rationale (per Rule 8), gate status per milestone, the pre/post session snapshot hashes (per Rule 9) with parity confirmation, the closing ledger hash, and any assumption you proceeded under where a different answer would change the plan. If you determine any finding in Section A or B is not reproducible as described, stop, document the negative repro in the ledger, and escalate rather than silently dropping it.

## DOCTRINE

Do not optimize for "all tests green." Optimize for "the system demonstrably fails closed when deliberately attacked." Every milestone exit is a claim that a specific class of attack now fails safely — and every such claim must be backed by having watched the attack fail.
