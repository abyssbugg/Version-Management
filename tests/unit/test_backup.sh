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

# Regression (restore-point integrity): two paths that collided under the old
# tr '/' '_' scheme (/a/b_c and /a_b/c -> _a_b_c) must now get distinct
# payloads and each restore its OWN content.
test_restore_point_no_collision() {
  local sb; sb=$(mktemp -d "${TMPDIR:-/tmp}/vms-rp-collide.XXXXXX")
  mkdir -p "$sb/a/b_c" "$sb/a_b/c"
  printf 'ONE\n' > "$sb/a/b_c/x"
  printf 'TWO\n' > "$sb/a_b/c/x"
  HOME="$sb" create_restore_point collide "$sb/a/b_c/x" "$sb/a_b/c/x" >/dev/null 2>&1
  printf 'CORRUPT\n' > "$sb/a/b_c/x"; printf 'CORRUPT\n' > "$sb/a_b/c/x"
  HOME="$sb" restore_from_point collide >/dev/null 2>&1
  if [[ "$(cat "$sb/a/b_c/x")" == "ONE" && "$(cat "$sb/a_b/c/x")" == "TWO" ]]; then
    echo -e "${GREEN}✓ Restore point: colliding paths kept distinct${NC}"; rm -rf "$sb"; return 0
  else
    echo -e "${RED}✗ Restore point collision: wrong content restored${NC}"; rm -rf "$sb"; return 1
  fi
}

# Regression (transaction integrity): if the rollback record cannot be written,
# transaction_add_file must FAIL CLOSED (nonzero), never return 0. Root-proof:
# we replace the transaction dir's record files with DIRECTORIES, so the `>>`
# append fails with EISDIR for any user (chmod a-w is a no-op under root/CI).
test_transaction_add_file_fail_closed() {
  local sb; sb=$(mktemp -d "${TMPDIR:-/tmp}/vms-txn-fc.XXXXXX")
  HOME="$sb" transaction_start probe >/dev/null 2>&1
  printf 'orig\n' > "$sb/t.txt"
  # Make both rollback-record targets un-appendable regardless of uid:
  # a directory in place of the expected regular file -> `>>` fails (EISDIR).
  rm -f "$_TRANSACTION_DIR/files.tsv" "$_TRANSACTION_DIR/new_files.txt" 2>/dev/null
  mkdir -p "$_TRANSACTION_DIR/files.tsv" "$_TRANSACTION_DIR/new_files.txt"
  HOME="$sb" transaction_add_file "$sb/t.txt" >/dev/null 2>&1; local rc_e=$?
  HOME="$sb" transaction_add_file "$sb/new.txt" >/dev/null 2>&1; local rc_n=$?
  # Restore writable record files so rollback/cleanup don't wedge.
  rmdir "$_TRANSACTION_DIR/files.tsv" "$_TRANSACTION_DIR/new_files.txt" 2>/dev/null
  : > "$_TRANSACTION_DIR/files.tsv" 2>/dev/null; : > "$_TRANSACTION_DIR/new_files.txt" 2>/dev/null
  transaction_rollback >/dev/null 2>&1 || true
  if [[ "$rc_e" -ne 0 && "$rc_n" -ne 0 ]]; then
    echo -e "${GREEN}✓ transaction_add_file fails closed on unwritable record${NC}"; rm -rf "$sb"; return 0
  else
    echo -e "${RED}✗ transaction_add_file returned success despite failed record (existing=$rc_e new=$rc_n)${NC}"; rm -rf "$sb"; return 1
  fi
}

# Regression (backup validation integrity): validate_backup must compare
# SHA-256 content hashes with whichever tool the host has. The old check
# hashed only via `shasum`, so on hosts that ship only `sha256sum` (minimal
# Linux images) it silently fell back to size-only and accepted an
# equal-size but different backup.
test_validate_backup_hashes_without_shasum() {
  local sb; sb=$(mktemp -d "${TMPDIR:-/tmp}/vms-vb.XXXXXX")
  mkdir -p "$sb/bin" "$sb/nohash"
  local t
  for t in stat awk cut; do
    ln -s "$(command -v "$t")" "$sb/bin/$t"
    ln -s "$(command -v "$t")" "$sb/nohash/$t"
  done
  if command -v sha256sum >/dev/null 2>&1; then
    ln -s "$(command -v sha256sum)" "$sb/bin/sha256sum"
  elif [[ -x /usr/bin/shasum ]]; then
    # sha256sum stand-in that is NOT named shasum (absolute target, so it
    # still works under the restricted PATH below).
    printf '#!/bin/sh\nexec /usr/bin/shasum -a 256 "$@"\n' > "$sb/bin/sha256sum"
    chmod +x "$sb/bin/sha256sum"
  else
    echo -e "${YELLOW}⊘ validate_backup hash test skipped: no sha256sum or /usr/bin/shasum${NC}"
    rm -rf "$sb"; return 0
  fi
  printf 'AAAA\n' > "$sb/orig"
  printf 'BBBB\n' > "$sb/tampered"   # same size, different content
  cp "$sb/orig" "$sb/copy"

  local rc_tampered rc_copy rc_nohash
  ( PATH="$sb/bin"; validate_backup "$sb/orig" "$sb/tampered" ) >/dev/null 2>&1; rc_tampered=$?
  ( PATH="$sb/bin"; validate_backup "$sb/orig" "$sb/copy" ) >/dev/null 2>&1; rc_copy=$?
  # No SHA-256 tool at all: the documented size-only fallback is preserved.
  # shellcheck disable=SC2123 # deliberate: restricted PATH probe in a subshell
  ( PATH="$sb/nohash"; validate_backup "$sb/orig" "$sb/copy" ) >/dev/null 2>&1; rc_nohash=$?
  rm -rf "$sb"

  if [[ "$rc_tampered" -ne 0 && "$rc_copy" -eq 0 && "$rc_nohash" -eq 0 ]]; then
    echo -e "${GREEN}✓ validate_backup rejects an equal-size tampered backup without shasum${NC}"; return 0
  else
    echo -e "${RED}✗ validate_backup without shasum: tampered=$rc_tampered (want !=0) copy=$rc_copy (want 0) nohash=$rc_nohash (want 0)${NC}"; return 1
  fi
}

# Run tests — aggregate: any failure fails the file (not just the last test).
_bk_fails=0
test_backup_file || _bk_fails=$((_bk_fails + 1))
test_restore_backup || _bk_fails=$((_bk_fails + 1))
test_restore_point_no_collision || _bk_fails=$((_bk_fails + 1))
test_transaction_add_file_fail_closed || _bk_fails=$((_bk_fails + 1))
test_validate_backup_hashes_without_shasum || _bk_fails=$((_bk_fails + 1))

exit "$_bk_fails"
