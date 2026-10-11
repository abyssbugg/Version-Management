#!/usr/bin/env bash
# =============================================================================
# RA-6 (re-audit 2026-10-10): tests/helpers.sh refuses the real home directory
# RA-4: the dead, eval-based mock_command/restore_command helpers are gone.
# =============================================================================
# Tests mutate $HOME. A test file started by hand from a normal shell used to
# run against the developer's real home. helpers.sh now resolves the account's
# home from the password database and refuses (exit 1) when HOME is it.
#
# Safety of this test itself: the probes below only SOURCE helpers.sh in a
# child shell with HOME set to the real home path and then print a marker.
# Sourcing defines functions and writes nothing; the guard stops the child
# before the marker. No probe runs any test body or mutation.
# =============================================================================
set -uo pipefail
source "${BASH_SOURCE[0]%/*}/../helpers.sh" || { echo "FATAL: cannot source helpers.sh — run via tests/test_runner.sh (P0-3: unsandboxed HOME writes forbidden)" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPERS="$ROOT/tests/helpers.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vms-home-guard.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
failures=0
ok() { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }

REAL_HOME=$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
[[ -n "$REAL_HOME" && "$REAL_HOME" != "$HOME" ]] || { bad "precondition: runner HOME is a sandbox distinct from $REAL_HOME"; exit 1; }

probe() {  # <HOME value> -> prints SOURCED when helpers.sh let the child continue
    (cd "$WORK" && env -i PATH="$PATH" HOME="$1" bash -c 'source "$0"; echo SOURCED' "$HELPERS" 2>"$WORK/err" </dev/null)
}

out=$(probe "$REAL_HOME") && rc=0 || rc=$?
if [[ "$rc" != 0 && "$out" != *SOURCED* ]] && grep -q 'RA-6' "$WORK/err"; then
    ok "sourcing with HOME = real home is refused (rc=$rc)"
else
    bad "sourcing with HOME = real home is refused (rc=$rc out=$out)"
fi

out=$(probe "$REAL_HOME/") && rc=0 || rc=$?
[[ "$rc" != 0 && "$out" != *SOURCED* ]] && ok "trailing-slash form of the real home is refused" \
    || bad "trailing-slash form of the real home is refused (rc=$rc)"

ln -s "$REAL_HOME" "$WORK/home-link"
out=$(probe "$WORK/home-link") && rc=0 || rc=$?
[[ "$rc" != 0 && "$out" != *SOURCED* ]] && ok "a symlink to the real home is refused" \
    || bad "a symlink to the real home is refused (rc=$rc)"

out=$(probe "") && rc=0 || rc=$?
[[ "$rc" != 0 && "$out" != *SOURCED* ]] && ok "an empty HOME is refused" \
    || bad "an empty HOME is refused (rc=$rc)"

mkdir -p "$WORK/sandbox-home"
out=$(probe "$WORK/sandbox-home") && rc=0 || rc=$?
[[ "$rc" == 0 && "$out" == SOURCED ]] && ok "a sandbox HOME sources normally" \
    || bad "a sandbox HOME sources normally (rc=$rc out=$out)"

# The runner's opt-out is a NON-exported shell variable; an inherited
# (environment) value must not disable the guard in a test child.
out=$(cd "$WORK" && env -i PATH="$PATH" HOME="$REAL_HOME" _VMS_HELPERS_CALLER=test_runner \
    bash -c 'source "$0"; echo SOURCED' "$HELPERS" 2>/dev/null </dev/null) && rc=0 || rc=$?
[[ "$rc" != 0 && "$out" != *SOURCED* ]] && ok "an inherited runner opt-out does not disable the guard" \
    || bad "an inherited runner opt-out does not disable the guard (rc=$rc)"

# Makefile per-file targets go through the sandboxing runner, never `bash tests/...`.
if grep -nE '^[[:space:]]*@?bash tests/(unit|integration)/' "$ROOT/Makefile"; then
    bad "Makefile per-file test targets run through tests/test_runner.sh"
else
    ok "Makefile per-file test targets run through tests/test_runner.sh"
fi

if grep -nE 'mock_command|restore_command|/tmp/mocks' "$HELPERS" "$ROOT/tests/shims/sudo"; then
    bad "RA-4: dead mock_command/restore_command helpers removed"
else
    ok "RA-4: dead mock_command/restore_command helpers removed"
fi

printf 'helpers home guard (RA-6/RA-4): %s failure(s)\n' "$failures"
[[ "$failures" -eq 0 ]]
