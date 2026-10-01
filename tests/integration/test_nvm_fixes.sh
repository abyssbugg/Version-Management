#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
setup_test
source "$ROOT_DIR/scripts/fix-nvm-issues.sh"
trap teardown_test EXIT

# Test: fix_nvm_issues function exists and runs without error
test_fix_nvm_issues_runs() {
  if declare -f fix_nvm_issues >/dev/null 2>&1; then
    fix_nvm_issues 2>/dev/null
    assert_equals "0" "$?" "fix_nvm_issues runs without fatal error"
  else
    assert_equals "defined" "missing" "fix_nvm_issues should be defined"
  fi
}

# Test: NVM helper functions exist
test_nvm_fix_functions_defined() {
  local functions_found=0
  for fn in fix_silent_mode fix_verbose_issues permanent_silence; do
    if declare -f "$fn" >/dev/null 2>&1; then
      functions_found=$((functions_found + 1))
    fi
  done
  if [[ "$functions_found" -gt 0 ]]; then
    assert_equals "found" "found" "NVM fix helper functions defined ($functions_found)"
  else
    assert_equals "found" "none" "Expected NVM fix helper functions"
  fi
}

failures=0
test_fix_nvm_issues_runs || failures=$((failures + 1))
test_nvm_fix_functions_defined || failures=$((failures + 1))

teardown_test
trap - EXIT

if [[ "$failures" -gt 0 ]]; then
  echo "test_nvm_fixes.sh: $failures assertion(s) failed"
  exit 1
fi
