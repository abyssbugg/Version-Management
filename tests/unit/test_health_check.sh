#!/usr/bin/env bash
# =============================================================================
# RA-2 (re-audit 2026-10-10): tools/health-check.sh must never execute data.
# =============================================================================
# The tool ran every check through `eval "$2"`, and its .nvmrc check built that
# string from the file's content. Running the health check inside a cloned
# repository therefore executed code from the repository's .nvmrc.
# Contract pinned here:
#   - hostile .nvmrc content is compared, never executed (two payload shapes);
#   - a normal .nvmrc is still reported with its expected version;
#   - the tool contains no eval at all (ENGINEERING_RULES 2.1).
# =============================================================================
set -uo pipefail
source "${BASH_SOURCE[0]%/*}/../helpers.sh" || { echo "FATAL: cannot source helpers.sh — run via tests/test_runner.sh (P0-3: unsandboxed HOME writes forbidden)" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$ROOT/tools/health-check.sh"
PROJ="$(mktemp -d "${TMPDIR:-/tmp}/vms-health.XXXXXX")"
trap 'rm -rf -- "$PROJ"' EXIT
failures=0

run_in_project() {  # run the tool with the project dir as cwd; output in $PROJ/out
    (cd "$PROJ" && bash "$TOOL" </dev/null >"$PROJ/out" 2>&1) || true
}

hostile() {  # <label> <.nvmrc content>
    local label="$1" content="$2"
    rm -f "$PROJ/PWNED"
    printf '%s' "$content" > "$PROJ/.nvmrc"
    run_in_project
    if [[ -e "$PROJ/PWNED" ]]; then
        printf 'FAIL: %s — .nvmrc content was executed\n' "$label"
        failures=$((failures + 1))
    else
        printf 'PASS: %s — .nvmrc content not executed\n' "$label"
    fi
}

# The tool strips whitespace from .nvmrc, so the payloads use ${IFS}.
# shellcheck disable=SC2016 # literal payloads, expanded only if executed
hostile "command substitution" "1'\$(touch\${IFS}$PROJ/PWNED)'"
# shellcheck disable=SC2016
hostile "quote break" "1';touch\${IFS}$PROJ/PWNED;'"

printf '20.11.0\n' > "$PROJ/.nvmrc"
run_in_project
if grep -q '\.nvmrc (expects 20\.11\.0' "$PROJ/out"; then
    printf 'PASS: normal .nvmrc is reported with its expected version\n'
else
    printf 'FAIL: normal .nvmrc not reported; output:\n'; sed 's/^/    /' "$PROJ/out"
    failures=$((failures + 1))
fi

if grep -nE '(^|[^_[:alnum:]])eval([[:space:]]|$)' "$TOOL" | grep -vE '^[0-9]+:[[:space:]]*#'; then
    printf 'FAIL: tools/health-check.sh still uses eval (lines above)\n'
    failures=$((failures + 1))
else
    printf 'PASS: tools/health-check.sh uses no eval\n'
fi

printf 'health-check (RA-2): %s failure(s)\n' "$failures"
[[ "$failures" -eq 0 ]]
