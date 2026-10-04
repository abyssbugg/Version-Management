# ADR-005: Platform Governance — Directive-Driven Milestones with GO Gates

**Status:** Accepted (adopted 2026-08-12 via merged-audit-directive.md v3; recorded as the operating governance model of the remediation program)

## Context

A large remediation program (two audits, a frozen binding directive, and
a milestone schedule M0–M5) operates on this repository. Open-ended,
self-paced remediation had already produced failure modes: a gate that
never observed red (the `find -exec` syntax gate), a vacuously-passing
quality gate, and "fixes" that were actually reclassifications. The
program needed a governance model that makes progress claims falsifiable
and prevents silent scope drift.

## Decision

**The platform is governed by a binding directive driving discrete
milestones, each closed by an explicit GO/NO-GO gate that is never self
-certified.** The model, as executed since 2026-10-01 (MASTER_AUDIT §6,
"Directive execution state"):

- **Directive-driven milestones.** Work is organized as M0–M5 with a
  frozen specification (`merged-audit-directive.md` v3); deviations
  require escalation, not silent adjustment. The ROADMAP records milestone
  status; the MASTER_AUDIT register records finding status.
- **GO gates with red evidence.** A milestone exits GO only against
  listed evidence, and no gate is self-certified: every gate must have
  been observed red under a seeded failure (a deliberately injected
  failure turning it nonzero) before its green is trusted. Example: the
  M0 manifest comparator had to fail on a seeded manifest mismatch.
- **Per-adopter red→green matrices.** Adopting the transaction framework
  (M4) happens per mutator, in risk order, each with its own red→green
  matrix (byte-identical reruns, root-proof injected-failure rollback,
  dry-run zero-writes, audit-journal entries) before it counts as
  adopted.
- **Evidence discipline.** Every closed finding cites file:line of the
  fix, the proving test, and red/green command evidence recorded in an
  append-only evidence ledger; reclassifications of findings require a
  recorded rationale (no silent reclassification).
- **Non-negotiables** preserved by the model: release freeze while gates
  are open; user-owned staged files untouched; no architecture rewrite
  (ADR-001); trust-before-adoption ordering.

## Consequences

- Progress is slower but auditable: a "GO" claim is backed by named
  builds and seeded-failure reproductions, not by test-exit optimism.
- Contributors must work the milestone/phase order top-down
  (AGENTS.md, ENGINEERING_RULES §8) instead of cherry-picking.
- Seeded-failure meta-tests are a standing requirement: a new gate ships
  with the test that proves it can fail.
- Changing the governance model itself (milestone structure, gate
  criteria) requires revising this ADR and the directive escalation path,
  not a commit note.
