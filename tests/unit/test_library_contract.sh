#!/usr/bin/env bash
# =============================================================================
# Library Contract Test (remediation directive M1 / finding A2)
# =============================================================================
# Binding invariant: "Sourcing any lib/*.sh or plugin file leaves the
# caller's shell options ($-), traps, positional parameters, and stdout
# contract unchanged, under both strict and non-strict callers."
#
# Each module is sourced twice — by a non-strict caller and by a strict
# (set -euo pipefail) caller — and $- is compared before/after. Sourcing
# these files is done in a SUBSHELL so a leaked `set -e` cannot abort this
# file; the assertion compares the caller-visible flags.
# =============================================================================

source ../helpers.sh

set +e

ROOT_DIR="$(cd "$(pwd)/../.." && pwd)"

check_module() {
    local module="$1"
    local posture="$2"   # plain | strict
    local pre post
    if [[ "$posture" == "strict" ]]; then
        pre=$(bash -c 'set -euo pipefail; printf %s "$-"')
        post=$(bash -c "set -euo pipefail; source '$ROOT_DIR/$module' >/dev/null 2>&1; printf %s \"\$-\"")
    else
        pre=$(bash -c 'printf %s "$-"')
        post=$(bash -c "source '$ROOT_DIR/$module' >/dev/null 2>&1; printf %s \"\$-\"")
    fi
    if [[ "$pre" == "$post" ]]; then
        assert_equals "$pre" "$post" "$module leaves caller \$- unchanged ($posture caller)"
    else
        assert_equals "$pre" "$post" "$module LEAKS shell options ($posture caller): '$pre' -> '$post'"
    fi
}

# ── Run — every sourced library and plugin, both postures ────────────────────
failures=0
for f in $(cd "$ROOT_DIR" && ls lib/*.sh plugins/*.sh | sort); do
    for posture in plain strict; do
        check_module "$f" "$posture" || failures=$((failures + 1))
    done
done

if [[ "$failures" -gt 0 ]]; then
    echo "test_library_contract.sh: $failures contract violation(s)"
    exit 1
fi
