# ARCHITECTURE — Current State & Target End-State

**Decision record:** Keep the shell-native architecture and harden it (Option B — see MASTER_AUDIT §5.5). No rewrite. Compiled-helper hybrid deferred.

## Current architecture (verified at `ffda468`)

Layered modular monolith in Bash/zsh:

```
UI layer            setup.sh (menu) · version-manager.sh · version-advanced.sh (CLIs)
Orchestration       setup-theme.sh · setup-versions.sh · validate-setup.sh · scripts/fix-*.sh
Library             lib/*.sh (20 modules, global-namespace functions, DAG rooted at logger.sh)
Configuration       config/ presets · version files (.nvmrc, .python-version, …)
Extension           plugins/ (asdf, rbenv) per docs/PLUGINS.md contract
Vendored            FontPatcher/ (Nerd Fonts, third-party, excluded from deep analysis)
```

Strengths to preserve: clean module DAG (no cycles), re-sourcing guards, lazy-loading of version managers (shell-startup performance is a feature), TTL cache, backup/restore + transaction primitives, git-clone (not pipe-to-shell) installers in first-party code.

Structural weaknesses driving the roadmap: global shell namespace with no public/private convention; duplicated platform detection; transaction primitives adopted by only one mutating script; string-command execution APIs; generated artifacts (CI templates, Dockerfiles) held to a lower standard than first-party code.

## Target end-state

The project is **configuration management for developer workstations** and evolves toward that model explicitly:

1. **Mutation framework as the spine.** All writes to user/system state flow through one lifecycle: `plan → show → backup transaction → apply → verify → commit/rollback`, with an audit journal (`~/.config/version-manager/audit.log`). Scripts become thin declarations of *desired state*; the framework owns safety.
2. **Trust-boundary model.** Three execution domains, each with its own rules (ENGINEERING_RULES §2): trusted hard-coded init literals; argv-array execution for parameterized commands; verified-download for anything remote. `eval "$string"` APIs are removed.
3. **Canonical platform API.** `lib/env.sh` is the sole authority for OS/arch/shell/WSL detection, guarded by contract tests. Everything else wraps it.
4. **Contracted extension points.** Plugins and lib modules declare a public API; contract tests pin those APIs; `docs/API.md` is enforced, not aspirational.
5. **Gated delivery.** Release pipeline: lint gate, version-consistency gate, sandboxed tests, real coverage signal, signed artifacts + SBOM + consolidated attribution.
6. **Generated artifacts held to first-party standards.** Emitted CI templates and Dockerfiles follow the same security rules as the project's own code.

## Explicit non-goals

- Rewrite in Go/Rust/Python (loses shell-sourcing ergonomics; duplicates version-manager behavior).
- Daemons, services, databases, horizontal scaling — this is a local CLI tool.
- Blanket strict-mode in sourced libraries (leaks into caller shells — policy in ENGINEERING_RULES §3).
- Decomposing large modules by line count alone — refactors happen along interface seams after contracts exist (ROADMAP Phase 4+).
