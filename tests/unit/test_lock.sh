#!/usr/bin/env bash

set -euo pipefail

source ../helpers.sh
source ../../lib/lock.sh

coverage_init "lock"
coverage_expect 3

TEST_STATE_DIR=""

setup_lock_test() {
  TEST_STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vms-lock-test.XXXXXX")
  export VMS_STATE_DIR="$TEST_STATE_DIR/state"
  mkdir -p "$VMS_STATE_DIR"
}

teardown_lock_test() {
  if [[ -n "$TEST_STATE_DIR" && "$TEST_STATE_DIR" == */vms-lock-test.* ]]; then
    rm -rf "$TEST_STATE_DIR"
  fi
  unset VMS_STATE_DIR
}

test_acquire_timeout_and_release() {
  setup_lock_test
  track_coverage "lock_acquire"
  track_coverage "lock_release"

  lock_acquire "basic" 1

  local second_status=0
  lock_acquire "basic" 1 || second_status=$?
  assert_exit_code 1 "$second_status" "Second acquire times out while lock is held"

  lock_release "basic"
  lock_acquire "basic" 1
  assert_equals "$$" "$(cat "$VMS_STATE_DIR/locks/basic.lock.d/pid")" "Acquire succeeds after release"
  lock_release "basic"

  teardown_lock_test
}

test_concurrent_acquire_serializes_critical_section() {
  setup_lock_test
  track_coverage "lock_acquire"

  local holder_file="$TEST_STATE_DIR/holder"
  local violation_file="$TEST_STATE_DIR/violations"
  : > "$violation_file"

  local worker
  for worker in {1..10}; do
    bash -c '
      set -euo pipefail
      log_info() { :; }
      log_warn() { :; }
      log_error() { :; }
      log_debug() { :; }
      source ../../lib/lock.sh
      if lock_acquire "concurrent" 5; then
        printf "%s\n" "$$" > "$1"
        sleep 0.1
        if [[ "$(cat "$1")" != "$$" ]]; then
          printf "violation %s\n" "$$" >> "$2"
        fi
        lock_release "concurrent"
      else
        printf "acquire failed %s\n" "$$" >> "$2"
      fi
    ' bash "$holder_file" "$violation_file" &
  done

  wait
  assert_equals "0" "$(wc -l < "$violation_file" | tr -d ' ')" "Concurrent lock holders do not overlap"

  teardown_lock_test
}

test_stale_lock_reclaimed() {
  setup_lock_test
  track_coverage "lock_acquire"

  sleep 0.01 &
  local dead_pid=$!
  wait "$dead_pid" || true

  mkdir -p "$VMS_STATE_DIR/locks/stale.lock.d"
  printf '%s\n' "$dead_pid" > "$VMS_STATE_DIR/locks/stale.lock.d/pid"

  lock_acquire "stale" 1
  assert_equals "$$" "$(cat "$VMS_STATE_DIR/locks/stale.lock.d/pid")" "Stale lock is reclaimed"
  lock_release "stale"

  teardown_lock_test
}

test_invalid_name_rejected() {
  setup_lock_test
  track_coverage "lock_acquire"

  local status=0
  lock_acquire "bad/name" 1 || status=$?
  assert_exit_code 1 "$status" "Invalid lock name is rejected"

  teardown_lock_test
}

test_release_refuses_other_pid() {
  setup_lock_test
  track_coverage "lock_release"

  mkdir -p "$VMS_STATE_DIR/locks/owned.lock.d"
  printf '%s\n' "999999" > "$VMS_STATE_DIR/locks/owned.lock.d/pid"

  local status=0
  lock_release "owned" || status=$?
  assert_exit_code 1 "$status" "Release refuses a lock owned by another pid"
  assert_file_exists "$VMS_STATE_DIR/locks/owned.lock.d/pid" "Other process lock remains"

  teardown_lock_test
}

test_acquire_timeout_and_release
test_concurrent_acquire_serializes_critical_section
test_stale_lock_reclaimed
test_invalid_name_rejected
test_release_refuses_other_pid
coverage_report

exit 0