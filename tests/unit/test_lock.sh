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
  assert_equals "$$" "$(_lock_owner_pid "$VMS_STATE_DIR/locks/basic.lock.d")" "Acquire succeeds after release"
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
  # Acquire timeouts under heavy runner load are serialization, not overlap:
  # record them separately so they cannot be conflated with a violation.
  local timeout_file="$TEST_STATE_DIR/timeouts"
  : > "$timeout_file"
  for worker in {1..10}; do
    bash -c '
      set -euo pipefail
      log_info() { :; }
      log_warn() { :; }
      log_error() { :; }
      log_debug() { :; }
      source ../../lib/lock.sh
      if lock_acquire "concurrent" 15; then
        printf "%s\n" "$$" > "$1"
        sleep 0.1
        if [[ "$(cat "$1")" != "$$" ]]; then
          printf "violation %s\n" "$$" >> "$2"
        fi
        lock_release "concurrent"
      else
        printf "acquire failed %s\n" "$$" >> "$3"
      fi
    ' bash "$holder_file" "$violation_file" "$timeout_file" &
  done

  wait
  # Self-classify on CI: emit the diagnostic files into the test's own output
  # so a failure names its cause (emit-manifest surfaces failing-file tails).
  if [[ -s "$timeout_file" ]]; then
    echo "TIMEOUTS (serialization under load, not overlap):" >&2
    cat "$timeout_file" >&2
  fi
  if [[ -s "$violation_file" ]]; then
    echo "VIOLATIONS (true overlap):" >&2
    cat "$violation_file" >&2
  fi
  assert_equals "0" "$(wc -l < "$violation_file" | tr -d ' ')" "Concurrent lock holders do not overlap"

  teardown_lock_test
}

test_stale_lock_reclaimed() {
  setup_lock_test
  track_coverage "lock_acquire"

  sleep 0.01 &
  local dead_pid=$!
  wait "$dead_pid" || true

  mkdir -p "$VMS_STATE_DIR/locks/stale.lock.d/owner.$dead_pid"

  lock_acquire "stale" 1
  assert_equals "$$" "$(_lock_owner_pid "$VMS_STATE_DIR/locks/stale.lock.d")" "Stale lock is reclaimed"
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

  mkdir -p "$VMS_STATE_DIR/locks/owned.lock.d/owner.999999"

  local status=0
  lock_release "owned" || status=$?
  assert_exit_code 1 "$status" "Release refuses a lock owned by another pid"
  local still=0
  [[ -d "$VMS_STATE_DIR/locks/owned.lock.d/owner.999999" ]] && still=1
  assert_equals "1" "$still" "Other process lock remains"

  teardown_lock_test
}

test_orphaned_claiming_is_reclaimed() {
  setup_lock_test
  track_coverage "lock_acquire"

  # Simulate a holder killed between mkdir(lock_dir) and mkdir(owner marker):
  # ownerless dir. Backdate mtime so the age rule declares it stale.
  mkdir -p "$VMS_STATE_DIR/locks/orphan.lock.d"
  touch -t 202601010000 "$VMS_STATE_DIR/locks/orphan.lock.d"

  lock_acquire "orphan" 2
  assert_equals "$$" "$(_lock_owner_pid "$VMS_STATE_DIR/locks/orphan.lock.d")" "Ownerless orphan lock is reclaimed by age"
  lock_release "orphan"

  teardown_lock_test
}

test_lock_with_trap_chains_existing_exit_trap() {
  setup_lock_test
  track_coverage "lock_with_trap"

  local marker="$TEST_STATE_DIR/trap-marker"
  bash -c '
    log_info() { :; }
    log_warn() { :; }
    log_error() { :; }
    log_debug() { :; }
    source ../../lib/lock.sh
    trap "touch \"$1\"" EXIT
    lock_with_trap "chained" 5
  ' bash "$marker"

  assert_file_exists "$marker" "Pre-existing EXIT trap still fires after lock_with_trap"
  local lock_left=0
  [[ -d "$VMS_STATE_DIR/locks/chained.lock.d" ]] && lock_left=1
  assert_equals "0" "$lock_left" "Lock released by chained trap on child exit"

  teardown_lock_test
}

test_acquire_timeout_and_release
test_concurrent_acquire_serializes_critical_section
test_stale_lock_reclaimed
test_invalid_name_rejected
test_release_refuses_other_pid
test_orphaned_claiming_is_reclaimed
test_lock_with_trap_chains_existing_exit_trap
coverage_report

exit 0
