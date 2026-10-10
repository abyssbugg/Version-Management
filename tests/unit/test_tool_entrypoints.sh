#!/usr/bin/env bash
# =============================================================================
# Tool entry-point regression tests (AX-12, AX-13, AX-14)
# =============================================================================
# Binding invariants:
#   AX-12  lib/logger.sh does not freeze the caller's color globals: scripts
#          that define their own palette after sourcing it (setup-wizard,
#          system-diagnostics, analytics-report) start instead of dying with
#          "GREEN: readonly variable"; a caller that disabled colors with
#          BLUE='' keeps them disabled.
#   AX-13  log_* inherited by a child bash works (the private helpers are
#          exported), also under `set -u` with no color variables defined.
#   AX-14  Diagnostic tools complete under `set -euo pipefail`: no
#          `((x++))` abort on a zero counter, no early abort of
#          validate-setup's summary, no predictable /tmp temp paths in the
#          version diagnostic tool.
#
# Every tool runs read-only modes only, under env -i with a mktemp -d HOME,
# TMPDIR and XDG tree, PATH=/usr/bin:/bin and stdin from /dev/null.
# =============================================================================

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_SBX=$(mktemp -d "${TMPDIR:-/tmp}/vms-entrypoints.XXXXXX")
trap 'rm -rf -- "$_SBX"' EXIT
export HOME="$_SBX/home" TMPDIR="$_SBX/tmp"
mkdir -p "$HOME" "$TMPDIR"
source "$ROOT_DIR/tests/helpers.sh"

BASH_BIN="$(command -v bash)"
failures=0
chk() { assert_equals "$@" || failures=$((failures + 1)); }
chk_contains() { assert_contains "$@" || failures=$((failures + 1)); }
chk_absent() {
    local needle="$1" hay="$2" msg="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        chk "absent: $needle" "present" "$msg"
    else
        chk absent absent "$msg"
    fi
}

# _tool <home-tag> [VAR=value ...] -- <script> [args...]  -> sets OUT / RC
OUT="" RC=0
_tool() {
    local tag="$1"
    shift
    local -a envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        envs+=("$1")
        shift
    done
    shift
    local h="$_SBX/run-$tag"
    rm -rf -- "$h" && mkdir -p "$h/home" "$h/tmp"
    OUT=$(/usr/bin/env -i HOME="$h/home" TMPDIR="$h/tmp" PATH=/usr/bin:/bin LC_ALL=C \
        XDG_CONFIG_HOME="$h/home/.config" XDG_CACHE_HOME="$h/home/.cache" \
        XDG_STATE_HOME="$h/home/.local/state" XDG_DATA_HOME="$h/home/.local/share" \
        "${envs[@]}" "$BASH_BIN" "$@" </dev/null 2>&1)
    RC=$?
}

# ── AX-12 / AX-13: logger contract ──────────────────────────────────────────
test_logger_globals_and_child_bash() {
    local out
    out=$(/usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin "$BASH_BIN" -c '
        set -euo pipefail
        source "$1/lib/logger.sh"
        readonly GREEN="custom-green"
        printf "palette=%s\n" "$GREEN"
    ' _ "$ROOT_DIR" 2>&1)
    chk "palette=custom-green" "$out" "AX-12: a script may define its own palette after sourcing the logger"

    out=$(/usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin "$BASH_BIN" -c '
        set -euo pipefail
        readonly GREEN="g" RED="r" NC=""
        source "$1/lib/logger.sh"
        printf "sourced green=%s blue=%s\n" "$GREEN" "${BLUE:+set}"
    ' _ "$ROOT_DIR" 2>&1)
    chk "sourced green=g blue=set" "$out" "AX-12: sourcing the logger after a readonly partial palette keeps it and fills the rest"

    out=$(/usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin "$BASH_BIN" -c '
        BLUE="" GREEN=""
        source "$1/lib/logger.sh"
        printf "blue=[%s] green=[%s]\n" "$BLUE" "$GREEN"
    ' _ "$ROOT_DIR" 2>&1)
    chk "blue=[] green=[]" "$out" "AX-12: colors a caller disabled (BLUE='') stay disabled"

    out=$(/usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin "$BASH_BIN" -c '
        source "$1/lib/logger.sh"
        printf "palette=%s\n" "${BLUE:+set}"
    ' _ "$ROOT_DIR" 2>&1)
    chk "palette=set" "$out" "AX-12: logger still provides a palette when the caller defines none"

    out=$(/usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin "$BASH_BIN" -c '
        source "$1/lib/logger.sh"
        bash -c "set -u; log_info child-info; log_error child-error; echo child-rc=\$?"
    ' _ "$ROOT_DIR" 2>&1)
    chk_contains "[INFO] child-info" "$out" "AX-13: inherited log_info works in a child bash"
    chk_contains "[ERROR] child-error" "$out" "AX-13: inherited log_error works in a child bash"
    chk_contains "child-rc=0" "$out" "AX-13: child bash completes under set -u"
    chk_absent "command not found" "$out" "AX-13: no '_log: command not found'"

    out=$(/usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin "$BASH_BIN" -c '
        source "$1/lib/logger.sh"; bash -c "echo child-ok"' _ "$ROOT_DIR" 2>&1)
    chk "child-ok" "$out" "AX-7 contract: sourcing the logger leaves child bash clean"
}

# ── AX-12 / AX-14: tools start and complete ─────────────────────────────────
test_system_diagnostics_modes() {
    local mode
    for mode in --help --quick --dashboard --versions --setup; do
        _tool sysdiag -- "$ROOT_DIR/tools/system-diagnostics.sh" "$mode"
        chk 0 "$RC" "system-diagnostics $mode exits 0"
        chk_absent "readonly variable" "$OUT" "system-diagnostics $mode: no readonly crash"
    done
    _tool sysdiag -- "$ROOT_DIR/tools/system-diagnostics.sh" --quick
    chk_contains "Quick check completed" "$OUT" "system-diagnostics --quick reaches the end"
    _tool sysdiag -- "$ROOT_DIR/tools/system-diagnostics.sh" --dashboard
    chk_contains "%" "$OUT" "system-diagnostics --dashboard prints a score"
    _tool sysdiag -- "$ROOT_DIR/tools/system-diagnostics.sh" --json
    chk 0 "$RC" "system-diagnostics --json exits 0"
    if command -v python3 >/dev/null 2>&1; then
        local verdict
        verdict=$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d["summary"]["total_checks"] > 0 else "empty")' 2>&1)
        chk ok "$verdict" "system-diagnostics --json emits valid JSON with checks"
    else
        echo "SKIP: python3 unavailable — JSON validity not checked"
    fi
}

test_analytics_report_starts() {
    _tool analytics -- "$ROOT_DIR/tools/analytics-report.sh" --help
    chk 0 "$RC" "analytics-report --help exits 0"
    chk_absent "readonly variable" "$OUT" "analytics-report: no readonly crash"
    _tool analytics -- "$ROOT_DIR/tools/analytics-report.sh" -f json
    chk 0 "$RC" "analytics-report -f json exits 0"
}

test_setup_wizard_starts() {
    # Interactive: with stdin at EOF it must reach the first prompt, then stop.
    _tool wizard TERM=xterm -- "$ROOT_DIR/scripts/setup-wizard.sh"
    chk_absent "readonly variable" "$OUT" "setup-wizard: no readonly crash at startup"
    chk_contains " - Choose individual components" "$OUT" "setup-wizard reaches profile selection"
}

test_validate_setup_summarizes() {
    _tool validate -- "$ROOT_DIR/validate-setup.sh"
    chk_contains "Validation Summary" "$OUT" "validate-setup runs every validation and prints the summary"
    chk_contains "error(s)" "$OUT" "validate-setup reports its error count"
    chk 1 "$RC" "validate-setup exits 1 on an empty HOME (errors found)"
}

test_version_diagnostic_completes() {
    local report_dir="$_SBX/report"
    rm -rf -- "$report_dir" && mkdir -p "$report_dir"
    _tool vdiag REPORT_PATH="$report_dir/diag.txt" -- "$ROOT_DIR/tools/version-diagnostic-enhanced.sh" --quick
    chk_contains "Diagnostic Summary" "$OUT" "version-diagnostic --quick reaches the summary"
    chk_absent "unbound variable" "$OUT" "version-diagnostic --quick: no unbound variable"
    chk 1 "$( [[ -s "$report_dir/diag.txt" ]] && echo 1 || echo 0)" "report written to REPORT_PATH"
    chk_contains "DIAGNOSTIC SUMMARY" "$(cat "$report_dir/diag.txt" 2>/dev/null)" "report has the summary section"
    local leftovers
    leftovers=$(find "$report_dir" -name '.version-diagnostic-report.*' | wc -l | tr -d ' ')
    chk 0 "$leftovers" "no temp report left next to REPORT_PATH"
    local fixed
    fixed=$(grep -cE '"/tmp/(shell_startup_test\.sh|version-diagnostic-report\.tmp)"' \
        "$ROOT_DIR/tools/version-diagnostic-enhanced.sh" || true)
    chk 0 "$fixed" "no predictable /tmp temp paths remain in the version diagnostic tool"
}

test_no_errexit_unsafe_increments() {
    # ((x++)) returns status 1 when x is 0 and aborts under set -e (B1.5 class).
    local hits
    hits=$(cd "$ROOT_DIR" && git ls-files '*.sh' | grep -vE '^(tests|FontPatcher)/' |
        xargs grep -nE '\(\( *[A-Za-z_]+ *(\+\+|--) *\)\)' 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#|# not \(\(x\+\+\)\)' || true)
    chk "" "$hits" "no ((var++)) / ((var--)) statements in shipped shell code"
}

test_logger_globals_and_child_bash
test_system_diagnostics_modes
test_analytics_report_starts
test_setup_wizard_starts
test_validate_setup_summarizes
test_version_diagnostic_completes
test_no_errexit_unsafe_increments

if [[ "$failures" -gt 0 ]]; then
    echo "test_tool_entrypoints.sh: $failures assertion(s) failed"
    exit 1
fi
echo "test_tool_entrypoints.sh: all assertions passed"
exit 0
