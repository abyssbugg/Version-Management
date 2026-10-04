# ADR-002: argv Arrays, Not `bash -c`, for Command Execution

**Status:** Accepted (adjudicated 2026-07-04, MASTER_AUDIT §5.2)

## Context

Finding P0-4 identified string-command `eval` in shared APIs
(`safe_exec`/`safe_exec_backoff`, `cache_safe_execute`, `cache_version`)
as an injection surface. One audit (GLM-5.2) recommended replacing
`eval "$command"` with `bash -c "$command"` as the remediation. The other
audit (GPT-5.5) observed that this does not remove the risk.

## Decision

`bash -c "$command"` is **rejected**: the injection surface is the
dynamic command *string*, not the evaluator — `bash -c` parses and
executes the same string with the same metacharacter semantics. The
adopted design (GPT-5.5's approach, implemented in `lib/error-handling.sh`):

- `safe_exec_argv cmd arg...` — execution from argv arrays; no
  intermediate string is ever parsed by a shell.
- `safe_exec_shell_trusted "literal"` — the explicitly named escape hatch
  for hard-coded, trusted-literal strings, requiring an inline
  justification comment at every call site (ENGINEERING_RULES §2.1).
- The string forms are deprecated and warn on use.
- The one accepted trusted pattern is `eval "$(tool init/env)"` for
  hard-coded, well-known version-manager init (fnm/pyenv/rbenv/phpenv) —
  the literal must be hard-coded, never assembled from variables
  (ENGINEERING_RULES §2.2).

## Consequences

- New code must use argv execution; a new string-`eval` blocks merge
  (ENGINEERING_RULES §2.1).
- Injection-regression tests cover spaces, `;`, backticks, `$()`, and
  globs through the public APIs.
- Callers that genuinely need shell features must either restructure into
  argv form or move to the trusted-literal API with justification — both
  are visible in review.
