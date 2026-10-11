#!/usr/bin/env bash
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../helpers.sh"
ROOT="${VMS_TEST_SOURCE_ROOT:-$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)}"
source "$ROOT/lib/mutation.sh"
source "$ROOT/lib/theme-ops.sh"
failures=0
check() { if ! "$@"; then printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); fi; }
export THEME_BASE_DIR="$ROOT/config"
P10K_CONFIG="$HOME/.p10k.zsh"
printf 'old\n' > "$P10K_CONFIG"
TRANSACTION_DRY_RUN=1 theme_switch professional || failures=$((failures + 1))
check test "$(cat "$P10K_CONFIG")" = old
if (transaction_add_file() { return 1; }; theme_switch professional); then failures=$((failures + 1)); fi
check test "$(cat "$P10K_CONFIG")" = old
theme_switch professional || failures=$((failures + 1))
check cmp -s "$ROOT/config/professional-dev-p10k.zsh" "$P10K_CONFIG"
check test -z "$(_txn_sha256 "$P10K_CONFIG" | tr -d '0-9a-f')"
chmod 600 "$P10K_CONFIG"
mode_before=$(ls -l "$P10K_CONFIG" | awk '{print $1}')
theme_switch professional || failures=$((failures + 1))
check test "$(ls -l "$P10K_CONFIG" | awk '{print $1}')" = "$mode_before"
rm "$P10K_CONFIG"
printf 'target-before\n' > "$HOME/theme-target"
ln -s "$HOME/theme-target" "$P10K_CONFIG"
transaction_start theme_outer
outer=$_TRANSACTION_ACTIVE
theme_switch professional || failures=$((failures + 1))
check test "$_TRANSACTION_ACTIVE" = "$outer"
check test -L "$P10K_CONFIG"
transaction_rollback || failures=$((failures + 1))
check test "$(cat "$HOME/theme-target")" = target-before
# Provide dependency fixtures; no shell integration is loaded or installed.
mkdir -p "$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
printf '\n' > "$HOME/.zshrc"
# The executable entrypoint must honor transaction-level preview too.
TRANSACTION_DRY_RUN=1 bash "$ROOT/setup-theme.sh" professional || failures=$((failures + 1))
check test "$(cat "$HOME/theme-target")" = target-before
printf 'Theme safety failures: %s\n' "$failures"
exit "$failures"
