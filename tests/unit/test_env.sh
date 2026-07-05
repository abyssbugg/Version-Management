#!/usr/bin/env bash

source ../helpers.sh
source ../../lib/env.sh

test_detect_os() {
  local os=$(detect_os)
  # detect_os returns lowercase: "macos", "linux", "windows", "unknown"
  # On macOS, it returns "macos" (not "Darwin")
  case "$os" in
    macos|linux|windows)
      assert_equals "true" "true" "OS detection works (detected: $os)"
      ;;
    *)
      assert_equals "known_os" "$os" "OS detection works"
      ;;
  esac
}

test_detect_shell() {
  local shell=$(detect_shell)
  # Accept bash or zsh as valid detected shells
  if [[ "$shell" == *bash* ]] || [[ "$shell" == *zsh* ]]; then
    assert_equals "true" "true" "Shell detection works (detected: $shell)"
  else
    assert_equals "bash_or_zsh" "$shell" "Shell detection works"
  fi
}

test_validate_env_var() {
  # Test that PATH environment variable exists
  if validate_env_var "PATH"; then
    assert_equals "true" "true" "Environment variable validation works (PATH exists)"
  else
    assert_equals "true" "false" "Environment variable validation works (PATH should exist)"
  fi
}

# Run tests
test_detect_os
test_detect_shell
test_validate_env_var

exit $?
