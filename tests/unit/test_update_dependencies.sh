#!/usr/bin/env bash
# =============================================================================
# tools/update-dependencies.sh safety tests (AX-6g, P3-1)
# =============================================================================
# Binding invariants:
#   - --dry-run (alone = all, or combined with one target in either order)
#     prints the plan and executes NO mutating command (git pull, nvm install,
#     rustup update, npm update/audit).
#   - Version-manager self-updates use `git -C <dir> pull --ff-only`; a failed
#     pull warns with the reason and the script continues (exit 0).
#   - The nvm upgrade prompt treats EOF / non-interactive stdin as "no" instead
#     of aborting under set -e.
#   - Unknown options exit 1.
# Every tool is a PATH shim (or, for nvm, a fake sourced $NVM_DIR/nvm.sh) that
# only records its argv — nothing real is ever run.
# =============================================================================

# Self-sandbox BEFORE anything else (ENGINEERING_RULES 4.1): never the real HOME.
_UPD_SB=$(mktemp -d "${TMPDIR:-/tmp}/vms-upd-test.XXXXXX") || exit 1
_upd_cleanup() {
    if [[ -n "${_UPD_SB:-}" && "$_UPD_SB" == */vms-upd-test.* && -d "$_UPD_SB" ]]; then
        rm -rf -- "$_UPD_SB"
    fi
}
trap _upd_cleanup EXIT
export HOME="$_UPD_SB/home" TMPDIR="$_UPD_SB/tmp"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
mkdir -p "$HOME" "$TMPDIR" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
UPD_SCRIPT="$ROOT_DIR/tools/update-dependencies.sh"

source "$SCRIPT_DIR/../helpers.sh" || exit 1

# Own posture: unset-var + pipefail strict, but not errexit — the cases branch
# on the script's exit codes themselves.
set -u -o pipefail

failures=0
SHIM_DIR="$_UPD_SB/bin"
CALLS="$_UPD_SB/calls.log"
OUT="$_UPD_SB/out.txt"
RC=0

# -----------------------------------------------------------------------------
# Shims
# -----------------------------------------------------------------------------
_write_shim() {
    local name="$1" body="$2"
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "%s $*" >> "%s"\n' "$name" "$CALLS"
        printf '%s\n' "$body"
    } > "$SHIM_DIR/$name"
    chmod +x "$SHIM_DIR/$name"
}

_setup_world() {
    rm -rf -- "$SHIM_DIR" "$HOME/.nvm" "$HOME/.pyenv" "$HOME/.goenv" "$HOME/.jenv"
    rm -f -- "$CALLS" "$OUT" "$_UPD_SB/git.fail"
    mkdir -p "$SHIM_DIR"
    : > "$CALLS"

    # Git clones of the managers (so the self-update path is taken).
    mkdir -p "$HOME/.pyenv/.git" "$HOME/.goenv/.git" "$HOME/.jenv/.git"

    _write_shim git "if [ -f \"$_UPD_SB/git.fail\" ]; then
  for a in \"\$@\"; do
    if [ \"\$a\" = pull ]; then
      echo 'hint: Diverging branches can'\"'\"'t be fast-forwarded.' >&2
      echo 'fatal: Not possible to fast-forward, aborting.' >&2
      exit 128
    fi
  done
fi
exit 0"
    _write_shim pyenv 'case "$1" in
  version-name) echo 3.12.0 ;;
  install) printf "  3.12.1\n  3.13.0\n" ;;
esac
exit 0'
    _write_shim goenv 'case "$1" in
  version-name) echo 1.22.0 ;;
  install) printf "  1.22.1\n  1.23.0\n" ;;
esac
exit 0'
    _write_shim jenv 'case "$1" in
  version-name) echo 17 ;;
  versions) echo "* 17" ;;
esac
exit 0'
    _write_shim rustup 'case "$1" in
  toolchain) echo "stable-x86_64-unknown-linux-gnu (default)" ;;
esac
exit 0'
    _write_shim rustc 'echo "rustc 1.81.0 (shim)"; exit 0'
    _write_shim npm 'printf "%s\n" "npm-cwd $PWD" >> "'"$CALLS"'"; exit 0'

    # nvm is a sourced shell function, not a binary: fake $NVM_DIR/nvm.sh.
    mkdir -p "$HOME/.nvm"
    {
        printf 'nvm() {\n'
        printf '    printf "%%s\\n" "nvm $*" >> "%s"\n' "$CALLS"
        printf '    case "${1:-}" in\n'
        printf '        current) echo v18.20.0 ;;\n'
        printf '        version-remote) echo v22.11.0 ;;\n'
        printf '    esac\n'
        printf '    return 0\n'
        printf '}\n'
    } > "$HOME/.nvm/nvm.sh"
}

# Run the script in a clean env: shims first on PATH, sandboxed HOME, no
# inherited exported functions. Arg 1: stdin file. Rest: script args.
_run() {
    local stdin_file="$1"
    shift
    RC=0
    env -i \
        HOME="$HOME" TMPDIR="$TMPDIR" \
        XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
        NVM_DIR="$HOME/.nvm" PATH="$SHIM_DIR:/usr/bin:/bin" \
        TERM=dumb NO_COLOR=1 \
        "$BASH" "$UPD_SCRIPT" "$@" <"$stdin_file" >"$OUT" 2>&1 || RC=$?
}

_mutating_calls() {
    grep -E '^(git .*pull|nvm install|rustup update|npm (update|audit|install|ci))' "$CALLS" || true
}

_assert_rc() {
    assert_exit_code "$1" "$RC" "$2" || { failures=$((failures + 1)); sed 's/^/    | /' "$OUT"; }
}

_assert_no_mutation() {
    local m
    m=$(_mutating_calls)
    assert_equals "" "$m" "$1: no mutating command executed" || failures=$((failures + 1))
}

_assert_out_contains() {
    assert_contains "$1" "$(cat "$OUT")" "$2" || failures=$((failures + 1))
}

_assert_calls_contain() {
    assert_contains "$1" "$(cat "$CALLS")" "$2" || failures=$((failures + 1))
}

# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------
test_dry_run_all() {
    _setup_world
    _run /dev/null --dry-run
    _assert_rc 0 "--dry-run (all): exit 0"
    _assert_no_mutation "--dry-run (all)"
    _assert_out_contains "Would run: git -C $HOME/.pyenv pull --ff-only --quiet" "--dry-run (all): pyenv git pull planned"
    _assert_out_contains "Would run: git -C $HOME/.goenv pull --ff-only --quiet" "--dry-run (all): goenv git pull planned"
    _assert_out_contains "Would run: git -C $HOME/.jenv pull --ff-only --quiet" "--dry-run (all): jenv git pull planned"
    _assert_out_contains "Would run: nvm install --lts --reinstall-packages-from=current" "--dry-run (all): nvm install planned"
    _assert_out_contains "Would run: rustup update" "--dry-run (all): rustup update planned"
    _assert_out_contains "Would run: npm update" "--dry-run (all): npm update planned"
}

test_dry_run_per_target() {
    local spec target expect
    for spec in \
        "--dry-run --pyenv|Would run: git -C $HOME/.pyenv pull --ff-only --quiet" \
        "--pyenv --dry-run|Would run: git -C $HOME/.pyenv pull --ff-only --quiet" \
        "--goenv --dry-run|Would run: git -C $HOME/.goenv pull --ff-only --quiet" \
        "--dry-run --jenv|Would run: git -C $HOME/.jenv pull --ff-only --quiet" \
        "--dry-run --nvm|Would run: nvm install --lts --reinstall-packages-from=current" \
        "--rustup --dry-run|Would run: rustup update" \
        "--dry-run --npm|Would run: npm update" \
        "--dry-run --all|Would run: rustup update"; do
        target="${spec%%|*}"
        expect="${spec#*|}"
        _setup_world
        # shellcheck disable=SC2086 # intentional word split of the arg pair
        _run /dev/null $target
        _assert_rc 0 "$target: exit 0"
        _assert_no_mutation "$target"
        _assert_out_contains "$expect" "$target: plan printed"
    done
}

test_git_ff_only() {
    local m
    for m in pyenv goenv jenv; do
        _setup_world
        _run /dev/null "--$m"
        _assert_rc 0 "--$m: exit 0"
        _assert_calls_contain "git -C $HOME/.$m pull --ff-only --quiet" "--$m: git -C <dir> pull --ff-only"
    done
}

test_git_pull_failure_warns_and_continues() {
    _setup_world
    : > "$_UPD_SB/git.fail"
    _run /dev/null --pyenv
    _assert_rc 0 "git pull failure (--pyenv): exit 0"
    _assert_out_contains "[WARN]" "git pull failure: warning logged"
    _assert_out_contains "Not possible to fast-forward" "git pull failure: reason reported"
    _assert_out_contains "pyenv check complete" "git pull failure: pyenv check continues"

    _setup_world
    : > "$_UPD_SB/git.fail"
    _run /dev/null --all
    _assert_rc 0 "git pull failure (--all): exit 0"
    _assert_calls_contain "git -C $HOME/.goenv pull --ff-only --quiet" "git pull failure: next manager (goenv) still processed"
    _assert_calls_contain "git -C $HOME/.jenv pull --ff-only --quiet" "git pull failure: jenv still processed"
    _assert_out_contains "Dependency update complete" "git pull failure: run completes"
}

test_nvm_prompt_eof_is_no() {
    _setup_world
    _run /dev/null --nvm
    _assert_rc 0 "nvm upgrade available + stdin </dev/null: exit 0"
    if grep -q '^nvm install' "$CALLS"; then
        assert_equals "absent" "present" "nvm EOF: no nvm install" || failures=$((failures + 1))
    else
        assert_equals "absent" "absent" "nvm EOF: no nvm install" || failures=$((failures + 1))
    fi
    _assert_out_contains "skipped" "nvm EOF: skip logged"
}

test_nvm_prompt_yes_still_upgrades() {
    _setup_world
    printf 'y\n' > "$_UPD_SB/yes.txt"
    _run "$_UPD_SB/yes.txt" --nvm
    _assert_rc 0 "nvm prompt answered y: exit 0"
    _assert_calls_contain "nvm install --lts --reinstall-packages-from=current" "nvm prompt y: upgrade runs"
}

test_live_paths_still_mutate() {
    _setup_world
    _run /dev/null --rustup
    _assert_rc 0 "--rustup (live): exit 0"
    _assert_calls_contain "rustup update" "--rustup (live): rustup update executed"

    _setup_world
    _run /dev/null --npm
    _assert_rc 0 "--npm (live): exit 0"
    _assert_calls_contain "npm update" "--npm (live): npm update executed"
}

test_unknown_option() {
    _setup_world
    _run /dev/null --bogus
    _assert_rc 1 "unknown option: exit 1"
    _assert_out_contains "Unknown option: --bogus" "unknown option: reported"
    _assert_no_mutation "unknown option"

    _setup_world
    _run /dev/null --dry-run --bogus
    _assert_rc 1 "--dry-run + unknown option: exit 1"
    _assert_no_mutation "--dry-run + unknown option"
}

test_help_mentions_dry_run() {
    _setup_world
    _run /dev/null --help
    _assert_rc 0 "--help: exit 0"
    _assert_out_contains "--dry-run" "--help: documents --dry-run"
}

echo "=== tools/update-dependencies.sh Tests (AX-6g) ==="
test_dry_run_all
test_dry_run_per_target
test_git_ff_only
test_git_pull_failure_warns_and_continues
test_nvm_prompt_eof_is_no
test_nvm_prompt_yes_still_upgrades
test_live_paths_still_mutate
test_unknown_option
test_help_mentions_dry_run

echo
echo "update-dependencies: $failures failure(s)"
[[ "$failures" -eq 0 ]] || exit 1
exit 0
