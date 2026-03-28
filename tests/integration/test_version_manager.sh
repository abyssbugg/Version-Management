#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers.sh"
source "$SCRIPT_DIR/../../version-manager.sh"

# Test that create_version_files creates .nvmrc
test_create_version_files() {
  local temp_dir=$(mktemp -d)
  cd "$temp_dir" || exit 1
  
  # Call with specific version
  local test_node_version="18.16.0"
  create_version_files "$test_node_version" "3.12.0" "3.0.0"
  
  # Check .nvmrc was created
  if [[ -f ".nvmrc" ]]; then
    local nvmrc_content=$(cat .nvmrc)
    assert_equals "$test_node_version" "$nvmrc_content" "create_version_files creates .nvmrc"
  else
    assert_equals "file_exists" "file_missing" ".nvmrc should be created"
  fi
  
  # Cleanup
  cd - > /dev/null || exit 1
  rm -rf "$temp_dir"
}

# Test that .python-version is created
test_create_python_version_file() {
  local temp_dir=$(mktemp -d)
  cd "$temp_dir" || exit 1
  
  local test_python_version="3.12.0"
  create_version_files "18.0.0" "$test_python_version" "3.0.0"
  
  if [[ -f ".python-version" ]]; then
    local python_content=$(cat .python-version)
    assert_equals "$test_python_version" "$python_content" "create_version_files creates .python-version"
  else
    assert_equals "file_exists" "file_missing" ".python-version should be created"
  fi
  
  cd - > /dev/null || exit 1
  rm -rf "$temp_dir"
}

# Test that .tool-versions (asdf) is created
test_create_tool_versions_file() {
  local temp_dir=$(mktemp -d)
  cd "$temp_dir" || exit 1
  
  create_version_files "20.0.0" "3.11.0" "3.2.0"
  
  if [[ -f ".tool-versions" ]]; then
    assert_contains "nodejs 20.0.0" "$(cat .tool-versions)" ".tool-versions contains nodejs version"
    assert_contains "python 3.11.0" "$(cat .tool-versions)" ".tool-versions contains python version"
  else
    assert_equals "file_exists" "file_missing" ".tool-versions should be created"
  fi
  
  cd - > /dev/null || exit 1
  rm -rf "$temp_dir"
}

# Test health_check function exists and is callable
test_health_check_function_exists() {
  if declare -f health_check >/dev/null 2>&1; then
    assert_equals "true" "true" "health_check function exists"
  else
    assert_equals "function_exists" "function_missing" "health_check function should exist"
  fi
}

# Run tests
test_create_version_files
test_create_python_version_file
test_create_tool_versions_file
test_health_check_function_exists

exit $?