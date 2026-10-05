#!/usr/bin/env bash
# =============================================================================
# Plugin Conformance Tests (MASTER_AUDIT P3-4; ROADMAP Phase 4 item 4.5)
# =============================================================================
# For every bundled plugin (plugins/*.sh), assert the contract that
# lib/plugins.sh's dispatcher and docs/PLUGINS.md "Required Functions" impose
# on plugin authors. The contract is DERIVED, not invented:
#
#   C1. Source contract (directive M1 / finding A2 pattern, reused from
#       tests/unit/test_library_contract.sh): the plugin parses (bash -n) and
#       sources cleanly (rc 0) without changing the caller's shell options
#       ($-), under both a plain and a strict (set -euo pipefail) caller.
#   C2. Required interface (lib/plugins.sh "Plugin Interface Definition"
#       lines 58-74 + docs/PLUGINS.md §Required Functions; plugin_load
#       hard-requires plugin_info at load time, lib/plugins.sh:123-126):
#           plugin_info plugin_init plugin_detect plugin_install
#           plugin_version plugin_list plugin_use
#       plugin_cleanup / plugin_update / plugin_uninstall are declared
#       optional by the same block and are reported, never asserted.
#   C3. Dispatch contract (plugin_run / plugin_has_capability compose
#       "<plugin_name>_<capability>", lib/plugins.sh:290-313; the standard
#       interface aliases delegate, e.g. plugin_info() { asdf_info; }):
#           - every required op also has a <name>_<op> delegate function;
#           - every function the plugin defines is namespaced: plugin_*
#             (standard aliases) or <name>_* (dispatcher-composable).
#
# Runner pattern (matches the suite convention): set +e + failure
# accumulation, so one run reports every violation; exit 1 iff any check
# failed. This file performs no mutations — it reads plugin files and sources
# them inside throwaway bash subshells only.
# =============================================================================

source ../helpers.sh

set +e

ROOT_DIR="$(cd "$(pwd)/../.." && pwd)"

REQUIRED_OPS=(info init detect install version list use)
OPTIONAL_OPS=(cleanup update uninstall)

failures=0

# Accumulate a check result: pass through the helper's verdict and count
# failures here (the helpers themselves only report).
count_fail() {
    failures=$((failures + 1))
}

# ── C1: source contract ──────────────────────────────────────────────────────
check_source_contract() {
    local plugin="$1"
    local posture="$2"   # plain | strict
    local pre post rc=0
    if [[ "$posture" == "strict" ]]; then
        pre=$(bash -c 'set -euo pipefail; printf %s "$-"')
        post=$(bash -c "set -euo pipefail; source '$ROOT_DIR/$plugin' >/dev/null 2>&1; printf %s \"\$-\"") || rc=$?
    else
        pre=$(bash -c 'printf %s "$-"')
        post=$(bash -c "source '$ROOT_DIR/$plugin' >/dev/null 2>&1; printf %s \"\$-\"") || rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
        assert_equals "clean source (rc 0)" "source failed (rc $rc)" \
            "$plugin does NOT source cleanly ($posture caller)"
        count_fail
        return 0
    fi
    if [[ "$pre" == "$post" ]]; then
        assert_equals "$pre" "$post" "$plugin leaves caller \$- unchanged ($posture caller)"
    else
        assert_equals "$pre" "$post" "$plugin LEAKS shell options ($posture caller): '$pre' -> '$post'"
        count_fail
    fi
    return 0
}

# ── C1: parse contract ───────────────────────────────────────────────────────
check_syntax() {
    local plugin="$1"
    local err
    if err=$(bash -n "$ROOT_DIR/$plugin" 2>&1); then
        assert_equals "" "$err" "$plugin passes bash -n"
    else
        assert_equals "no syntax errors" "syntax errors: $err" "$plugin FAILS bash -n"
        count_fail
    fi
    return 0
}

# ── C2 + C3: function surface (inspected in a throwaway subshell so the
#    plugin_* aliases of one plugin cannot mask another's missing function) ──
plugin_defined_functions() {
    local plugin="$1"
    bash -c "source '$ROOT_DIR/$plugin' >/dev/null 2>&1; declare -F" | awk '{print $3}' | sort
}

check_function_surface() {
    local plugin="$1"
    local name
    name=$(basename "$plugin" .sh)
    local defined
    defined=$(plugin_defined_functions "$plugin") || {
        assert_equals "function dump" "source/dump failed" "$plugin function surface could not be inspected"
        count_fail
        return 0
    }

    local op
    for op in "${REQUIRED_OPS[@]}"; do
        # C2: required standard-interface function.
        if printf '%s\n' "$defined" | grep -qx "plugin_${op}"; then
            assert_equals "plugin_${op}" "plugin_${op}" "$plugin defines required interface: plugin_${op}"
        else
            assert_equals "plugin_${op}" "MISSING" "$plugin missing REQUIRED interface function: plugin_${op} (P3-4 contract violation)"
            count_fail
        fi
        # C3: dispatcher-composable delegate <name>_<op>.
        if printf '%s\n' "$defined" | grep -qx "${name}_${op}"; then
            assert_equals "${name}_${op}" "${name}_${op}" "$plugin defines dispatch delegate: ${name}_${op}"
        else
            assert_equals "${name}_${op}" "MISSING" "$plugin missing dispatch delegate: ${name}_${op} (plugin_run/plugin_has_capability cannot reach it)"
            count_fail
        fi
    done

    # C3: namespacing — every defined function is plugin_* or <name>_*.
    local offender=""
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if [[ "$f" == "plugin_"* || "$f" == "${name}_"* ]]; then
            :
        else
            offender+="$f"$'\n'
        fi
    done <<< "$defined"
    if [[ -z "$offender" ]]; then
        assert_equals "namespaced" "namespaced" "$plugin function namespacing conforms (plugin_* / ${name}_*)"
    else
        assert_equals "namespaced" "unnamespaced: ${offender%%$'\n'*}" \
            "$plugin defines functions outside the plugin_* / ${name}_* namespace (P3-4 namespacing violation)"
        count_fail
    fi

    # Optional interface: report presence, never assert (contract is optional).
    for op in "${OPTIONAL_OPS[@]}"; do
        if printf '%s\n' "$defined" | grep -qx "plugin_${op}"; then
            echo "INFO: $plugin defines optional plugin_${op}"
        fi
    done
    return 0
}

# ── Run — every bundled plugin ───────────────────────────────────────────────
plugin_count=0
for f in $(cd "$ROOT_DIR" && ls plugins/*.sh | sort); do
    plugin_count=$((plugin_count + 1))
    echo "--- conformance: $f ---"
    check_syntax "$f"
    check_source_contract "$f" plain
    check_source_contract "$f" strict
    check_function_surface "$f"
done

if [[ "$plugin_count" -eq 0 ]]; then
    assert_equals ">0" "0" "no bundled plugins found in plugins/ — contract vacuously true, failing closed"
    count_fail
fi

if [[ "$failures" -gt 0 ]]; then
    echo "test_plugin_conformance.sh: $failures contract violation(s) across $plugin_count plugin(s)"
    exit 1
fi
echo "test_plugin_conformance.sh: all conformance checks passed for $plugin_count plugin(s)"
