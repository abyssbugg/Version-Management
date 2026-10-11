#!/usr/bin/env bash

# Test helpers for shell scripts

# =============================================================================
# RA-6 (re-audit 2026-10-10): refuse to run against the real home directory.
# =============================================================================
# Tests mutate $HOME freely (rc files, backups, fonts, state). They are meant
# to run under tests/test_runner.sh, which gives every test file a fresh
# mktemp HOME. A test started by hand from a normal shell would otherwise
# write into the developer's real home. The account's home is read from the
# password database, not from $HOME, and compared after resolving symlinks.
# Fail closed when it cannot be determined. A non-interactive shell (a test
# file) exits; an interactive shell that sources this file only gets
# `return 1`, so a developer's session is never killed.
# tests/test_runner.sh itself runs in the real home (it CREATES the sandboxes)
# and opts out by setting the NON-exported shell variable
# _VMS_HELPERS_CALLER=test_runner. An exported (inherited) value is ignored,
# so a test child can never inherit the opt-out.
_vms_passwd_home() {
  local user home=""
  if command -v python3 >/dev/null 2>&1; then
    home=$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null) || home=""
  fi
  if [[ -z "$home" ]]; then
    user=$(id -un 2>/dev/null) || user=""
    if [[ -n "$user" ]] && command -v getent >/dev/null 2>&1; then
      home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6) || home=""
    elif [[ -n "$user" ]] && command -v dscl >/dev/null 2>&1; then
      home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}') || home=""
    fi
  fi
  [[ -n "$home" ]] || return 1
  printf '%s\n' "$home"
}

_vms_canonical_dir() {  # print the symlink-resolved path, or the input unchanged
  local d="${1%/}"
  [[ -n "$d" ]] || d="/"
  if [[ -d "$d" ]]; then
    (cd -P -- "$d" 2>/dev/null && pwd -P) || printf '%s\n' "$d"
  else
    printf '%s\n' "$d"
  fi
}

_vms_refuse_real_home() {
  local real current
  if [[ -z "${HOME:-}" ]]; then
    echo "FATAL: tests/helpers.sh: HOME is unset — run tests via tests/test_runner.sh (sandboxed HOME, RA-6)" >&2
    return 1
  fi
  if ! real=$(_vms_passwd_home); then
    echo "FATAL: tests/helpers.sh: cannot determine this account's home directory to prove HOME is a sandbox — refusing (RA-6)" >&2
    return 1
  fi
  current=$(_vms_canonical_dir "$HOME")
  real=$(_vms_canonical_dir "$real")
  if [[ "$current" == "$real" ]]; then
    echo "FATAL: tests/helpers.sh: HOME is your real home ($real) — tests mutate HOME; run them via tests/test_runner.sh or make test-unit (sandboxed HOME, RA-6)" >&2
    return 1
  fi
  return 0
}

_vms_helpers_runner_optout() {
  [[ "$(declare -p _VMS_HELPERS_CALLER 2>/dev/null)" == 'declare -- _VMS_HELPERS_CALLER="test_runner"' ]]
}

if ! _vms_helpers_runner_optout && ! _vms_refuse_real_home; then
  case "$-" in
    *i*) return 1 ;;
    *) exit 1 ;;
  esac
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Assertion functions
assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="${3:-}"

  if [ "$expected" = "$actual" ]; then
    echo -e "${GREEN}✓ ${message} (passed)${NC}"
    return 0
  else
    echo -e "${RED}✗ ${message} (failed)${NC}"
    echo "Expected: $expected"
    echo "Actual: $actual"
    return 1
  fi
}

assert_contains() {
  local expected="$1"
  local actual="$2"
  local message="${3:-}"

  if [[ "$actual" == *"$expected"* ]]; then
    echo -e "${GREEN}✓ ${message} (passed)${NC}"
    return 0
  else
    echo -e "${RED}✗ ${message} (failed)${NC}"
    echo "Expected to contain: $expected"
    echo "Actual: $actual"
    return 1
  fi
}

assert_file_exists() {
  local file="$1"
  local message="${2:-}"

  if [ -f "$file" ]; then
    echo -e "${GREEN}✓ ${message} (file exists)${NC}"
    return 0
  else
    echo -e "${RED}✗ ${message} (file does not exist)${NC}"
    return 1
  fi
}

assert_file_not_exists() {
  local file="$1"
  local message="${2:-}"

  if [ ! -f "$file" ]; then
    echo -e "${GREEN}✓ ${message} (file does not exist)${NC}"
    return 0
  else
    echo -e "${RED}✗ ${message} (file exists)${NC}"
    return 1
  fi
}

assert_not_empty() {
  local value="$1"
  local message="${2:-}"

  if [[ -n "$value" ]]; then
    echo -e "${GREEN}✓ ${message} (not empty)${NC}"
    return 0
  else
    echo -e "${RED}✗ ${message} (was empty)${NC}"
    return 1
  fi
}

assert_command_exists() {
  local cmd="$1"
  local message="${2:-}"

  if command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ ${message:-command '$cmd' exists}${NC}"
    return 0
  else
    echo -e "${RED}✗ ${message:-command '$cmd' not found}${NC}"
    return 1
  fi
}

assert_exit_code() {
  local expected_code="$1"
  local actual_code="$2"
  local message="${3:-}"

  if [[ "$actual_code" -eq "$expected_code" ]]; then
    echo -e "${GREEN}✓ ${message} (exit code $actual_code)${NC}"
    return 0
  else
    echo -e "${RED}✗ ${message} (expected exit $expected_code, got $actual_code)${NC}"
    return 1
  fi
}

# Test setup and teardown
setup_test() {
  echo "Setting up test environment..."

  if [[ -n "${_VMS_TEST_HOME:-}" && "${HOME:-}" == "$_VMS_TEST_HOME" ]]; then
    mkdir -p "$HOME/.config" "$HOME/.cache"
    touch "$HOME/.zshrc"
    return 0
  fi

  _VMS_REAL_HOME="${HOME:-}"
  _VMS_REAL_XDG_CONFIG_HOME="${XDG_CONFIG_HOME-}"
  _VMS_REAL_XDG_CACHE_HOME="${XDG_CACHE_HOME-}"
  _VMS_TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/vms-test-home.XXXXXX")

  mkdir -p "$_VMS_TEST_HOME/.config" "$_VMS_TEST_HOME/.cache"
  touch "$_VMS_TEST_HOME/.zshrc"

  export HOME="$_VMS_TEST_HOME"
  export XDG_CONFIG_HOME="$_VMS_TEST_HOME/.config"
  export XDG_CACHE_HOME="$_VMS_TEST_HOME/.cache"
}

teardown_test() {
  echo "Tearing down test environment..."

  local sandbox="${_VMS_TEST_HOME:-}"

  if [[ -n "${_VMS_REAL_HOME+x}" ]]; then
    export HOME="$_VMS_REAL_HOME"
  fi

  if [[ -n "${_VMS_REAL_XDG_CONFIG_HOME+x}" ]]; then
    if [[ -n "$_VMS_REAL_XDG_CONFIG_HOME" ]]; then
      export XDG_CONFIG_HOME="$_VMS_REAL_XDG_CONFIG_HOME"
    else
      unset XDG_CONFIG_HOME
    fi
  fi

  if [[ -n "${_VMS_REAL_XDG_CACHE_HOME+x}" ]]; then
    if [[ -n "$_VMS_REAL_XDG_CACHE_HOME" ]]; then
      export XDG_CACHE_HOME="$_VMS_REAL_XDG_CACHE_HOME"
    else
      unset XDG_CACHE_HOME
    fi
  fi

  if [[ -n "$sandbox" && "$sandbox" == */vms-test-home.* ]]; then
    rm -rf "$sandbox"
  fi

  unset _VMS_TEST_HOME _VMS_REAL_HOME _VMS_REAL_XDG_CONFIG_HOME _VMS_REAL_XDG_CACHE_HOME
}

# =============================================================================
# Coverage Tracking
# =============================================================================
# INTENT TRACKING, NOT LINE COVERAGE (P1-11): this section records which
# functions a test file manually marked as exercised (.coverage marker file).
# The numbers are test-intent signals only — they are not produced by a
# coverage engine and must not be read as line/path coverage. Real line
# coverage: `make coverage-kcov` (kcov over the unit suite, --include-path=lib)
# or the coverage-kcov Buildkite job.
#
# Usage:
#   At the top of a test file:       coverage_init "my_module"
#   Before each tested function:     track_coverage "function_name"
#   At the end of a test file:       coverage_report
# =============================================================================

COVERAGE_FILE="${COVERAGE_FILE:-.coverage}"
_COVERAGE_TOTAL=0
_COVERAGE_CALLED=0

# Initialize coverage for a module (call once per test file)
coverage_init() {
  local module="${1:-unknown}"
  : > "$COVERAGE_FILE"  # truncate/create
  echo "# coverage module=$module ts=$(date +%s)" >> "$COVERAGE_FILE"
}

# Record that a function was exercised
track_coverage() {
  local func_name="$1"
  _COVERAGE_CALLED=$((_COVERAGE_CALLED + 1))
  echo "$func_name" >> "$COVERAGE_FILE"
}

# Register total expected functions (call after listing all functions to test)
coverage_expect() {
  local total="$1"
  _COVERAGE_TOTAL="$total"
}

# Print a coverage summary
generate_coverage_report() {
  local called
  called=$(grep -vc '^#' "$COVERAGE_FILE" 2>/dev/null || echo "0")
  echo ""
  echo "====== Coverage Report (intent tracking, not line coverage) ======"
  echo "Engine: none — manual function markers only; real line coverage is make coverage-kcov (kcov)"
  echo "Functions exercised: $called"
  if [[ "$_COVERAGE_TOTAL" -gt 0 ]]; then
    local pct=$(( called * 100 / _COVERAGE_TOTAL ))
    echo "Expected total:      $_COVERAGE_TOTAL"
    echo "Coverage:            ${pct}%"
    if [[ "$pct" -lt 80 ]]; then
      echo "WARNING: Coverage below 80%"
    fi
  fi
  echo "Details (by function):"
  grep -v '^#' "$COVERAGE_FILE" 2>/dev/null | sort | uniq -c | sort -rn
  echo "============================="
}

# Alias kept for backward compatibility
coverage_report() { generate_coverage_report; }

# TAP output support
tap_start() {
  echo "1..$1"
}

tap_pass() {
  echo "ok $1 - $2"
}

tap_fail() {
  echo "not ok $1 - $2"
}

# =============================================================================
# Extended Test Helpers (used by font tests and others)
# =============================================================================
_TEST_PASS_COUNT=0
_TEST_FAIL_COUNT=0
_TEST_SKIP_COUNT=0
_CURRENT_TEST=""

start_test() {
  _CURRENT_TEST="$1"
  echo "--- $1 ---"
}

end_test() {
  _CURRENT_TEST=""
}

pass() {
  local message="${1:-passed}"
  _TEST_PASS_COUNT=$((_TEST_PASS_COUNT + 1))
  echo -e "${GREEN}✓ ${message}${NC}"
}

fail() {
  local message="${1:-failed}"
  _TEST_FAIL_COUNT=$((_TEST_FAIL_COUNT + 1))
  echo -e "${RED}✗ ${message}${NC}"
}

skip() {
  local message="${1:-skipped}"
  _TEST_SKIP_COUNT=$((_TEST_SKIP_COUNT + 1))
  echo -e "${YELLOW}⊘ ${message}${NC}"
}

print_summary() {
  echo ""
  echo "====== Test Summary ======"
  echo -e "${GREEN}Passed: $_TEST_PASS_COUNT${NC}"
  echo -e "${RED}Failed: $_TEST_FAIL_COUNT${NC}"
  echo -e "${YELLOW}Skipped: $_TEST_SKIP_COUNT${NC}"
  echo "=========================="
  return "$_TEST_FAIL_COUNT"
}
