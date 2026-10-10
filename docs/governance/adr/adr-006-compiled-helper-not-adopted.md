# ADR-006: Compiled Helper (Option C) Not Adopted

**Status:** Accepted (2026-10-10; resolves P3-5, the revisit ADR-001 deferred)

## Context

ADR-001 kept the suite in shell and deferred a hybrid "Option C": a small
compiled helper for planning, JSON, locking, checksums and downloads, with
shell as the UX layer. It set the revisit point as "after P0–P2 and the
transaction framework (Phase 3) land". That point is reached: every P0–P2
finding in MASTER_AUDIT is fixed or resolved (P1-6 signing awaits only its
live proof at the first tagged release), and ROADMAP Phase 3 is done.

The revisit asked, for each responsibility Option C would own, whether the
shell implementation has a defect class that a shell contract test cannot
pin:

| Responsibility | Shell implementation today | Evidence |
| -------------- | -------------------------- | -------- |
| Planning (dry-run) | Transaction preview and `--dry-run` on every mutator; zero writes | `test_transaction_preview.sh`; `test_install_safety.sh` (whole-HOME zero-write, `8b57f56`) |
| JSON | `jq` optional; small payloads written with `printf` | ADR-004; `test_status_json.sh` |
| Locking | `lib/lock.sh` workstation lock | `test_lock.sh` (AX-10 subshell trap) |
| Checksums | `_txn_sha256` (`sha256sum`, else `shasum`); hash-verified rollback | A3 matrix; AX-23 (`eb18556`) |
| Downloads | Pinned versions with inline SHA-256, verified before use | rustup-init (AX-9), fonts (AX-19), gitleaks in CI (`7799fe3`) |

Every defect found in these areas was fixed in shell with a regression
test. None needed a different language.

## Decision

**Option C is not adopted.** The suite ships no compiled component.

## Consequences

- No second toolchain, no per-platform binaries to build, sign and
  release, and no extra supply-chain surface (ENGINEERING_RULES §7).
- The ADR-001 guardrails stay load-bearing: transaction primitive,
  managed blocks, argv execution (ADR-002), library strict-mode contract,
  Bash >= 4.0.
- P3-5 is closed as decided, not left open as "deferred".

**Reopen only with a new ADR, when one of these holds:**

1. A defect class recurs in one of the responsibilities above and cannot
   be pinned by a shell contract test.
2. Native Windows support is taken on (unsupported today; P2-10).
3. A feature needs structured-data processing that cannot keep `jq`
   optional (ADR-004).
