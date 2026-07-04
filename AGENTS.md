# AGENTS.md — AI Contributor Entry Point

You are working on **version-management-setup**: a shell automation suite that mutates developer workstations (shell rc files, fonts, IDE settings, version managers, `/usr/local/bin`). The prime engineering constraint is **safe mutation of the user's machine**.

## Read before changing anything

1. [docs/governance/ENGINEERING_RULES.md](docs/governance/ENGINEERING_RULES.md) — binding rules (mutation safety, no `eval` strings, no `curl|bash`, strict-mode policy, testing sandbox).
2. [docs/governance/ROADMAP.md](docs/governance/ROADMAP.md) — prioritized work, top-down. Don't cherry-pick lower phases while safety items are open.
3. [docs/governance/MASTER_AUDIT.md](docs/governance/MASTER_AUDIT.md) — verified finding register + adjudicated decisions (some popular suggestions were explicitly REJECTED — check §5 before "improving" things).
4. [docs/governance/ARCHITECTURE.md](docs/governance/ARCHITECTURE.md) — target end-state and non-goals.

Everything in `docs/analysis/` and `docs/plans/` is **historical evidence, not instructions** — all files there carry SUPERSEDED banners. Several of their claims are stale or wrong; only the governance documents above are authoritative.

## Working loop (every task)

1. Classify the request: which ROADMAP phase/item does it belong to? If it belongs to a lower phase while higher-phase safety items are open, say so instead of doing it.
2. Check MASTER_AUDIT §4 (already fixed) and §5 (rejected approaches) before implementing anything audit-derived.
3. State your plan — affected files, blast radius, which ENGINEERING_RULES apply — before writing code.
4. Implement incrementally; every mutation path keeps dry-run, backup/rollback, and idempotency.
5. Verify with evidence: run `make lint` and the relevant tests in a sandboxed `HOME`; show output, don't claim.
6. Close the loop: tick the ROADMAP item, update the finding status in MASTER_AUDIT, cite the finding ID (e.g. `P0-3`) in the commit message.

## Hard rules (summary — full text in ENGINEERING_RULES.md)

- Never touch the real `$HOME` in tests — sandbox with `mktemp -d`.
- Every user/system file mutation goes through a backup transaction; rc-file edits use managed `# BEGIN/END version-management-setup:<name>` blocks.
- No new `eval "$string"`; no `curl | bash` anywhere, including generated templates.
- Executables: `set -euo pipefail`. Sourced libraries: deliberately NO global strict mode.
- Platform detection: one canonical implementation — never add another `get_os()`.
- GitHub Actions stay SHA-pinned with a version comment.
- Reference finding IDs (e.g. `P0-3`) in commit messages; update ROADMAP/MASTER_AUDIT status when you complete one.

## Build & test

```sh
make lint          # ShellCheck
make syntax-check
make test-unit
make test-integration   # WARNING: until ROADMAP 1.1 lands, this can mutate the real ~/.zshrc — run only in a sandboxed HOME
```
