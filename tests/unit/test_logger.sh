#!/usr/bin/env bash

source ../helpers.sh
source ../../lib/logger.sh

# Logger output format is: [timestamp] [LEVEL] message
# Example: [2024-01-15 10:30:25] [INFO] Test message

test_log_info() {
  local output=$(log_info "Test message")
  # Check for [INFO] and the message text
  assert_contains "[INFO]" "$output" "Log info contains level"
  assert_contains "Test message" "$output" "Log info contains message"
}

test_log_error() {
  local output=$(log_error "Test error" 2>&1)
  # log_error outputs to stderr, so we capture both streams
  assert_contains "[ERROR]" "$output" "Log error contains level"
  assert_contains "Test error" "$output" "Log error contains message"
}

test_log_debug() {
  # Debug only outputs when DEBUG=true
  DEBUG=true
  local output=$(log_debug "Test debug")
  assert_contains "[DEBUG]" "$output" "Log debug contains level"
  assert_contains "Test debug" "$output" "Log debug contains message"
  unset DEBUG
}

test_log_success() {
  local output=$(log_success "Test success")
  assert_contains "[SUCCESS]" "$output" "Log success contains level"
  assert_contains "Test success" "$output" "Log success contains message"
}

# Run tests
test_log_info
test_log_error
test_log_debug
test_log_success

exit $?