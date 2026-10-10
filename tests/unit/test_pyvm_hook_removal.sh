#!/usr/bin/env bash
# =============================================================================
# pyvm auto-activate hook removal (AX-20)
# =============================================================================
# pyvm_remove_auto_activate used to rewrite ~/.zshrc through a /tmp file + mv
# (no backup, mode reset, symlink replaced by a plain file) and an
# unterminated legacy block made its awk range delete every following line.
# Binding invariants for the legacy-block remover and its public wrapper:
#   - a well-formed legacy block is removed; every user line survives; the
#     rc keeps its mode; a symlinked rc stays a link; the pre-state is in the
#     transaction backup;
#   - unterminated/duplicated markers are refused with the file unchanged;
#   - TRANSACTION_DRY_RUN=1 changes nothing; an absent block is a no-op.
# Safety: every case runs in a child bash with a mktemp -d HOME.
# =============================================================================

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB=$(mktemp -d "${TMPDIR:-/tmp}/vms-pyvm-hook.XXXXXX")
SB=$(cd "$SB" && pwd -P)
trap 'rm -rf -- "$SB"' EXIT
mkdir -p "$SB/tmp"
source "$ROOT_DIR/tests/helpers.sh"

failures=0
chk() { assert_equals "$@" || failures=$((failures + 1)); }
chk_contains() { assert_contains "$@" || failures=$((failures + 1)); }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

OUT="" RC=0
# _run <case> [VAR=value ...] -- <function>
_run() {
    local tag="$1"
    shift
    local -a envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
    shift
    OUT=$(/usr/bin/env -i HOME="$SB/$tag" TMPDIR="$SB/tmp" PATH="/usr/bin:/bin:$(dirname "$(command -v bash)")" \
        SHELL=/bin/zsh "${envs[@]}" "$(command -v bash)" -c \
        'source "$1/lib/pyvm.sh" >/dev/null 2>&1 || exit 97; "$2"' _ "$ROOT_DIR" "$1" 2>&1)
    RC=$?
}
legacy_rc() {  # <file> <terminated: yes|no>
    {
        printf '# user top\nexport KEEP_TOP=1\n\n# >>> pyvm auto-activate hook <<<\n_pyvm_chpwd_hook() { :; }\n'
        [[ "$2" == yes ]] && printf '# <<< pyvm auto-activate hook <<<\n'
        printf 'export KEEP_BOTTOM=1\n'
    } > "$1"
}

test_wellformed_block_removed() {
    local h="$SB/wellformed"
    mkdir -p "$h/dotfiles"
    legacy_rc "$h/dotfiles/zshrc" yes
    chmod 640 "$h/dotfiles/zshrc"
    ln -s "$h/dotfiles/zshrc" "$h/.zshrc"
    _run wellformed -- _pyvm_remove_legacy_hook
    chk 0 "$RC" "legacy block removal exits 0"
    chk $'# user top\nexport KEEP_TOP=1\n\nexport KEEP_BOTTOM=1' "$(cat "$h/.zshrc")" "block removed, every user line kept"
    chk 1 "$([[ -L "$h/.zshrc" ]] && echo 1 || echo 0)" "symlinked rc is still a link"
    chk 640 "$(mode_of "$h/dotfiles/zshrc")" "rc keeps mode 640"
    local hits
    hits=$(grep -rl '_pyvm_chpwd_hook' "$h" 2>/dev/null | grep -vc '/dotfiles/zshrc$')
    chk 1 "$([[ "$hits" -ge 1 ]] && echo 1 || echo 0)" "pre-state kept in the transaction backup"
}

test_unterminated_block_refused() {
    local h="$SB/unterminated" before
    mkdir -p "$h"
    legacy_rc "$h/.zshrc" no
    before=$(cat "$h/.zshrc")
    _run unterminated -- _pyvm_remove_legacy_hook
    chk 1 "$RC" "unterminated legacy block refused"
    chk "$before" "$(cat "$h/.zshrc")" "rc unchanged (KEEP_BOTTOM not deleted)"
    chk_contains "refusing; file left unchanged" "$OUT" "refusal explains itself"
}

test_dry_run_and_absent() {
    local h="$SB/dry" before
    mkdir -p "$h"
    legacy_rc "$h/.zshrc" yes
    before=$(cat "$h/.zshrc")
    _run dry TRANSACTION_DRY_RUN=1 -- _pyvm_remove_legacy_hook
    chk 0 "$RC" "dry-run exits 0"
    chk "$before" "$(cat "$h/.zshrc")" "dry-run changes nothing"
    chk_contains "[dry-run] would remove the legacy pyvm auto-activate block" "$OUT" "dry-run prints the plan"
    h="$SB/absent"
    mkdir -p "$h"
    printf 'export ONLY_USER=1\n' > "$h/.zshrc"
    _run absent -- _pyvm_remove_legacy_hook
    chk 0 "$RC" "absent block is a no-op"
    chk "export ONLY_USER=1" "$(cat "$h/.zshrc")" "rc untouched when no block exists"
}

test_public_wrapper() {
    if ! command -v zsh >/dev/null 2>&1; then
        echo "SKIP: zsh unavailable — pyvm_remove_auto_activate end-to-end not exercised"
        return 0
    fi
    local h="$SB/wrapper"
    mkdir -p "$h"
    legacy_rc "$h/.zshrc" yes
    OUT=$(/usr/bin/env -i HOME="$h" TMPDIR="$SB/tmp" PATH="/usr/bin:/bin:$(dirname "$(command -v bash)"):$(dirname "$(command -v zsh)")" \
        SHELL=/bin/zsh "$(command -v bash)" -c 'source "$1/lib/pyvm.sh" >/dev/null 2>&1 || exit 97; pyvm_remove_auto_activate' _ "$ROOT_DIR" 2>&1)
    RC=$?
    chk 0 "$RC" "pyvm_remove_auto_activate exits 0"
    chk $'# user top\nexport KEEP_TOP=1\n\nexport KEEP_BOTTOM=1' "$(cat "$h/.zshrc")" "wrapper removes the legacy block and keeps user lines"
}

test_wellformed_block_removed
test_unterminated_block_refused
test_dry_run_and_absent
test_public_wrapper

if [[ "$failures" -gt 0 ]]; then
    echo "test_pyvm_hook_removal.sh: $failures assertion(s) failed"
    exit 1
fi
echo "test_pyvm_hook_removal.sh: all assertions passed"
exit 0
