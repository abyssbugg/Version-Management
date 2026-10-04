# ADR-003: Keep GitHub Actions SHA-Pinned

**Status:** Accepted (adjudicated 2026-07-04, MASTER_AUDIT §5.1)

## Context

Third-party GitHub Actions in this repository's workflows are pinned by
commit SHA with a trailing version comment (for example
`actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2`).
One audit (GLM-5.2) recommended moving from SHA pins to floating version
tags (`v4`) "for maintainability"; the other (GPT-5.5) identified SHA
pinning as a supply-chain strength.

## Decision

**Keep SHA pinning for third-party actions.** Immutable-ref pinning is
supply-chain best practice for third-party actions: a tag is a mutable
ref that an attacker (or an upstream compromise) can move, silently
changing the code that runs with this repository's `contents: write`
scopes. The trailing version comment preserves human maintainability —
the intent is visible without a GitHub lookup.

This rule extends to generated workflows: CI YAML emitted by this suite
(`version-advanced.sh` templates) must also pin by SHA; the generated
-workflow pinning sweep is tracked as ROADMAP M5 work.

## Consequences

- Updating an action is a deliberate, reviewable change: bump the SHA and
  refresh the version comment (verify the new SHA against the GitHub API
  or the release page, as done in ROADMAP 1.5).
- ENGINEERING_RULES §6.2 encodes the rule: "Do not switch to floating
  tags."
- A `dependabot`-style tag bump would defeat the pin; automation that
  updates actions must update SHAs, not tags.
