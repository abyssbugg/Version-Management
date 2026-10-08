#!/usr/bin/env bash
# P1-11: exercise the real runner with a recording coverage executable.
set -euo pipefail
# The outer per-file runner's filter must not select inside this fixture repo.
unset TEST_FILTER
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
S=$(mktemp -d "$ROOT/tmp_rovodev_coverage.XXXXXX")
trap 'rm -rf -- "$S"' EXIT
mkdir -p "$S/repo/tests/unit" "$S/repo/lib" "$S/bin" "$S/home"
cp "$ROOT/tests/test_runner.sh" "$S/repo/tests/"
export HOME="$S/home" TMPDIR="$S" XDG_CONFIG_HOME="$S/home/.config" XDG_CACHE_HOME="$S/home/.cache"
export PATH="$S/bin:$PATH"
# Reject a missing isolation prerequisite before creating runner resources.
mkdir -p "$S/no-tools"
bash_bin=$(command -v bash)
if PATH="$S/no-tools" "$bash_bin" "$S/repo/tests/test_runner.sh" unit >"$S/no-python.log" 2>&1; then
    echo 'FAIL: runner accepted missing python3'; exit 1
else
    [[ $? -eq 3 ]] || { echo 'FAIL: wrong missing-python exit'; exit 1; }
fi
grep -q 'python3 is required' "$S/no-python.log"
cat > "$S/repo/tests/unit/test_sample.sh" <<'TEST'
#!/usr/bin/env bash
[[ "$PWD" == */tests/unit ]] || exit 42
exit "${SEEDED_EXIT:-0}"
TEST
cat > "$S/bin/kcov" <<'KCOV'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --bash-method=DEBUG ]] || exit 38
shift
[[ "$1" == --bash-parser=/* ]] || exit 39
shift
[[ "$1" == --include-path=/*/lib ]] || exit 40
[[ "$3" == /*/tests/unit/test_sample.sh ]] || exit 41
out="$2/test_sample.sh"; mkdir -p "$out"
# Synthetic report tests the runner contract; live coverage is verified separately.
if [[ "${EMPTY_REPORT:-0}" != 1 ]]; then
 printf '<coverage lines-valid="2" lines-covered="1"><packages><package><classes><class filename="lib/sample.sh"><lines><line number="1" hits="1"/></lines></class></classes></package></packages></coverage>\n' > "$out/cobertura.xml"
fi
bash "$3"
KCOV
chmod +x "$S/bin/kcov" "$S/repo/tests/unit/test_sample.sh"
bash "$S/repo/tests/test_runner.sh" coverage > "$S/pass.log" 2>&1
if SEEDED_EXIT=7 bash "$S/repo/tests/test_runner.sh" coverage > "$S/fail.log" 2>&1; then
 echo 'FAIL: seeded test failure passed coverage'; exit 1
fi
# Previous successful output must not make a later empty run pass.
if EMPTY_REPORT=1 bash "$S/repo/tests/test_runner.sh" coverage > "$S/empty.log" 2>&1; then
 echo 'FAIL: no coverage report was treated as success'; exit 1
fi
if TEST_FILTER=absent bash "$S/repo/tests/test_runner.sh" coverage > "$S/no-tests.log" 2>&1; then
 echo 'FAIL: no tests was treated as coverage success'; exit 1
fi
# B1.8: timeout must stop descendants too; inherited tracer pipes otherwise hang.
cat > "$S/repo/tests/unit/test_sample.sh" <<'TEST'
#!/usr/bin/env bash
sleep 600 &
child=$!
printf '%s\n' "$child" > "$DESCENDANT_PID_FILE"
wait "$child"
TEST
if DESCENDANT_PID_FILE="$S/child.pid" VMS_TEST_FILE_TIMEOUT=1 \
    bash "$S/repo/tests/test_runner.sh" unit > "$S/timeout.log" 2>&1; then
    echo 'FAIL: timed-out test passed'; exit 1
fi
grep -q 'exit 124' "$S/timeout.log"
child=$(cat "$S/child.pid")
state=$(ps -o stat= -p "$child" 2>/dev/null || true)
if [[ -n "$state" && "$state" != *Z* ]]; then
    kill "$child" 2>/dev/null || true
    echo 'FAIL: timeout left a running descendant'; exit 1
fi
# Hosted agents may allocate a terminal. Unattended tests must not inherit it.
cat > "$S/repo/tests/unit/test_sample.sh" <<'TEST'
#!/usr/bin/env bash
[[ ! -t 0 ]] || { echo 'FAIL: inherited terminal stdin'; exit 1; }
if read -r _; then echo 'FAIL: inherited input'; exit 1; fi
# Interactive Bash startup must not stop on a background controlling terminal.
bash --noprofile --norc -i -c exit
TEST
python3 - "$S/repo" <<'PY'
import os
import pty
import select
import signal
import sys
import time

pid, fd = pty.fork()
if pid == 0:
    try:
        os.chdir(sys.argv[1])
        os.environ['VMS_TEST_FILE_TIMEOUT'] = '3'
        os.execvp('bash', ['bash', 'tests/test_runner.sh', 'unit'])
    except OSError:
        os._exit(127)
output = bytearray()
status = None
try:
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                chunk = b''
            output.extend(chunk)
        done, code = os.waitpid(pid, os.WNOHANG)
        if done:
            status = code
            break
    if status is None:
        raise RuntimeError('runner did not finish under controlling terminal')
    if os.waitstatus_to_exitcode(status):
        print(output.decode(errors='replace'))
        raise SystemExit(1)
finally:
    if status is None:
        os.killpg(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(fd)
PY
echo 'coverage runner: tracing, failures, reports, descendant cleanup and noninteractive stdin PASS'
