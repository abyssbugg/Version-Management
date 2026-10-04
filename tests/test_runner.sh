#!/usr/bin/env bash
# =============================================================================
# Test Runner for version-management-setup
# =============================================================================
# Discovers and runs all unit + integration tests, reports results,
# and exits non-zero when any test fails.
#
# Usage:
#   ./tests/test_runner.sh               # run all tests
#   ./tests/test_runner.sh unit          # unit tests only
#   ./tests/test_runner.sh integration   # integration tests only
#   PARALLEL=true ./tests/test_runner.sh # run test files in parallel
# =============================================================================

set -euo pipefail

# Bash version contract (directive M1, finding B1.9): the harness uses
# bash-4+ constructs (mapfile, associative arrays). Fail with a clear
# message instead of a confusing syntax error on bash 3.x (macOS default).
if ((BASH_VERSINFO[0] < 4)); then
    echo "test_runner: bash >= 4.0 required (found ${BASH_VERSION})" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source test helpers (for coverage reporting)
# shellcheck source=tests/helpers.sh
if [[ -f "$SCRIPT_DIR/helpers.sh" ]]; then
    source "$SCRIPT_DIR/helpers.sh"
fi

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Configuration ─────────────────────────────────────────────────────────────
UNIT_DIR="$SCRIPT_DIR/unit"
INTEGRATION_DIR="$SCRIPT_DIR/integration"
RESULTS_DIR="${TMPDIR:-/tmp}/test_results_$$"
PARALLEL="${PARALLEL:-false}"
VERBOSE="${VERBOSE:-false}"
FILTER="${TEST_FILTER:-}"

# ── Counters ──────────────────────────────────────────────────────────────────
total_files=0
passed_files=0
failed_files=0
skipped_files=0
start_time=$(date +%s)

# ── Helpers ───────────────────────────────────────────────────────────────────
_log_header() { echo -e "${BOLD}${BLUE}▶ $*${NC}"; }
_log_pass()   { echo -e "  ${GREEN}✓ $*${NC}"; }
_log_fail()   { echo -e "  ${RED}✗ $*${NC}"; }
_log_skip()   { echo -e "  ${YELLOW}⊘ $*${NC}"; }
_log_info()   { echo -e "  ${CYAN}ℹ $*${NC}"; }

# Run a single test file and record pass/fail in a result file.
# Bounded two ways (directive finding B1.8): output is redirected to a temp
# file so the runner waits only on the DIRECT child (a command substitution
# here waited on every descendant holding the inherited pipe — how hosted
# macOS legs died silently at the job timeout, builds #22/#24/#25/#26), and a
# poll watchdog kills a genuinely hung file after VMS_TEST_FILE_TIMEOUT
# seconds (default 300), recording FAIL:124 instead of hanging.
_run_test_file() {
    local test_file="$1"
    local result_file="$2"
    local test_dir
    local test_name

    [[ -x "$test_file" ]] || chmod +x "$test_file"
    test_dir="$(dirname "$test_file")"
    test_name="$(basename "$test_file")"

    local exit_code=0
    local output
    local sandbox
    sandbox=$(mktemp -d "${TMPDIR:-/tmp}/vms-test-home.XXXXXX")
    mkdir -p "$sandbox/.config" "$sandbox/.cache"
    touch "$sandbox/.zshrc"

    local out_file timed_out=0
    local limit_ms=$(( (${VMS_TEST_FILE_TIMEOUT:-300}) * 1000 ))
    local waited_ms=0 pid
    out_file=$(mktemp "${TMPDIR:-/tmp}/vms-test-out.XXXXXX")
    (
        cd "$test_dir" && \
            HOME="$sandbox" \
            XDG_CONFIG_HOME="$sandbox/.config" \
            XDG_CACHE_HOME="$sandbox/.cache" \
            bash "./$test_name"
    ) >"$out_file" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if (( waited_ms >= limit_ms )); then
            timed_out=1
            kill "$pid" 2>/dev/null
            break
        fi
        sleep 0.1
        waited_ms=$((waited_ms + 100))
    done
    if (( timed_out )); then
        # Grace period for SIGTERM, then SIGKILL; reap either way.
        local grace=0
        while kill -0 "$pid" 2>/dev/null && (( grace < 20 )); do
            sleep 0.1
            grace=$((grace + 1))
        done
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        exit_code=124
        printf '%s\n' \
            "watchdog: ${test_name} exceeded $((limit_ms / 1000))s — killed (VMS_TEST_FILE_TIMEOUT to adjust)" \
            >> "$out_file"
    else
        wait "$pid" 2>/dev/null || exit_code=$?
    fi

    output=$(cat "$out_file")
    rm -f "$out_file"

    if [[ "$sandbox" == */vms-test-home.* ]]; then
        rm -rf "$sandbox"
    fi

    if [[ $exit_code -eq 0 ]]; then
        echo "PASS" > "$result_file"
    else
        echo "FAIL:$exit_code" > "$result_file"
    fi
    echo "$output" >> "$result_file"
}

# Display results for a completed test file
_report_test_file() {
    local test_file="$1"
    local result_file="$2"
    local name
    name=$(basename "$test_file" .sh)

    if [[ ! -f "$result_file" ]]; then
        _log_skip "$name (no result)"
        skipped_files=$((skipped_files + 1))
        return
    fi

    local status
    status=$(head -n 1 "$result_file")
    total_files=$((total_files + 1))

    if [[ "$status" == "PASS" ]]; then
        passed_files=$((passed_files + 1))
        _log_pass "$name"
        if [[ "$VERBOSE" == "true" ]]; then
            tail -n +2 "$result_file" | sed 's/^/    /'
        fi
    else
        local code="${status##FAIL:}"
        failed_files=$((failed_files + 1))
        _log_fail "$name (exit $code)"
        tail -n +2 "$result_file" | sed 's/^/    /'
    fi
}

# Collect test files for the given suite
_collect_tests() {
    local suite="$1"

    if [[ "$suite" == "all" || "$suite" == "unit" ]]; then
        if [[ -d "$UNIT_DIR" ]]; then
            find "$UNIT_DIR" -name "test_*.sh" -type f | sort | while IFS= read -r f; do
                [[ -z "$FILTER" || "$f" == *"$FILTER"* ]] && echo "$f"
            done
        fi
    fi

    if [[ "$suite" == "all" || "$suite" == "integration" ]]; then
        if [[ -d "$INTEGRATION_DIR" ]]; then
            find "$INTEGRATION_DIR" -name "test_*.sh" -type f | sort | while IFS= read -r f; do
                [[ -z "$FILTER" || "$f" == *"$FILTER"* ]] && echo "$f"
            done
        fi
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    local suite="all"

    for arg in "$@"; do
        case "$arg" in
            unit)        suite="unit" ;;
            integration) suite="integration" ;;
            --parallel)  PARALLEL=true ;;
            --verbose|-v) VERBOSE=true ;;
            *)           _log_info "Unknown argument: $arg" ;;
        esac
    done

    mkdir -p "$RESULTS_DIR"
    trap 'rm -rf "$RESULTS_DIR"' EXIT

    echo ""
    echo -e "${BOLD}══════════════════════════════════════════${NC}"
    echo -e "${BOLD}  version-management-setup Test Runner${NC}"
    echo -e "${BOLD}══════════════════════════════════════════${NC}"
    echo ""

    # Collect test files into an array
    mapfile -t test_files < <(_collect_tests "$suite")

    if [[ ${#test_files[@]} -eq 0 ]]; then
        _log_info "No test files found for suite: $suite"
        exit 0
    fi

    _log_header "Found ${#test_files[@]} test file(s) [suite=$suite, parallel=$PARALLEL]"
    echo ""

    if [[ "$PARALLEL" == "true" ]]; then
        # Run all tests in parallel
        declare -a pids=()
        declare -A pid_file
        declare -A pid_result

        for test_file in "${test_files[@]}"; do
            result_file="$RESULTS_DIR/$(basename "$test_file").result"
            _run_test_file "$test_file" "$result_file" &
            pid=$!
            pids+=("$pid")
            pid_file["$pid"]="$test_file"
            pid_result["$pid"]="$result_file"
        done

        for pid in "${pids[@]}"; do
            wait "$pid" || true
            _report_test_file "${pid_file[$pid]}" "${pid_result[$pid]}"
        done
    else
        for test_file in "${test_files[@]}"; do
            result_file="$RESULTS_DIR/$(basename "$test_file").result"
            _run_test_file "$test_file" "$result_file"
            _report_test_file "$test_file" "$result_file"
        done
    fi

    # Print coverage report if available
    if declare -f generate_coverage_report >/dev/null 2>&1; then
        generate_coverage_report
    fi

    # Summary
    local elapsed=$(( $(date +%s) - start_time ))
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════${NC}"
    printf "${BOLD}  Results: ${GREEN}%d passed${NC}  ${RED}%d failed${NC}  ${YELLOW}%d skipped${NC}  (%ds)\n" \
        "$passed_files" "$failed_files" "$skipped_files" "$elapsed"
    echo -e "${BOLD}══════════════════════════════════════════${NC}"
    echo ""

    [[ "$failed_files" -gt 0 ]] && exit 1
    exit 0
}

main "$@"
