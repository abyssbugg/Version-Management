# ADR-001: Keep Shell, Add Guardrails

**Status:** Accepted (adjudicated 2026-07-04, MASTER_AUDIT §5.5; reinforced by remediation-directive rule 3, 2026-08-12)

## Context

Two independent audits (2026-07-04) evaluated this repository — a Bash
suite that mutates developer workstations — and reached different
conclusions about its posture. One option on the table was a full rewrite
of the suite in a compiled or typed language (Go/Rust/Python); a hybrid
"Option C" (a small compiled helper for planning/JSON/locking/checksums
with shell as the UX layer) was also proposed. The rewrite argument
cited the classic shell hazards: string-`eval` injection, untyped
filesystem mutation, and weak tooling.

## Decision

**Keep the implementation in shell and add guardrails** (GPT-5.5's
trade-off analysis, adopted as binding):

- A full rewrite is rejected: it would lose shell-native sourcing
  ergonomics (these libraries are consumed by user shells and by each
  other at source time) and would duplicate version-manager behavior
  anyway.
- Incremental hardening is the path: the transactional mutation
  framework, managed-block rc editing, argv-array execution, fail-closed
  validators, and the Bash >= 4.0 contract are the guardrails (see
  ENGINEERING_RULES.md).
- The compiled-helper hybrid (Option C) is **deferred** to P3-5 and is
  revisited only after P0–P2 and the transaction framework (Phase 3)
  land.

## Consequences

- Every contributor must treat the shell constraints as load-bearing:
  sourced libraries must not set global strict mode, `eval` is
  restricted per ADR-002, and mutation goes through the transaction
  primitive.
- The test harness requires Bash >= 4.0 and enforces it with a clear
  failure (ENGINEERING_RULES §3.1); macOS's default `/bin/bash` 3.2 is
  not sufficient.
- Shell-specific fragility is paid down with contract tests (library
  `$-` preservation, injection regression, syntax gates) rather than by
  switching languages.
- Reopening the rewrite question requires a new ADR (MASTER_AUDIT §5:
  "These are binding decisions. Reversing one requires a new ADR.").
