#!/usr/bin/env bash
# Unit tests for lib/pyvm.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
coverage_init "pyvm"

failures=0

# Test: detect_os is used (not get_os_type which was the original bug)  
test_pyvm_uses_detect_os() {
    track_coverage "install_pyenv"

    # Verify the bug fix: get_os_type should NOT appear in the file
    if grep -q 'get_os_type' "$ROOT_DIR/lib/pyvm.sh"; then
        assert_equals "no get_os_type" "found get_os_type" \
            "lib/pyvm.sh must not call get_os_type (undefined); should call detect_os"
        failures=$((failures + 1))
    else
        assert_equals "no get_os_type" "no get_os_type" \
            "lib/pyvm.sh correctly uses detect_os instead of get_os_type"
    fi
}

# Test: pyenv target dir respects PYENV_ROOT env var
test_pyvm_respects_pyenv_root() {
    track_coverage "install_pyenv"

    if grep -q 'PYENV_ROOT' "$ROOT_DIR/lib/pyvm.sh"; then
        assert_equals "found" "found" "lib/pyvm.sh respects PYENV_ROOT env var"
    else
        assert_equals "found" "missing" "lib/pyvm.sh should reference PYENV_ROOT"
        failures=$((failures + 1))
    fi
}

coverage_expect 2
test_pyvm_uses_detect_os
test_pyvm_respects_pyenv_root

generate_coverage_report
exit "$failures"
