#!/usr/bin/env bash
# A3-4/A3-5: real restore state, with all files confined to runner HOME.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../helpers.sh"
source "${BASH_SOURCE[0]%/*}/../../lib/backup.sh"
failures=0
check() { if ! "$@"; then printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); fi; }
reject() { if "$@"; then printf 'FAIL: unexpectedly accepted %s\n' "$*" >&2; failures=$((failures + 1)); fi; }
mkdir -p "$HOME/project"
local_path="$HOME/project/config with spaces"
file="$local_path"
printf 'saved\n' > "$file"
create_restore_point recovery "$file"
base="$HOME/.config-backups/restore_points"
holder="$base/.recovery@previous.test"
mkdir "$holder"
mv "$base/recovery" "$holder/point"
printf 'current\n' > "$file"
for mode in 0 1; do
    LOG_FILE="$HOME/preview-log/file" TRANSACTION_DRY_RUN=1 RESTORE_ALL_OR_NOTHING="$mode" restore_from_point recovery || failures=$((failures + 1))
    check test ! -e "$HOME/preview-log"
    check test -d "$holder/point"
    check test ! -e "$base/recovery"
    check test "$(cat "$file")" = current
    check test ! -e "$file.pre-restore"
done
TRANSACTION_DRY_RUN=0 RESTORE_ALL_OR_NOTHING=1 restore_from_point recovery
check test "$(cat "$file")" = saved
check test ! -e "$holder"
for bad in 'bad|name' $'bad\nname' $'bad\tname' $'bad\rname'; do
    printf data > "$HOME/project/$bad"
    reject create_restore_point rejected "$HOME/project/$bad"
    check test ! -e "$base/rejected"
done
reject create_restore_point . "$file"
reject create_restore_point .. "$file"
file="$local_path"
create_restore_point valid "$file"
printf 'current\n' > "$file"
printf '%s|%s\n' "$HOME/project/other" "$base/valid/missing" >> "$base/valid/mappings.txt"
env_mode_restore() { RESTORE_ALL_OR_NOTHING="$1" restore_from_point valid; }
for mode in 0 1; do
    reject env_mode_restore "$mode"
    check test "$(cat "$file")" = current
    check test ! -e "$file.pre-restore"
done
# A final mapping record without a newline must not be silently skipped.
create_restore_point final_line "$file"
mapping=$(cat "$base/final_line/mappings.txt")
printf '%s' "$mapping" > "$base/final_line/mappings.txt"
for mode in 0 1; do
    printf 'later\n' > "$file"
    RESTORE_ALL_OR_NOTHING="$mode" restore_from_point final_line || failures=$((failures + 1))
    check test "$(cat "$file")" = current
done
printf 'Restore safety failures: %s\n' "$failures"
exit "$failures"
