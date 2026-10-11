#!/usr/bin/env bash

set -euo pipefail

source "${BASH_SOURCE[0]%/*}/../helpers.sh" || { echo "FATAL: cannot source helpers.sh — run via tests/test_runner.sh (P0-3: unsandboxed HOME writes forbidden)" >&2; exit 1; }
# Explicit path: without it ShellCheck resolved ../../lib/lock.sh against the
# checkout's parent directory, so the lint result depended on where the
# repository was checked out.
# shellcheck source=lib/lock.sh
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

# AX-10: a lock taken with lock_with_trap inside a subshell must NOT chain the
# parent's EXIT trap (bash >= 4 still displays it via `trap -p` there), yet a
# trap the subshell set itself must still be chained.
test_lock_with_trap_subshell_does_not_inherit_parent_exit_trap() {
  setup_lock_test
  track_coverage "lock_with_trap"

  local parent_marker="$TEST_STATE_DIR/parent-fired" own_marker="$TEST_STATE_DIR/own-fired"
  local log="$TEST_STATE_DIR/order.log"
  bash -c '
    log_info() { :; }
    log_warn() { :; }
    log_error() { :; }
    log_debug() { :; }
    source ../../lib/lock.sh
    trap "printf \"parent\\n\" >>\"$3\"; touch \"$1\"" EXIT
    ( lock_with_trap "subshell" 5 )
    printf "after-plain-subshell\\n" >>"$3"
    ( trap "touch \"$2\"" EXIT; lock_with_trap "subshell-own" 5 )
    printf "after-own-subshell\\n" >>"$3"
  ' bash "$parent_marker" "$own_marker" "$log"

  assert_equals $'after-plain-subshell\nafter-own-subshell\nparent' "$(cat "$log")" "Parent EXIT trap fires once, only when the parent exits"
  assert_file_exists "$own_marker" "Subshell's own EXIT trap is still chained"
  local lock_left=0
  [[ -d "$VMS_STATE_DIR/locks/subshell.lock.d" || -d "$VMS_STATE_DIR/locks/subshell-own.lock.d" ]] && lock_left=1
  assert_equals "0" "$lock_left" "Subshell locks released on subshell exit"

  teardown_lock_test
}

# F3 (re-audit 2026-10-10): a reclaimer that judged a lock stale must never
# move or remove it once the path has been recycled by a live owner. The
# old rename-to-grave design moved B's live lock aside; C then acquired the
# empty path and the "restore" mv nested B's lock inside C's. The hooks run
# before every filesystem mutation the reclaimer makes, emulating the worst
# interleaving: B recycles the path first; C grabs it whenever it is absent.
test_reclaim_never_displaces_recycled_live_lock() {
  setup_lock_test
  track_coverage "lock_acquire"

  local L="$VMS_STATE_DIR/locks/race.lock.d" X B C step_file
  mkdir -p "$VMS_STATE_DIR/locks"
  sleep 0.01 & X=$!; wait "$X" || true
  sleep 30 & B=$!
  sleep 30 & C=$!
  mkdir -p "$L/owner.$X"
  step_file="$TEST_STATE_DIR/step"; echo 0 > "$step_file"

  _race_hook() {
    local step; step=$(<"$step_file")
    if [[ "$step" == 0 ]]; then
      command rm -rf "$L"; command mkdir "$L" "$L/owner.$B"
    elif [[ ! -d "$L" ]]; then
      command mkdir "$L" "$L/owner.$C"
    fi
    echo $((step + 1)) > "$step_file"
  }
  mv() { _race_hook; command mv "$@"; }
  rmdir() { _race_hook; command rmdir "$@"; }
  # The shims target lock.sh's own mv/rmdir/rm calls; logger.sh's
  # `find ... -delete` is not meant to reach them.
  # shellcheck disable=SC2032
  rm() { _race_hook; command rm "$@"; }
  _lock_reclaim_if_stale "$L" >/dev/null 2>&1 || true
  unset -f mv rmdir rm _race_hook

  local owners extra
  owners=$(cd "$L" 2>/dev/null && ls -d owner.* 2>/dev/null | tr '\n' ' ' || true)
  extra=$(find "$L" -mindepth 1 -maxdepth 1 ! -name 'owner.*' 2>/dev/null | wc -l | tr -d ' ')
  kill "$B" "$C" 2>/dev/null || true
  wait "$B" "$C" 2>/dev/null || true
  assert_equals "owner.$B " "$owners" "Recycled live lock stays at its path, owned only by its live owner"
  assert_equals "0" "$extra" "No displaced lock is nested inside the lock dir"

  teardown_lock_test
}

# F3: a stalled claimer whose owner mkdir lands in a NEWER lock (its own
# empty claim was reclaimed and B acquired the path meanwhile) must not end
# up co-owning B's lock. The hook injects that interleaving on our owner mkdir.
test_stalled_claim_cannot_co_own_newer_lock() {
  setup_lock_test
  track_coverage "lock_acquire"

  local L="$VMS_STATE_DIR/locks/stall.lock.d" B injected=0 status=0
  sleep 30 & B=$!
  mkdir() {
    if [[ "$injected" == 0 && "${1:-}" == "$L/owner.$$" ]]; then
      injected=1
      command rm -rf "$L"; command mkdir "$L" "$L/owner.$B"
    fi
    command mkdir "$@"
  }
  lock_acquire "stall" 1 >/dev/null 2>&1 || status=$?
  unset -f mkdir

  local owners
  owners=$(cd "$L" 2>/dev/null && ls -d owner.* 2>/dev/null | tr '\n' ' ' || true)
  kill "$B" 2>/dev/null || true
  wait "$B" 2>/dev/null || true
  assert_exit_code 1 "$status" "Acquire does not succeed while the live owner holds the lock"
  assert_equals "owner.$B " "$owners" "The live owner remains the only owner"

  teardown_lock_test
}

# RA-1: lock_acquire must use a successfully reclaimed lock even when the
# whole-second clock ticks over during the reclaim. The old loop checked the
# timeout BEFORE retrying, so `lock_acquire stale 1` (test_stale_lock_reclaimed)
# failed intermittently under load. The stub advances the clock one second per
# read, making the tick-over deterministic.
test_reclaimed_lock_used_despite_clock_tick() {
  setup_lock_test
  track_coverage "lock_acquire"

  local d status=0
  sleep 0.01 & d=$!; wait "$d" || true
  mkdir -p "$VMS_STATE_DIR/locks/tick.lock.d/owner.$d"
  echo 1000 > "$TEST_STATE_DIR/clock"
  date() {
    if [[ "${1:-}" == "+%s" ]]; then
      local t; t=$(<"$TEST_STATE_DIR/clock"); echo $((t + 1)) > "$TEST_STATE_DIR/clock"; echo "$t"
    else
      command date "$@"
    fi
  }
  lock_acquire "tick" 1 >/dev/null 2>&1 || status=$?
  unset -f date

  assert_exit_code 0 "$status" "Reclaimed stale lock is acquired even if the clock ticked over"
  lock_release "tick" >/dev/null 2>&1 || true

  teardown_lock_test
}

test_acquire_timeout_and_release
test_concurrent_acquire_serializes_critical_section
test_stale_lock_reclaimed
test_reclaim_never_displaces_recycled_live_lock
test_stalled_claim_cannot_co_own_newer_lock
test_reclaimed_lock_used_despite_clock_tick
test_invalid_name_rejected
test_release_refuses_other_pid
test_orphaned_claiming_is_reclaimed
test_lock_with_trap_chains_existing_exit_trap
test_lock_with_trap_subshell_does_not_inherit_parent_exit_trap
coverage_report

exit 0
