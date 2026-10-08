#!/usr/bin/env bash
# P3-1/P3-2: executable safety contracts for rc setup and removal.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX=$(mktemp -d "$ROOT/tmp_rovodev_autoactivate.XXXXXX")
trap 'rm -rf -- "$SANDBOX"' EXIT
export HOME="$SANDBOX/home" ZDOTDIR="$SANDBOX/home" SHELL=/bin/zsh TMPDIR="$SANDBOX"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
unset LOG_FILE BACKUP_DIR TRANSACTION_DRY_RUN NVM_DIR
mkdir -p "$HOME"
# shellcheck source=lib/auto-activate.sh
source "$ROOT/lib/auto-activate.sh"
failures=0; checks=0
check() { checks=$((checks+1)); if ! "$@"; then echo "FAIL: $*" >&2; failures=$((failures+1)); fi; }
reject() { ! "$@"; }
rc="$HOME/.zshrc"
printf '# canary\nexport KEEP_ME=yes\n' > "$rc"
cp "$rc" "$SANDBOX/original"
check auto_activate_setup
check zsh -n "$rc"
check grep -q '^# BEGIN version-management-setup:dev-auto-activate-hook$' "$rc"
cp "$rc" "$SANDBOX/applied"
check auto_activate_setup
check cmp -s "$rc" "$SANDBOX/applied"
# Repair an obsolete but syntactically valid managed payload on rerun.
printf '# canary\nexport KEEP_ME=yes\n# BEGIN version-management-setup:dev-auto-activate-hook\n# obsolete payload\n# END version-management-setup:dev-auto-activate-hook\n' > "$rc"
check auto_activate_setup
check cmp -s "$rc" "$SANDBOX/applied"
check auto_activate_remove
check cmp -s "$rc" "$SANDBOX/original"
check auto_activate_remove
# Link identity and permission preservation through both operations.
mv "$rc" "$HOME/target"; chmod 600 "$HOME/target"; ln -s target "$rc"
check auto_activate_setup
check test -L "$rc"
check test "$(stat -f '%Lp' "$HOME/target" 2>/dev/null || stat -c '%a' "$HOME/target")" = 600
check auto_activate_remove
check test -L "$rc"
check test "$(stat -f '%Lp' "$HOME/target" 2>/dev/null || stat -c '%a' "$HOME/target")" = 600
check cmp -s "$HOME/target" "$SANDBOX/original"
# Pre-register the destination before delegating: partial publication must roll back.
check reject bash -c 'source "$1/lib/auto-activate.sh"; mutation_block_write() { printf "BROKEN\n" >> "$1"; return 1; }; auto_activate_setup' _ "$ROOT"
check cmp -s "$HOME/target" "$SANDBOX/original"
check auto_activate_setup
cp "$HOME/target" "$SANDBOX/before-remove"
check reject bash -c 'source "$1/lib/auto-activate.sh"; mutation_block_remove() { printf "BROKEN\n" >> "$1"; return 1; }; auto_activate_remove' _ "$ROOT"
check cmp -s "$HOME/target" "$SANDBOX/before-remove"
# No malformed/duplicate/legacy marker may consume unrelated user content.
for content in '# BEGIN version-management-setup:dev-auto-activate-hook' '# END version-management-setup:dev-auto-activate-hook' '# >>> dev auto-activate hook <<<' ; do
    printf '%s\n# CANARY AFTER MARKER\n' "$content" > "$HOME/target"
    cp "$HOME/target" "$SANDBOX/bad"
    check reject auto_activate_setup
    check cmp -s "$HOME/target" "$SANDBOX/bad"
    check reject auto_activate_remove
    check cmp -s "$HOME/target" "$SANDBOX/bad"
done
# Duplicate complete blocks are also refused, not silently coalesced.
printf '# BEGIN version-management-setup:dev-auto-activate-hook\n# END version-management-setup:dev-auto-activate-hook\n# BEGIN version-management-setup:dev-auto-activate-hook\n# END version-management-setup:dev-auto-activate-hook\n' > "$HOME/target"
cp "$HOME/target" "$SANDBOX/duplicate"
check reject auto_activate_setup
check reject auto_activate_remove
check cmp -s "$HOME/target" "$SANDBOX/duplicate"
# Failed syntax verification after publication rolls back the complete pre-state.
cp "$SANDBOX/original" "$HOME/target"
check reject bash -c 'source "$1/lib/auto-activate.sh"; mutation_block_write() { printf "if then\n" >> "$1"; }; auto_activate_setup' _ "$ROOT"
check cmp -s "$HOME/target" "$SANDBOX/original"
# Dry run cannot create even temporary, cache, journal or log files.
check bash -c 'set -eu; export HOME="$2" ZDOTDIR="$2" TMPDIR="$2" SHELL=/bin/zsh XDG_CONFIG_HOME="$2/config" LOG_FILE="$2/log" TRANSACTION_DRY_RUN=1; source "$1/lib/auto-activate.sh"; mktemp() { return 99; }; auto_activate_setup; auto_activate_remove; test -z "$(find "$2" -mindepth 1 -print)"' _ "$ROOT" "$(mktemp -d "$SANDBOX/preview.XXXXXX")"
# Refuse lock denial and nesting; preserve the caller's traps.
cp "$SANDBOX/original" "$HOME/target"
check reject bash -c 'source "$1/lib/auto-activate.sh"; lock_acquire() { return 1; }; auto_activate_setup' _ "$ROOT"
check cmp -s "$HOME/target" "$SANDBOX/original"
check reject bash -c 'source "$1/lib/auto-activate.sh"; _TRANSACTION_ACTIVE=outer; auto_activate_setup' _ "$ROOT"
check bash -c 'source "$1/lib/auto-activate.sh"; trap : RETURN; before=$(trap -p RETURN); auto_activate_setup; test "$before" = "$(trap -p RETURN)"' _ "$ROOT"
printf 'autoactivate safety: %s checks, %s failures\n' "$checks" "$failures"
[[ "$failures" == 0 ]]
