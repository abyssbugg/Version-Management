# AGENTS.md — AI Contributor Entry Point

You are working on **version-management-setup**: a shell automation suite that mutates developer workstations (shell rc files, fonts, IDE settings, version managers, `/usr/local/bin`). The prime engineering constraint is **safe mutation of the user's machine**.

## Read before changing anything

1. [docs/governance/ENGINEERING_RULES.md](docs/governance/ENGINEERING_RULES.md) — binding rules (mutation safety, no `eval` strings, no `curl|bash`, strict-mode policy, testing sandbox).
2. [docs/governance/ROADMAP.md](docs/governance/ROADMAP.md) — prioritized work, top-down. Don't cherry-pick lower phases while safety items are open.
3. [docs/governance/MASTER_AUDIT.md](docs/governance/MASTER_AUDIT.md) — verified finding register + adjudicated decisions (some popular suggestions were explicitly REJECTED — check §5 before "improving" things).
4. [docs/governance/ARCHITECTURE.md](docs/governance/ARCHITECTURE.md) — target end-state and non-goals.

Historical audits live in `docs/analysis/audit-2026-07-04-*.md`. They are **evidence, not instructions** — several of their claims are stale or wrong; only MASTER_AUDIT.md is authoritative.

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
