#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
source "$ROOT_DIR/setup.sh"

test_setup_defines_main() {
  if declare -f main >/dev/null 2>&1; then
    assert_equals "defined" "defined" "setup.sh defines main function"
  else
    assert_equals "defined" "missing" "setup.sh should define main function"
  fi
}

test_setup_defines_setup_versions() {
  if declare -f setup_versions >/dev/null 2>&1; then
    assert_equals "defined" "defined" "setup.sh defines setup_versions function"
  else
    assert_equals "defined" "missing" "setup.sh should define setup_versions function"
  fi
}

failures=0
test_setup_defines_main || failures=$((failures + 1))
test_setup_defines_setup_versions || failures=$((failures + 1))

if [[ "$failures" -gt 0 ]]; then
  echo "test_setup.sh: $failures assertion(s) failed"
  exit 1
fi
