#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
setup_test
trap teardown_test EXIT

# shellcheck source=lib/cache.sh
source "$ROOT_DIR/lib/cache.sh"

test_cache_set_get() {
  local key="test_key"
  local value="test_value"
  local ttl=5

  cache_set "$key" "$value" "$ttl"
  local result=$(cache_get "$key")

  assert_equals "$value" "$result" "Cache set and get works"
}

test_cache_cleanup() {
  local key="expired_key"
  local value="expired_value"
  local ttl=1

  cache_set "$key" "$value" "$ttl"
  sleep 2
  local result=$(cache_get "$key" "$ttl")

  assert_equals "" "$result" "Cache cleanup works"
}

test_cache_namespace() {
  local key="ns_key"
  local value="ns_value"
  local namespace="test_ns"

  cache_namespace_set "$namespace" "$key" "$value"
  local result=$(cache_namespace_get "$namespace" "$key")

  assert_equals "$value" "$result" "Cache namespace works"
}

test_cache_cleanup_namespace() {
  local key="ns_expired_key"
  local value="ns_expired_value"
  local namespace="test_ns_expired"

  cache_namespace_set "$namespace" "$key" "$value"
  # Remove the cache file to simulate cleanup
  cache_namespace_clear "$namespace"
  local result=$(cache_namespace_get "$namespace" "$key" 2>/dev/null || echo "")

  assert_equals "" "$result" "Cache namespace cleanup works"
  assert_equals "true" "$([ -d "$CACHE_DIR/$namespace" ] && echo true || echo false)" "Cache namespace directory is recreated after valid clear"
}

test_cache_exec_argv_caches_output() {
  local command_script="$HOME/cache_exec_counter.sh"
  local counter_file="$HOME/cache_exec_counter.txt"
  local cache_key="cache_exec_argv_counter"

  cat > "$command_script" <<'SCRIPT'
#!/usr/bin/env bash
counter_file="$1"
label="$2"
count=0
if [[ -f "$counter_file" ]]; then
  count=$(cat "$counter_file")
fi
count=$((count + 1))
echo "$count" > "$counter_file"
printf '%s:%s\n' "$label" "$count"
SCRIPT
  chmod +x "$command_script"

  cache_delete "$cache_key" 2>/dev/null || true

  local first_result
  first_result=$(cache_exec_argv "$cache_key" 60 "$command_script" "$counter_file" "run")
  local second_result
  second_result=$(cache_exec_argv "$cache_key" 60 "$command_script" "$counter_file" "run")
  local execution_count
  execution_count=$(cat "$counter_file")

  assert_equals "run:1" "$first_result" "cache_exec_argv returns command output"
  assert_equals "run:1" "$second_result" "cache_exec_argv returns cached output"
  assert_equals "1" "$execution_count" "cache_exec_argv avoids re-execution on cache hit"
}

test_cache_exec_argv_handles_literal_arguments() {
  local command_script="$HOME/cache_exec_literal.sh"
  local cache_key="cache_exec_argv_literal"
  local special_arg='value with spaces; $(echo injected) * [brackets] "quotes"'

  cat > "$command_script" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$1"
SCRIPT
  chmod +x "$command_script"

  cache_delete "$cache_key" 2>/dev/null || true

  local result
  result=$(cache_exec_argv "$cache_key" 60 "$command_script" "$special_arg")

  assert_equals "$special_arg" "$result" "cache_exec_argv preserves literal arguments"
}

test_cache_safe_execute_uses_argv() {
  local command_script="$HOME/cache_safe_literal.sh"
  local cache_key="cache_safe_argv_literal"
  local canary_file="$HOME/cache_safe_canary"
  local special_arg="value with spaces; touch $canary_file; \$(touch $canary_file)"

  cat > "$command_script" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$1"
SCRIPT
  chmod +x "$command_script"

  rm -f "$canary_file"
  cache_delete "$cache_key" 2>/dev/null || true

  local result
  result=$(cache_safe_execute "$cache_key" 60 "$command_script" "$special_arg")

  assert_equals "$special_arg" "$result" "cache_safe_execute preserves argv arguments"
  assert_file_not_exists "$canary_file" "cache_safe_execute does not evaluate metacharacters"
}

test_cache_namespace_rejects_invalid_names() {
  local invalid_namespace
  local status
  local canary_dir="$HOME/cache_namespace_canary"
  mkdir -p "$canary_dir"

  for invalid_namespace in "../evil" "a b" ""; do
    status=0
    cache_namespace_get "$invalid_namespace" "key" >/dev/null 2>&1 || status=$?
    assert_exit_code 1 "$status" "cache_namespace_get rejects '$invalid_namespace'"

    status=0
    cache_namespace_set "$invalid_namespace" "key" "value" >/dev/null 2>&1 || status=$?
    assert_exit_code 1 "$status" "cache_namespace_set rejects '$invalid_namespace'"

    status=0
    cache_namespace_clear "$invalid_namespace" >/dev/null 2>&1 || status=$?
    assert_exit_code 1 "$status" "cache_namespace_clear rejects '$invalid_namespace'"
    assert_equals "true" "$([ -d "$canary_dir" ] && echo true || echo false)" "invalid namespace '$invalid_namespace' deletes nothing outside cache"
  done
}

test_cache_namespace_clear_all_preserves_external_canary() {
  local canary_dir="$HOME/cache_clear_all_canary"
  mkdir -p "$canary_dir"

  cache_namespace_set "commands" "clear_all_key" "clear_all_value"
  cache_namespace_clear_all

  assert_equals "true" "$([ -d "$CACHE_DIR" ] && echo true || echo false)" "cache_namespace_clear_all reinitializes cache directory"
  assert_equals "true" "$([ -d "$canary_dir" ] && echo true || echo false)" "cache_namespace_clear_all preserves external canary"
}

test_cache_stats_after_dedup() {
  cache_namespace_set "commands" "stats_key" "stats_value"

  local output
  output=$(cache_stats)

  assert_contains "Cache Statistics" "$output" "cache_stats produces statistics"
  assert_contains "commands:" "$output" "cache_stats reports namespace counts"
}

test_cache_stats_defined_once() {
  local definition_count
  definition_count=$(grep -c '^cache_stats()' "$ROOT_DIR/lib/cache.sh")

  assert_equals "1" "$definition_count" "cache_stats is defined exactly once"
}

# Run tests
test_cache_set_get
test_cache_cleanup
test_cache_namespace
test_cache_cleanup_namespace
test_cache_exec_argv_caches_output
test_cache_exec_argv_handles_literal_arguments
test_cache_safe_execute_uses_argv
test_cache_namespace_rejects_invalid_names
test_cache_namespace_clear_all_preserves_external_canary
test_cache_stats_after_dedup
test_cache_stats_defined_once

exit $?
