#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh" || { echo "FATAL: cannot source helpers.sh — run via tests/test_runner.sh (P0-3: unsandboxed HOME writes forbidden)" >&2; exit 1; }

# P0-3: sandbox HOME before sourcing setup.sh or driving any behavior that
# touches ~/. The behavioral case below writes ~/.p10k.zsh and ~/.nvm; those
# writes must never reach the real HOME.
setup_test
trap teardown_test EXIT

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

# P2-13: behavioral — show_configuration must REACT to workstation state, not
# merely exist. It is read-only (inspects files/commands, logs findings), so it
# is safe to drive under a sandboxed HOME. setup_test (helpers.sh) has already
# pointed HOME at a mktemp sandbox; assert the two file-based branches both ways.
test_show_configuration_reflects_state() {
  if ! declare -f show_configuration >/dev/null 2>&1; then
    assert_equals "defined" "missing" "setup.sh should define show_configuration"
    return
  fi

  # Absent: no ~/.p10k.zsh, no ~/.nvm -> "not found" / warning branches.
  rm -f "$HOME/.p10k.zsh"; rm -rf "$HOME/.nvm"
  local out_absent
  out_absent="$(show_configuration 2>&1)"
  if printf '%s' "$out_absent" | grep -q "PowerLevel10k configuration not found"; then
    assert_equals "warn" "warn" "show_configuration reports missing ~/.p10k.zsh"
  else
    assert_equals "warn" "silent" "show_configuration should warn when ~/.p10k.zsh is absent"
  fi

  # Present: create the markers -> the positive branches must fire.
  printf '# p10k\n' > "$HOME/.p10k.zsh"; mkdir -p "$HOME/.nvm"
  local out_present
  out_present="$(show_configuration 2>&1)"
  if printf '%s' "$out_present" | grep -q "PowerLevel10k configuration: ~/.p10k.zsh" \
     && printf '%s' "$out_present" | grep -q "NVM installed: ~/.nvm"; then
    assert_equals "detected" "detected" "show_configuration reports present ~/.p10k.zsh and ~/.nvm"
  else
    assert_equals "detected" "missed" "show_configuration should report present p10k/NVM markers"
  fi
}

failures=0
test_setup_defines_main || failures=$((failures + 1))
test_setup_defines_setup_versions || failures=$((failures + 1))
test_show_configuration_reflects_state || failures=$((failures + 1))

if [[ "$failures" -gt 0 ]]; then
  echo "test_setup.sh: $failures assertion(s) failed"
  exit 1
fi
