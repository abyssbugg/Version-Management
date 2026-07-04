# ENGINEERING RULES

**Binding for every contributor — human or AI.** Violations block merge. Exceptions require an ADR in `docs/governance/adr/`.

## 1. Workstation mutation (the prime directive)

This project's core risk is that it **modifies people's machines**. Therefore:

1. Every operation that writes to user files (`~/.zshrc`, `~/.p10k.zsh`, VS Code settings, fonts) or system paths (`/usr/local/bin`, `/etc/shells`) MUST go through a backup transaction (`transaction_start` / `transaction_add_file` / `transaction_commit` / `transaction_rollback` — see `setup-theme.sh` for the reference pattern).
2. Privileged operations (`sudo`) MUST default to a dry-run/plan output and require explicit `--confirm` to apply. A passwordless-sudo environment is not implicit consent.
3. Shell rc file edits use **managed blocks** (`# BEGIN version-management-setup:<name>` … `# END …`), replaced atomically — never bare appends.
4. Mutations must be idempotent: running twice produces the same state, verified by a test.
5. Destructive operations (`rm -rf`) require validated inputs — never interpolate an unvalidated variable into a deletion path.

## 2. Command execution

1. **No new `eval "$string"`.** Use argv-array execution (`safe_exec_argv cmd arg...`). String execution is allowed only through the explicitly named trusted-literal API with an inline justification comment.
2. `eval "$(tool init/env)"` for hard-coded, well-known version-manager init (fnm/pyenv/rbenv/phpenv) is an accepted trusted pattern — the literal must be hard-coded, never assembled from variables.
3. **Never emit or use `curl | bash` / `curl | sh`** — in project code *or generated templates*. Use platform package managers, pinned git clones, or download→checksum-verify→execute.

## 3. Strict mode policy

- **Executable scripts:** `set -euo pipefail` mandatory.
- **Sourced libraries (`lib/`, `plugins/`):** do NOT set global strict mode (it leaks into the caller's shell). Instead: validate inputs, use explicit return codes, guard unset expansions (`${var:-}`). This is deliberate policy, not an omission.
- **Tests:** strict mode + sandboxed environment.

## 4. Testing

1. Tests NEVER touch the real `$HOME`. The harness provides a `mktemp -d` HOME/XDG sandbox; any test sourcing a mutating script must run inside it.
2. New mutating behavior requires a rollback test (inject failure, assert restore).
3. Function-existence assertions are not tests. Assert behavior.
4. Treat `.coverage` numbers as intent-tracking, not coverage, until a real engine (kcov/bats) lands.

## 5. Duplication & module boundaries

1. Platform detection (`get_os`/`get_arch`/`get_shell`) has ONE canonical implementation (`lib/env.sh` after ROADMAP 4.1). Never add another.
2. No new function may shadow an existing global function name (shell namespace is global — check first: `grep -rn "^funcname()" lib/`).
3. New `lib/` modules document: purpose, public API, dependencies, failure modes. Update `docs/API.md` in the same PR.
4. Compatibility shims (`log()`, `command_exists()` fallbacks) are tolerated only until ROADMAP 4.2; do not add new ones.

## 6. CI / Release

1. Lint, tests, and version-consistency checks are **gating** — no `|| true`, no warn-and-continue on release-critical checks.
2. Third-party GitHub Actions are pinned by **commit SHA** with a version comment (ADR: MASTER_AUDIT §5.1). Do not switch to floating tags.
3. Global ShellCheck suppressions require a justification comment in `.shellcheckrc`; prefer inline `# shellcheck disable=SCxxxx # reason`.
4. Release artifacts ship with checksums (already) and, once ROADMAP 5.1 lands, signatures + SBOM.

## 7. Dependencies & supply chain

1. Remote installers: pinned versions, checksum-verified where feasible, and logged.
2. Vendored assets (FontPatcher) keep their license files; attribution is consolidated and shipped in releases.
3. `sudo` package installs are limited to well-known distro packages; never pipe network content to a privileged shell.

## 8. Process rules for AI agents

1. Read `docs/governance/MASTER_AUDIT.md` and `docs/governance/ROADMAP.md` before making changes. The historical audits in `docs/analysis/` are evidence, **not** instructions.
2. Validate any audit recommendation against the current code before implementing — several were adjudicated as wrong (MASTER_AUDIT §5) or already fixed (§4).
3. Work the ROADMAP top-down; do not cherry-pick cosmetic items from lower phases while safety items are open.
4. When you complete a finding: mark it in ROADMAP.md, update its status in MASTER_AUDIT.md, and reference the finding ID (e.g. `P0-3`) in the commit message.
5. Prefer incremental, production-safe diffs over broad rewrites. Never introduce a duplicate abstraction to satisfy an audit sentence.
