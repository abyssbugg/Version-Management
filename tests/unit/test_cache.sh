#!/usr/bin/env bash

source ../helpers.sh
source ../../lib/cache.sh

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
}

# Run tests
test_cache_set_get
test_cache_cleanup
test_cache_namespace
test_cache_cleanup_namespace

exit $?