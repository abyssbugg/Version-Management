#!/usr/bin/env bash
# P0-3-runtime-home: sourcing a library must not pin future writes to old HOME.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB=$(mktemp -d "${TMPDIR:-/tmp}/tmp_rovodev_backup_home.XXXXXX")
trap 'rm -rf -- "$SB"' EXIT
export HOME="$SB/source-home" TMPDIR="$SB/tmp"
mkdir -p "$HOME/.config-backups/restore_points/same-name" "$TMPDIR" "$SB/active-home" "$SB/later-home"
unset LOG_FILE TXN_AUDIT_LOG TRANSACTION_DRY_RUN BACKUP_DIR
source "$ROOT/lib/backup.sh"
source_root="$HOME/.config-backups"
printf 'old home canary\n' >"$source_root/old.backup.20000101_000000"
printf 'restore point canary\n' >"$source_root/restore_points/same-name/keep"
export HOME="$SB/active-home"
failures=0
check() { if "$@"; then printf 'PASS: %s\n' "$1"; else
    printf 'FAIL: %s\n' "$*"
    failures=$((failures + 1))
fi; }
root="$HOME/.config-backups"
printf 'original\n' >"$HOME/.zshrc"
printf 'prompt\n' >"$HOME/.p10k.zsh"
# Source-only compatibility constant stays readable, but no operation uses it.
check test "$DEFAULT_BACKUP_DIR" = "$source_root"
backup=$(create_backup "$HOME/.zshrc")
check test "$backup" = "$root/$(basename "$backup")"
check cmp -s "$backup" "$HOME/.zshrc"
zshrc_backup=$(create_zshrc_backup)
check test "$zshrc_backup" = "$root/$(basename "$zshrc_backup")"
prompt_backup=$(create_p10k_backup)
check test "$prompt_backup" = "$root/$(basename "$prompt_backup")"
case "$(uname -s)" in
    Darwin) vscode_dir="$HOME/Library/Application Support/Code/User" ;;
    Linux) vscode_dir="$HOME/.config/Code/User" ;;
    *) vscode_dir="$HOME/AppData/Roaming/Code/User" ;;
esac
mkdir -p "$vscode_dir"
printf '{}\n' >"$vscode_dir/settings.json"
check create_vscode_backup
check test "$(find "$root" -name 'vscode.settings.json.backup.*' -type f | wc -l | tr -d ' ')" = 1
# Explicit positional destination keeps precedence over HOME.
explicit=$(create_backup "$HOME/.zshrc" "$SB/explicit")
check test "$explicit" = "$SB/explicit/$(basename "$explicit")"
# A changed HOME must not relocate an already-started rollback.
transaction_start home_isolation
transaction_add_file "$HOME/.zshrc"
txn="$_TRANSACTION_DIR"
check test "$(dirname "$txn")" = "$root/transactions"
target="$HOME/.zshrc"
printf 'changed\n' >"$target"
export HOME="$SB/later-home"
check transaction_rollback
check test "$(cat "$target")" = original
check test -f "$txn/metadata.json"
check test ! -d "$HOME/.config-backups/transactions"
transaction_start later
check test "$(dirname "$_TRANSACTION_DIR")" = "$HOME/.config-backups/transactions"
check transaction_commit
export HOME="$SB/active-home"
# Restore-point creation/list/restore/delete must agree on the runtime root.
check create_restore_point same-name "$target"
check test -f "$root/restore_points/same-name/mappings.txt"
check test -f "$source_root/restore_points/same-name/keep"
check list_restore_points
printf 'changed again\n' >"$target"
check restore_from_point same-name
check test "$(cat "$target")" = original
check delete_restore_point same-name
check test ! -d "$root/restore_points/same-name"
check test -f "$source_root/restore_points/same-name/keep"
# Queries and retention must never silently fall back to the source-time root.
listing=$(list_backups)
check test "${listing#*old.backup.20000101_000000}" = "$listing"
check cleanup_old_backups '' 0 100
check test -f "$source_root/old.backup.20000101_000000"
# Timestamp lookup uses current root, not the frozen source value.
mkdir -p "$root"
printf 'restored value\n' >"$root/.zshrc.backup.20000101_000000"
check restore_backup "$target" 20000101_000000
check test "$(cat "$target")" = 'restored value'
# No source-home writes other than the two deliberate fixture canaries.
check test "$(find "$source_root" -type f | wc -l | tr -d ' ')" = 2
# Exported backup functions retain their runtime-root dependency in child shells.
child_backup=$(bash -c 'source "$1/lib/logger.sh"; create_backup "$2"' bash "$ROOT" "$target")
check test "$child_backup" = "$root/$(basename "$child_backup")"
# Empty/unset HOME must fail closed before any default-root write.
if HOME='' transaction_start invalid_home >/dev/null 2>&1; then
    check false
    transaction_rollback
fi
if HOME=relative _backup_default_dir >/dev/null 2>&1; then check false; fi
if HOME='' _backup_default_dir >/dev/null 2>&1; then check false; fi
if (
    unset HOME
    create_backup "$target"
) >/dev/null 2>&1; then check false; fi
printf 'Backup HOME isolation: %s failure(s)\n' "$failures"
[[ "$failures" == 0 ]]
