#!/usr/bin/env bash
# P3-1/P3-2: exercise real public configuration functions in private homes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX=$(mktemp -d "$ROOT/tmp_rovodev_manager.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home" TMPDIR="$SANDBOX/tmp" SHELL=/bin/zsh
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME" "$TMPDIR"
# shellcheck source=version-manager.sh
source "$ROOT/version-manager.sh"
PASS=0 FAIL=0
check() { if "$@"; then PASS=$((PASS+1)); else printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); fi; }
run_config() (
    local item="$1" destination="$2"
    get_shell_config() { printf '%s\n' "$destination"; }
    if [[ "$item" == lazy-load ]]; then
        ZDOTDIR=$(dirname "$destination") configure_lazy_load
    else
        "configure_$item"
    fi
)
for manager in nvm fnm pyenv rbenv phpenv lazy-load; do
    dir="$HOME/$manager"; mkdir -p "$dir"
    rc="$dir/.zshrc"; printf '# user canary\n' > "$rc"; chmod 600 "$rc"
    check run_config "$manager" "$rc"
    check grep -qx "# BEGIN version-management-setup:version-manager-$manager" "$rc"
    check grep -qx '# user canary' "$rc"
    cp "$rc" "$dir/expected"
    check run_config "$manager" "$rc"
    check cmp -s "$rc" "$dir/expected"
    check bash -n "$rc"
    if command -v zsh >/dev/null; then check zsh -n "$rc"; fi
    # A content symlink must remain a link, with target permissions intact.
    mv "$rc" "$dir/target"; ln -s target "$rc"
    check run_config "$manager" "$rc"
    check test -L "$rc"
    check cmp -s "$dir/target" "$dir/expected"
    if stat -c %a "$dir/target" >/dev/null 2>&1; then mode=$(stat -c %a "$dir/target"); else mode=$(stat -f %Lp "$dir/target"); fi
    check test "$mode" = 600
    # An editor failure after registration must restore the real target bytes.
    fail_edit() (
        mutation_block_write() { printf 'CORRUPTED\n' >> "$1"; return 1; }
        run_config "$manager" "$rc"
    )
    if fail_edit; then printf 'FAIL: editor failure accepted (%s)\n' "$manager"; FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi
    check cmp -s "$dir/target" "$dir/expected"
    mkdir -p "$dir/malformed"
    printf '# BEGIN version-management-setup:version-manager-%s\n' "$manager" > "$dir/malformed/.zshrc"
    cp "$dir/malformed/.zshrc" "$dir/malformed/expected"
    if run_config "$manager" "$dir/malformed/.zshrc"; then FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi
    check cmp -s "$dir/malformed/.zshrc" "$dir/malformed/expected"
    mkdir -p "$dir/new"
    check run_config "$manager" "$dir/new/.zshrc"
    # User-owned and legacy configuration is never silently replaced or duplicated.
    mkdir -p "$dir/unmanaged"
    case "$manager" in
        nvm) signature='export NVM_DIR="$HOME/custom"' ;;
        fnm) signature='# custom fnm env setup' ;;
        pyenv) signature='export PYENV_ROOT="$HOME/custom"' ;;
        rbenv) signature='# custom rbenv init setup' ;;
        phpenv) signature='export PHPENV_ROOT="$HOME/custom"' ;;
        lazy-load) signature='# >>> version-manager lazy-load <<<' ;;
    esac
    printf '%s\n' "$signature" > "$dir/unmanaged/.zshrc"
    cp "$dir/unmanaged/.zshrc" "$dir/unmanaged/expected"
    if run_config "$manager" "$dir/unmanaged/.zshrc"; then FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi
    check cmp -s "$dir/unmanaged/.zshrc" "$dir/unmanaged/expected"
done
# Preview creates neither rc files nor parent, backup, state, cache or log dirs.
preview="$SANDBOX/preview"; mkdir "$preview"
(
    # shellcheck disable=SC2030 # Preview HOME must not escape this test subshell.
    export HOME="$preview" TRANSACTION_DRY_RUN=1 SHELL=/bin/zsh
    export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
    export LOG_FILE="$HOME/unwanted.log" BACKUP_DIR="$HOME/unwanted-backups" VMS_STATE_DIR="$HOME/unwanted-state"
    get_shell_config() { printf '%s\n' "$HOME/missing/.zshrc"; }
    for manager in nvm fnm pyenv rbenv phpenv; do "configure_$manager"; done
    ZDOTDIR="$HOME/missing" configure_lazy_load
) || FAIL=$((FAIL+1))
check test -z "$(find "$preview" -mindepth 1 -print)"
# Generated NVM hooks may switch installed versions, never implicitly install.
check bash -c '! grep -Eq "^[[:space:]]*nvm install" "$1"' _ "$SANDBOX/home/nvm/target"
# Configuration-only CLI must preview before eager main initialization.
cli_home="$SANDBOX/cli-home"; mkdir "$cli_home"
cli_env=(env HOME="$cli_home" SHELL=/bin/zsh ZDOTDIR="$cli_home" TMPDIR="$cli_home"
    XDG_CONFIG_HOME="$cli_home/.config" XDG_CACHE_HOME="$cli_home/.cache"
    XDG_DATA_HOME="$cli_home/.local/share" XDG_STATE_HOME="$cli_home/.local/state"
    CONFIG_DIR="$cli_home/config" CACHE_DIR="$cli_home/cache" STATE_DIR="$cli_home/state"
    BACKUP_DIR="$cli_home/backups" VMS_STATE_DIR="$cli_home/state" LOG_FILE="$cli_home/log")
check "${cli_env[@]}" TRANSACTION_DRY_RUN=1 bash "$ROOT/version-manager.sh" configure nvm --dry-run
check test -z "$(find "$cli_home" -mindepth 1 -print)"
check "${cli_env[@]}" TRANSACTION_DRY_RUN=0 bash "$ROOT/version-manager.sh" configure fnm --dry-run
check test -z "$(find "$cli_home" -mindepth 1 -print)"
printf 'manager config: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
