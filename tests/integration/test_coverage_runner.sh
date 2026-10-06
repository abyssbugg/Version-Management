#!/usr/bin/env bash
# P1-11: exercise the real runner with a recording coverage executable.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
S=$(mktemp -d "$ROOT/tmp_rovodev_coverage.XXXXXX")
trap 'rm -rf -- "$S"' EXIT
mkdir -p "$S/repo/tests/unit" "$S/repo/lib" "$S/bin" "$S/home"
cp "$ROOT/tests/test_runner.sh" "$S/repo/tests/"
export HOME="$S/home" TMPDIR="$S" XDG_CONFIG_HOME="$S/home/.config" XDG_CACHE_HOME="$S/home/.cache"
export PATH="$S/bin:$PATH"
cat > "$S/repo/tests/unit/test_sample.sh" <<'TEST'
#!/usr/bin/env bash
[[ "$PWD" == */tests/unit ]] || exit 42
exit "${SEEDED_EXIT:-0}"
TEST
cat > "$S/bin/kcov" <<'KCOV'
#!/usr/bin/env bash
set -euo pipefail
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
rm -rf -- "$S/repo/coverage"
if EMPTY_REPORT=1 bash "$S/repo/tests/test_runner.sh" coverage > "$S/empty.log" 2>&1; then
 echo 'FAIL: no coverage report was treated as success'; exit 1
fi
if TEST_FILTER=absent bash "$S/repo/tests/test_runner.sh" coverage > "$S/no-tests.log" 2>&1; then
 echo 'FAIL: no tests was treated as coverage success'; exit 1
fi
echo 'coverage runner: direct script, cwd, seeded failure, missing report and empty selection PASS'
