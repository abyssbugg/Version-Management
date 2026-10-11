#!/usr/bin/env bash
# =============================================================================
# Interrupted runner (test hygiene, 2026-10-11)
# =============================================================================
# tests/test_runner.sh starts each test file in its own session (setsid), so a
# Ctrl-C or a TERM aimed at the runner never reaches the test. Before this
# fix an interrupted run left the test process running as an orphan and its
# sandbox HOME (vms-test-home.*) and output file (vms-test-out.*) behind in
# TMPDIR for good. Each case starts the runner on a fixture test that blocks,
# interrupts the runner once the fixture is running, and requires that the
# fixture's process group is gone and that no sandbox or output file is left.
# =============================================================================
set -euo pipefail
unset TEST_FILTER

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
S=$(mktemp -d "${TMPDIR:-/tmp}/vms-interrupt.XXXXXX")
trap 'rm -rf -- "$S"' EXIT
mkdir -p "$S/repo/tests/unit" "$S/tmp" "$S/home" "$S/mark"
cp "$ROOT/tests/test_runner.sh" "$S/repo/tests/"

# The fixture records its pid (the session and process-group leader) and
# blocks; it never finishes on its own within the test's lifetime.
cat > "$S/repo/tests/unit/test_blocking.sh" <<'TEST'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$VMS_FIXTURE_MARK/pid.tmp"
mv "$VMS_FIXTURE_MARK/pid.tmp" "$VMS_FIXTURE_MARK/pid"
sleep 600 &
wait "$!"
TEST
chmod +x "$S/repo/tests/unit/test_blocking.sh"

bash_bin=$(command -v bash)
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

# run_case <label> <signal> [runner args...]
run_case() {
    local label="$1" sig="$2" runner_pid fixture_pid i rc
    shift 2
    rm -f "$S/mark/pid"
    # python3 restores the default SIGINT disposition before exec: a
    # background job of a non-interactive shell otherwise starts with SIGINT
    # ignored, which bash then cannot trap.
    HOME="$S/home" TMPDIR="$S/tmp" VMS_FIXTURE_MARK="$S/mark" \
        python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
        "$bash_bin" "$S/repo/tests/test_runner.sh" "$@" unit >"$S/$label.log" 2>&1 &
    runner_pid=$!

    for ((i = 0; i < 100; i++)); do
        [[ -s "$S/mark/pid" ]] && break
        sleep 0.1
    done
    if [[ ! -s "$S/mark/pid" ]]; then
        fail "$label: the fixture never started"
        kill -KILL "$runner_pid" 2>/dev/null || true
        return
    fi
    fixture_pid=$(cat "$S/mark/pid")

    kill "-$sig" "$runner_pid"
    for ((i = 0; i < 100; i++)); do
        kill -0 "$runner_pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$runner_pid" 2>/dev/null; then
        fail "$label: the runner did not exit after SIG$sig"
        kill -KILL "$runner_pid" 2>/dev/null || true
    fi
    rc=0
    wait "$runner_pid" 2>/dev/null || rc=$?
    [[ "$rc" -ne 0 ]] || fail "$label: an interrupted run exited 0"

    if kill -0 -- "-$fixture_pid" 2>/dev/null; then
        fail "$label: the test's process group survived the runner (orphan)"
        kill -KILL -- "-$fixture_pid" 2>/dev/null || true
    fi
    local left
    left=$(find "$S/tmp" -mindepth 1 -maxdepth 1 \( -name 'vms-test-home.*' -o -name 'vms-test-out.*' \) | wc -l | tr -d ' ')
    [[ "$left" == 0 ]] || fail "$label: $left sandbox/output path(s) left in TMPDIR"
    find "$S/tmp" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

run_case sequential-term TERM
run_case sequential-int INT
run_case parallel-term TERM --parallel

if [[ "$failures" -gt 0 ]]; then
    echo "test_runner_interrupt.sh: $failures failure(s)"
    exit 1
fi
echo "test_runner_interrupt.sh: interrupted runs leave no orphan test and no sandbox (3 cases)"
exit 0
