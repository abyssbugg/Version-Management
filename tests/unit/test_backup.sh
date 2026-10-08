#!/usr/bin/env bash

source "${BASH_SOURCE[0]%/*}/../helpers.sh" || { echo "FATAL: cannot source helpers.sh — run via tests/test_runner.sh (P0-3: unsandboxed HOME writes forbidden)" >&2; exit 1; }
source ../../lib/backup.sh

test_backup_file() {
  local test_file="test_backup.txt"
  local backup_dir="backup"
  mkdir -p "$backup_dir"
  touch "$test_file"

  local backup_path=$(create_backup "$test_file" "$backup_dir")
  local backup_file=$(basename "$backup_path")

  if [ -n "$backup_file" ]; then
    echo -e "${GREEN}✓ Backup file created successfully${NC}"
    rm "$test_file"
    rm "$backup_dir/$backup_file"
    return 0
  else
    echo -e "${RED}✗ Backup file not created${NC}"
    rm "$test_file"
    return 1
  fi
}

test_restore_backup() {
  local test_file="test_restore.txt"
  local backup_dir="backup"
  mkdir -p "$backup_dir"
  touch "$test_file"
  local backup_path=$(create_backup "$test_file" "$backup_dir")

  rm "$test_file"
  # Pass full backup path as identifier
  restore_backup "$test_file" "$backup_path" "$backup_dir"

  if [ -f "$test_file" ]; then
    echo -e "${GREEN}✓ Restore backup successful${NC}"
    rm -f "$backup_path"
    return 0
  else
    echo -e "${RED}✗ Restore backup failed${NC}"
    rm -f "$backup_path"
    return 1
  fi
}

# Run tests
test_backup_file
test_restore_backup

exit $?
