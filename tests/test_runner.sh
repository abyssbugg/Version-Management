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
#   ./tests/test_runner.sh coverage      # unit suite under kcov (B2.6/P1-11)
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

# Python provides portable session isolation for unattended test children.
if ! command -v python3 >/dev/null 2>&1; then
    echo "test_runner: python3 is required for isolated test execution" >&2
    exit 3
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

# ── kcov coverage mode (B2.6/P1-11 remainder) ────────────────────────────────
# "coverage" selects the unit suite and wraps every test file in kcov with
# lib/ as the instrumentation include path, writing real line coverage to
# "$ROOT_DIR/coverage". The pseudo-coverage in tests/helpers.sh remains
# intent-tracking only (see its relabeled report). Fail-closed: coverage mode
# without kcov installed aborts instead of silently running a plain suite.
KCOV_MODE="false"
KCOV_DIR="$ROOT_DIR/coverage"

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
    local -a cmd=(bash "./$test_name")
    if [[ "$KCOV_MODE" == "true" ]]; then
        # Select the shell engine, not binary ptrace/personality tracing.
        cmd=(kcov --bash-method=DEBUG --bash-parser="$(command -v bash)" --include-path="$ROOT_DIR/lib" "$KCOV_DIR" "$test_dir/$test_name")
    fi
    # A new session gives the test its own process group and no controlling
    # terminal. Merely backgrounding a process group can stop interactive shell
    # startup probes with SIGTTIN even when stdin is /dev/null.
    local monitor_was_set=0
    [[ $- == *m* ]] && monitor_was_set=1
    set +m
    (
        cd "$test_dir" && \
            HOME="$sandbox" \
            XDG_CONFIG_HOME="$sandbox/.config" \
            XDG_CACHE_HOME="$sandbox/.cache" \
            exec python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "${cmd[@]}"
    ) </dev/null >"$out_file" 2>&1 &
    pid=$!
    (( ! monitor_was_set )) || set -m
    while kill -0 "$pid" 2>/dev/null; do
        if (( waited_ms >= limit_ms )); then
            timed_out=1
            kill -TERM -- "-$pid" 2>/dev/null || true
            break
        fi
        sleep 0.1
        waited_ms=$((waited_ms + 100))
    done
    if (( timed_out )); then
        # Wait for the whole group, not only the parent: a descendant may ignore
        # SIGTERM and hold an inherited coverage pipe after its parent exits.
        local grace=0
        while kill -0 -- "-$pid" 2>/dev/null && (( grace < 20 )); do
            sleep 0.1
            grace=$((grace + 1))
        done
        kill -KILL -- "-$pid" 2>/dev/null || true
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
            coverage)    suite="unit"; KCOV_MODE="true" ;;
            --parallel)  PARALLEL=true ;;
            --verbose|-v) VERBOSE=true ;;
            *)           _log_info "Unknown argument: $arg" ;;
        esac
    done

    # B2.6/P1-11: coverage mode is fail-closed — no silent plain-suite run
    # masquerading as a coverage run.
    if [[ "$KCOV_MODE" == "true" ]] && ! command -v kcov >/dev/null 2>&1; then
        echo "test_runner: coverage mode requested but kcov is not installed — install it (apt-get install kcov / brew install kcov) or use the coverage-kcov Buildkite job" >&2
        exit 3
    fi
    if [[ "$KCOV_MODE" == "true" ]]; then
        mkdir -p "$KCOV_DIR"
        # Isolate this invocation; old or parallel runs cannot satisfy its gate.
        KCOV_DIR=$(mktemp -d "$KCOV_DIR/run.XXXXXX")
    fi

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
        [[ "$KCOV_MODE" != true ]] || exit 3
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

    # Print coverage report if available. The report is informational — a
    # failure inside it (missing/empty .coverage makes the Details pipeline
    # non-zero under this file's set -euo pipefail; pre-existing on HEAD,
    # reported as a lane finding) must never flip a fully-passing suite.
    if declare -f generate_coverage_report >/dev/null 2>&1; then
        generate_coverage_report || _log_info "coverage report incomplete (non-fatal)"
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
    if [[ "$KCOV_MODE" == true ]]; then
        # A successful subprocess alone does not prove instrumentation occurred.
        python3 - "$KCOV_DIR" "${#test_files[@]}" <<'PY' || exit 3
import pathlib, sys, xml.etree.ElementTree as ET
reports = list(pathlib.Path(sys.argv[1]).glob('test_*/cobertura.xml'))
try:
    roots = [ET.parse(path).getroot() for path in reports]
    valid = sum(int(root.get('lines-valid', '0')) for root in roots)
    hits = sum(int(root.get('lines-covered', '0')) for root in roots)
    if len(reports) < int(sys.argv[2]) or valid <= 0 or hits <= 0:
        raise ValueError('missing reports or no instrumented/executed library lines')
except (ValueError, ET.ParseError, OSError) as exc:
    print('coverage validation failed: ' + str(exc), file=sys.stderr)
    sys.exit(1)
print(f'Validated {len(reports)} real coverage reports: {hits}/{valid} executed library lines (summed per suite)')
PY
    fi
    exit 0
}

main "$@"
