# CLAUDE.md

All project guidance for AI contributors lives in [AGENTS.md](AGENTS.md). Read it first — it links the binding governance documents in `docs/governance/` (ENGINEERING_RULES, ROADMAP, MASTER_AUDIT, ARCHITECTURE).

This file is intentionally a pointer, not a copy: duplicated governance drifts, and drift in safety rules is worse than absence. Do not add rules here — add them to `docs/governance/ENGINEERING_RULES.md`.

Critical warnings that bear repeating:

- `make test-integration` can mutate the real `~/.zshrc` until ROADMAP 1.1 lands — sandbox `HOME` first.
- Sourced libraries in `lib/` deliberately lack `set -euo pipefail`. Do not "fix" this.
- Check `docs/governance/MASTER_AUDIT.md` §5 before implementing any audit suggestion — several were adjudicated as wrong.
