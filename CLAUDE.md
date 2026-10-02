# version-management-setup — Operating Protocol (ALWAYS LOAD)

This file defines **HOW** work gets done in this project. **`AGENTS.md`** defines **WHAT** is true: the prime constraint (safe mutation of the user's machine), the working loop, the hard engineering rules, and the binding governance documents in `docs/governance/` (ENGINEERING_RULES, ROADMAP, MASTER_AUDIT, ARCHITECTURE). **Both files are binding — read them together before acting.** Do not invent conflicting decisions.

---

## 1. Think before you act — Sequential Thinking MCP

Use the **Sequential Thinking MCP** to decompose every non-trivial task before
touching code:

1. Symptom — what is actually observed
2. Root cause — the real cause, not the surface behavior
3. Affected files and modules
4. Dependency order — what must land first
5. Fix strategy
6. Verification method

No jumping straight to a patch. If you're writing code before finishing this
breakdown, stop and restart.

## 2. Select tooling deliberately, after thinking

Before executing, state which capabilities the task needs and why:

| Capability | Use for |
|---|---|
| **Plugins** | Extended platform-specific functionality |
| **MCPs** | External data, services, specialized tool access |
| **Skills** | Domain-specific procedures and structured expertise |
| **Subagents** | Parallel work, isolated context, independent investigation |
| **Rules** | Constraints from AGENTS.md/CLAUDE.md that must be enforced |
| **Commands** | Repeatable defined operations |
| **Hooks** | Automated pre/post-step enforcement and validation |

Don't default to raw execution when a purpose-built tool exists. Don't use
tools reflexively either — justify each one.

## 3. Understand before changing

First deliverable on any unfamiliar area is **comprehension**, not a fix. Trace
the path end to end. If you can't explain how it currently works, you're not
ready to change it. This project has ~20 shell libraries in `lib/`, a dozen
mutating entry-point scripts, and a verified finding register in
**`docs/governance/MASTER_AUDIT.md`** (linked from `AGENTS.md`) — read the
relevant entries before assuming, and check §5 (REJECTED approaches) before
implementing any audit suggestion; several were adjudicated as wrong. One
deliberate design choice to know: sourced libraries in `lib/` lack
`set -euo pipefail` on purpose — do not "fix" this.

## 4. No bug-on-bug patching

Every change addresses the **actual root cause**. Never layer a fix on a prior
workaround. If a workaround is genuinely unavoidable, it must carry:

- an explicit `TEMPORARY:` marker
- the reason it was necessary
- the specific condition under which it gets removed

Undocumented workarounds are not acceptable.

## 5. Phases sequential, work parallel

**Across phases:** don't start the next phase until the previous is **verified
working** — not assumed working. ROADMAP order is binding: don't cherry-pick
lower phases while higher-phase safety items are open.

**Within a phase:** fan out. Large or wide-scope work gets distributed across
**subagents** running concurrently, each with clean isolated context and
non-overlapping file ownership.

Rules 2 and 5 combine here: subagent orchestration is a **tooling decision made
during planning**, and it's what makes phase discipline practical at this
codebase's scale.

In this mode you act as **advisor and orchestrator**:

- Decompose the phase into independent, non-overlapping units
- Dispatch one subagent per unit with a precise self-contained brief
- Keep contexts isolated so findings don't cross-contaminate
- Reconcile results yourself — never concatenate subagent output verbatim
- **Always `git status` a dead or silent agent's lane before re-dispatching.**
  Silent agent deaths leave complete-but-unreported lanes; re-dispatching
  without checking would duplicate or clobber real work.

## 6. Verification is part of the work

A change is not done until verified. State how. "Should work" is not
verification. The standing gate on this repo:

```text
make lint 0 failures · make syntax-check clean · make test-unit 0 fail
· make test-integration 0 fail (sandboxed HOME — never the real $HOME)
· CI green (pre-commit, gitleaks, shellcheck in Actions)
```

Anything unverified gets labeled unverified — never reported as done.

## 7. Report honestly

- Distinguish **confirmed** / **suspected** / **unverified**
- Cite `file:line` for factual claims about the codebase
- Never assert something is fixed, complete, or clean without evidence
- Surface contradictions and unknowns instead of smoothing them over
- **If a request has a gap or ambiguity, flag the gap.** Do not fill it with
  an assumption and proceed.

**Standing rule: mutation-touching directives get a safety review before implementation.** This project's prime constraint is safe mutation of the user's machine — rc files, fonts, VS Code settings, version managers, `/usr/local/bin`, `/etc/shells`. Every mutation path must keep dry-run, backup/rollback, and idempotency; a change that "works" but loses any of the three is not done. MASTER_AUDIT P0-3/P0-5/P0-6 are the paid-for examples.
Engineering honesty is already a rule on this project (show test output, don't
claim it; label unverified work unverified; cite finding IDs like `P0-3` in
commits and update ROADMAP/MASTER_AUDIT when an item closes). Apply the same
standard to your own reporting.

## Standard workflow

```text
1. Sequential Thinking MCP  →  decompose the problem
2. Tool selection           →  plugins / MCPs / skills / subagents /
                               rules / commands / hooks, with justification
3. Comprehension            →  read the system end to end
4. Root cause               →  identify the actual cause
5. Plan                     →  ordered by real dependency, phase-gated
6. Execute                  →  phases sequential, subagents parallel within
7. Verify                   →  full gate; nothing assumed
8. Report                   →  confirmed vs. suspected vs. unverified
```
