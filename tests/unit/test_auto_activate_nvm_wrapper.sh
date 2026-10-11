#!/usr/bin/env bash
# =============================================================================
# RA-3 (re-audit 2026-10-10): the generated zsh nvm wrapper copies nvm
# without eval
# =============================================================================
# The auto-activation hook (lib/auto-activate.sh _aa_emit_hook) wraps the
# user's nvm function so manual `nvm use|install|alias` trigger the gated
# symlink sync. It used to rename nvm by eval-ing a header-stripped copy of
# `functions nvm`. It now copies the function through zsh's $functions
# parameter. Pinned here, in real zsh (skipped honestly when zsh is absent):
#   - the emitted hook contains no eval;
#   - the wrapper calls the ORIGINAL nvm with the exact arguments (including
#     arguments with spaces and quotes) and preserves its exit status;
#   - an nvm body containing braces, quotes and `}` in strings survives;
#   - use/install/alias trigger the sync; other subcommands do not.
# =============================================================================
set -uo pipefail
source "${BASH_SOURCE[0]%/*}/../helpers.sh" || { echo "FATAL: cannot source helpers.sh — run via tests/test_runner.sh (P0-3: unsandboxed HOME writes forbidden)" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vms-nvm-wrapper.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
failures=0
ok() { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }

SILENT_MODE=true
# shellcheck source=../../lib/auto-activate.sh
source "$ROOT/lib/auto-activate.sh"

_aa_emit_hook >"$WORK/hook.zsh" || { bad "the hook can be emitted"; exit 1; }

if grep -nE '(^|[^_[:alnum:]])eval([[:space:]]|$)' "$WORK/hook.zsh" | grep -vE '^[0-9]+:[[:space:]]*#'; then
    bad "the emitted hook contains no eval (RA-3)"
else
    ok "the emitted hook contains no eval (RA-3)"
fi

if ! command -v zsh >/dev/null 2>&1; then
    printf 'SKIP: zsh not installed — wrapper behavior not exercised (reported, not passed)\n'
    printf 'auto-activate nvm wrapper (RA-3): %s failure(s)\n' "$failures"
    [[ "$failures" -eq 0 ]]
    exit
fi

# Only the wrapper section: the rest of the hook installs a chpwd hook and
# runs auto-activation for the current directory.
sed -n '/^# ---------- nvm wrapper/,$p' "$WORK/hook.zsh" >"$WORK/wrapper.zsh"
[[ -s "$WORK/wrapper.zsh" ]] || { bad "wrapper section found in the emitted hook"; exit 1; }

cat >"$WORK/driver.zsh" <<'DRIVER'
log="$WORK/calls"
# A deliberately awkward nvm body: braces and a lone } inside strings.
nvm() {
    local brace='}' open='{ x }'
    print -r -- "orig:${(j:|:)@}:$brace$open" >>"$log"
    [[ "$1" == fail ]] && return 3
    [[ "$1" == current ]] && { print v20.0.0; return 0; }
    return 0
}
_nvm_sync_symlinks() { print -r -- "sync" >>"$log"; }
source "$WORK/wrapper.zsh"
nvm use 18 "with space" "it's"
print -r -- "rc:$?" >>"$log"
nvm ls
print -r -- "rc:$?" >>"$log"
nvm fail
print -r -- "rc:$?" >>"$log"
DRIVER

export WORK
zsh -f "$WORK/driver.zsh" >"$WORK/out" 2>&1 </dev/null
zrc=$?
expected='orig:current:}{ x }
orig:use|18|with space|it'"'"'s:}{ x }
sync
rc:0
orig:current:}{ x }
orig:ls:}{ x }
rc:0
orig:current:}{ x }
orig:fail:}{ x }
rc:3'
actual=$(cat "$WORK/calls" 2>/dev/null)
if [[ "$zrc" == 0 && "$actual" == "$expected" ]]; then
    ok "wrapper calls the original nvm with exact args, syncs only on use, keeps exit status"
else
    bad "wrapper behavior (zsh rc=$zrc)"
    printf '    expected:\n%s\n    actual:\n%s\n    zsh output:\n' "$expected" "$actual"
    sed 's/^/    /' "$WORK/out"
fi

printf 'auto-activate nvm wrapper (RA-3): %s failure(s)\n' "$failures"
[[ "$failures" -eq 0 ]]
