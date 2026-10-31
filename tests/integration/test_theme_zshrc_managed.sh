#!/usr/bin/env bash
# =============================================================================
# Theme ~/.zshrc Adoption Tests (INT-1)
# =============================================================================
# GO criteria: the managed block `setup-theme-p10k` becomes the single owner
# of the oh-my-zsh + Powerlevel10k wiring; the interactive gate `[[ -o
# interactive ]]` replaces the stdout-tty gate that starved wrapped
# interactive shells; legacy strip is EXACT (bare fi/else elsewhere must
# survive); rerun byte-identical; dry-run zero writes; injected block-write
# failure rolls the strip back; --zshrc-only never touches ~/.p10k.zsh;
# segment enablement is idempotent and handles both the commented and the
# absent pyenv element.
# =============================================================================

source "${BASH_SOURCE[0]%/*}/../helpers.sh" || { echo "FATAL: cannot source helpers.sh — run via tests/test_runner.sh (P0-3: unsandboxed HOME writes forbidden)" >&2; exit 1; }

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }

# Local inverted assertion (helpers.sh has no assert_not_equals).
assert_not_equals() { # <not-expected> <actual> <message>
    if [[ "$1" == "$2" ]]; then
        echo "✗ $3 (failed): unexpectedly equals '$1'"
        return 1
    fi
    echo "✓ $3 (passed)"
    return 0
}

# Fixture rc carrying the exact legacy wiring shape (INT-1 evidence). The
# trailing if-block proves the strip never consumes a bare column-0 `fi` that
# belongs to real user code, nor anything after it.
_fixture_rc() {
    cat > "$SBX/.zshrc" << 'RC'
# user preamble
export EDITOR=vim

# Enable Powerlevel10k instant prompt (should stay at the top).
if [[ -t 1 && -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

path_prepend "$HOME/.local/bin"

# Oh My Zsh configuration
export ZSH="$HOME/.oh-my-zsh"
if [[ -t 1 ]]; then
  ZSH_THEME="powerlevel10k/powerlevel10k"
else
  ZSH_THEME=""
fi
plugins=(git)
source "$ZSH/oh-my-zsh.sh"

# Load Powerlevel10k config only for real terminal sessions.
[[ ! -t 1 || ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# ---------- NVM ----------
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

if [[ -x "$HOME/.factory/bin/x" ]]; then
  export X=1
fi
keep_me_after_bare_fi=1
RC
}

# Stock-shape p10k config. Variant "with-pyenv-comment" also carries a
# commented pyenv element in the RIGHT list (uncomment branch).
_fixture_p10k() {
    local pyenv_line=""
    if [[ "${1:-}" == "with-pyenv-comment" ]]; then
        pyenv_line='    # pyenv                  # pyenv version'
    fi
    cat > "$SBX/.p10k.zsh" << P10K
typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
    os_icon
    dir
    vcs
    newline
)
typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
    status
    # node_version          # node.js version
$pyenv_line
    context
)
P10K
}

_setup() {
    SBX=$(mktemp -d "${TMPDIR:-/tmp}/vms-theme-zshrc.XXXXXX")
    export HOME="$SBX"
    mkdir -p "$SBX/.oh-my-zsh/custom/themes/powerlevel10k"
    _fixture_rc
    _fixture_p10k
}

_teardown() {
    [[ -n "${SBX:-}" && "$SBX" == */vms-theme-zshrc.* ]] && rm -rf "$SBX"
    unset HOME
}

# ── a. First run adopts: block written, legacy wiring gone, user text kept ───
test_first_run_adopts() {
    _setup
    bash "$ROOT_DIR/setup-theme.sh" --zshrc-only >/dev/null 2>&1
    local rc=$?
    chk assert_equals "0" "$rc" "zshrc-only adoption exits zero"
    grep -q 'BEGIN version-management-setup:setup-theme-p10k' "$SBX/.zshrc" \
        && chk assert_equals "managed" "managed" "managed theme block created" \
        || chk assert_equals "managed" "absent" "managed theme block created"
    grep -q '\[\[ -o interactive \]\]' "$SBX/.zshrc" \
        && chk assert_equals "interactive-gate" "interactive-gate" "block gated on interactivity" \
        || chk assert_equals "interactive-gate" "missing" "block gated on interactivity"
    ! grep -q 'ZSH_THEME=""' "$SBX/.zshrc" \
        && chk assert_equals "legacy-omz-gone" "legacy-omz-gone" "legacy omz wiring stripped" \
        || chk assert_equals "legacy-omz-gone" "present" "legacy omz wiring stripped"
    ! grep -qF '[[ ! -t 1 || ! -f ~/.p10k.zsh ]]' "$SBX/.zshrc" \
        && chk assert_equals "legacy-p10k-gone" "legacy-p10k-gone" "legacy p10k source line stripped" \
        || chk assert_equals "legacy-p10k-gone" "present" "legacy p10k source line stripped"
    grep -q 'export EDITOR=vim' "$SBX/.zshrc" \
        && chk assert_equals "preamble-kept" "preamble-kept" "user preamble preserved" \
        || chk assert_equals "preamble-kept" "lost" "user preamble preserved"
    grep -q 'keep_me_after_bare_fi=1' "$SBX/.zshrc" \
        && chk assert_equals "after-bare-fi-safe" "after-bare-fi-safe" "content after a bare fi survives the strip" \
        || chk assert_equals "after-bare-fi-safe" "eaten" "content after a bare fi survives the strip"
    grep -q '^  export X=1' "$SBX/.zshrc" \
        && chk assert_equals "if-body-safe" "if-body-safe" "indented user code preserved" \
        || chk assert_equals "if-body-safe" "eaten" "indented user code preserved"
    # Sharp positional check: the user's own bare fi must still directly
    # precede their marker line (the strip must not have consumed either).
    sed -n '/^keep_me_after_bare_fi=1/{x;p;d;};h' "$SBX/.zshrc" | grep -q '^fi$' \
        && chk assert_equals "bare-fi-intact" "bare-fi-intact" "user's bare fi still precedes their marker line" \
        || chk assert_equals "bare-fi-intact" "disturbed" "user's bare fi still precedes their marker line"
    _teardown
}

# ── b. Rerun byte-identical (idempotency) ────────────────────────────────────
test_rerun_byte_identical() {
    _setup
    bash "$ROOT_DIR/setup-theme.sh" --zshrc-only >/dev/null 2>&1
    local first; first=$(sha "$SBX/.zshrc")
    bash "$ROOT_DIR/setup-theme.sh" --zshrc-only >/dev/null 2>&1
    chk assert_equals "$first" "$(sha "$SBX/.zshrc")" "rerun is byte-identical"
    _teardown
}

# ── c. Instant-prompt guard replaced exactly; neighbors untouched ────────────
test_instant_guard_replaced() {
    _setup
    bash "$ROOT_DIR/setup-theme.sh" --zshrc-only >/dev/null 2>&1
    grep -qF 'if [[ -o interactive && -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-' "$SBX/.zshrc" \
        && chk assert_equals "guard-fixed" "guard-fixed" "instant-prompt guard uses interactivity" \
        || chk assert_equals "guard-fixed" "missing" "instant-prompt guard uses interactivity"
    ! grep -qF 'if [[ -t 1 && -r' "$SBX/.zshrc" \
        && chk assert_equals "old-guard-gone" "old-guard-gone" "old stdout-tty instant guard removed" \
        || chk assert_equals "old-guard-gone" "present" "old stdout-tty instant guard removed"
    grep -qF 'source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"' "$SBX/.zshrc" \
        && chk assert_equals "neighbors-kept" "neighbors-kept" "instant-prompt source line untouched" \
        || chk assert_equals "neighbors-kept" "lost" "instant-prompt source line untouched"
    _teardown
}

# ── d. --zshrc-only never touches ~/.p10k.zsh ────────────────────────────────
test_zshrc_only_leaves_p10k() {
    _setup
    local pre; pre=$(sha "$SBX/.p10k.zsh")
    bash "$ROOT_DIR/setup-theme.sh" --zshrc-only >/dev/null 2>&1
    chk assert_equals "$pre" "$(sha "$SBX/.p10k.zsh")" "zshrc-only leaves .p10k.zsh byte-identical"
    _teardown
}

# ── e. Dry-run: zero writes anywhere ─────────────────────────────────────────
test_dry_run_zero_writes() {
    _setup
    local rc_pre p_pre
    rc_pre=$(sha "$SBX/.zshrc")
    p_pre=$(sha "$SBX/.p10k.zsh")
    bash "$ROOT_DIR/setup-theme.sh" --dry-run --zshrc-only --enable-segments >/dev/null 2>&1
    local rc=$?
    chk assert_equals "0" "$rc" "dry-run exits zero"
    chk assert_equals "$rc_pre" "$(sha "$SBX/.zshrc")" "dry-run leaves .zshrc byte-identical"
    chk assert_equals "$p_pre" "$(sha "$SBX/.p10k.zsh")" "dry-run leaves .p10k.zsh byte-identical"
    _teardown
}

# ── f. Segment enablement: commented node_version enabled, pyenv inserted ────
test_segments_enabled() {
    _setup
    bash "$ROOT_DIR/setup-theme.sh" --zshrc-only --enable-segments >/dev/null 2>&1
    grep -qE '^[[:space:]]*node_version[[:space:]]+# node\.js version' "$SBX/.p10k.zsh" \
        && chk assert_equals "node-on" "node-on" "node_version element enabled" \
        || chk assert_equals "node-on" "off" "node_version element enabled"
    grep -qE '^[[:space:]]*pyenv[[:space:]]*$' "$SBX/.p10k.zsh" \
        && chk assert_equals "pyenv-on" "pyenv-on" "pyenv element present" \
        || chk assert_equals "pyenv-on" "absent" "pyenv element present"
    local node_line pyenv_line
    node_line=$(grep -nE '^[[:space:]]*node_version' "$SBX/.p10k.zsh" | cut -d: -f1 | head -1)
    pyenv_line=$(grep -nE '^[[:space:]]*pyenv[[:space:]]*$' "$SBX/.p10k.zsh" | cut -d: -f1 | head -1)
    if [[ -n "$node_line" && -n "$pyenv_line" && "$node_line" -lt "$pyenv_line" ]]; then
        chk assert_equals "ordered" "ordered" "pyenv follows node_version"
    else
        chk assert_equals "ordered" "unordered" "pyenv follows node_version"
    fi
    grep -q 'os_icon' "$SBX/.p10k.zsh" \
        && chk assert_equals "left-kept" "left-kept" "left list untouched" \
        || chk assert_equals "left-kept" "lost" "left list untouched"
    _teardown
}

# ── g. Segment enablement idempotent ─────────────────────────────────────────
test_segments_idempotent() {
    _setup
    bash "$ROOT_DIR/setup-theme.sh" --zshrc-only --enable-segments >/dev/null 2>&1
    local first; first=$(sha "$SBX/.p10k.zsh")
    bash "$ROOT_DIR/setup-theme.sh" --zshrc-only --enable-segments >/dev/null 2>&1
    chk assert_equals "$first" "$(sha "$SBX/.p10k.zsh")" "segment rerun is byte-identical"
    _teardown
}

# ── h. Segment enablement with a commented pyenv element: no duplicate ───────
test_segments_pyenv_uncomment_branch() {
    _setup
    _fixture_p10k "with-pyenv-comment"
    bash "$ROOT_DIR/setup-theme.sh" --zshrc-only --enable-segments >/dev/null 2>&1
    local count
    count=$(grep -cE '^[[:space:]]*pyenv' "$SBX/.p10k.zsh")
    chk assert_equals "1" "$count" "commented pyenv element uncommented exactly once"
    _teardown
}

# ── i. Injected block-write failure rolls the strip back ─────────────────────
test_injected_failure_rolls_back() {
    _setup
    local pre p_pre
    pre=$(sha "$SBX/.zshrc")
    p_pre=$(sha "$SBX/.p10k.zsh")
    # Pre-seed a MALFORMED marker set for the block name: the editor refuses
    # (AX-8) AFTER the strip has run — only a rollback can restore the rc.
    printf '# BEGIN version-management-setup:setup-theme-p10k\n# END version-management-setup:setup-theme-p10k\n# BEGIN version-management-setup:setup-theme-p10k\n' >> "$SBX/.zshrc"
    local seeded; seeded=$(sha "$SBX/.zshrc")
    bash "$ROOT_DIR/setup-theme.sh" --zshrc-only >/dev/null 2>&1
    local rc=$?
    chk assert_not_equals "0" "$rc" "malformed markers fail the run"
    chk assert_equals "$seeded" "$(sha "$SBX/.zshrc")" "rollback restores the seeded (stripped) rc byte-identically"
    chk assert_equals "$p_pre" "$(sha "$SBX/.p10k.zsh")" ".p10k.zsh untouched by the failed run"
    _teardown
}

# chk: per-assertion failure accounting that survives _teardown masking
# (TH-2: chk must feed a counter a case-level gate actually reads — the
# runner judges by exit code, so an unread counter is a vacuous green).
FAILURES=0
chk() { "$@" || FAILURES=$((FAILURES + 1)); }

# run_case: a case ending in _teardown exits 0 regardless of its assertions;
# the FAILURES delta is the real verdict (test_recovery_managed.sh pattern).
run_case() {
    local name="$1"
    shift
    local before=$FAILURES
    "$@"
    if [[ "$FAILURES" -gt "$before" ]]; then
        echo "    [case $name] $((FAILURES - before)) assertion(s) failed"
        return 1
    fi
    return 0
}

failures=0
run_case first-run-adopts test_first_run_adopts || failures=$((failures + 1))
run_case rerun-byte-identical test_rerun_byte_identical || failures=$((failures + 1))
run_case instant-guard test_instant_guard_replaced || failures=$((failures + 1))
run_case zshrc-only-p10k test_zshrc_only_leaves_p10k || failures=$((failures + 1))
run_case dry-run-zero-writes test_dry_run_zero_writes || failures=$((failures + 1))
run_case segments-enabled test_segments_enabled || failures=$((failures + 1))
run_case segments-idempotent test_segments_idempotent || failures=$((failures + 1))
run_case segments-uncomment test_segments_pyenv_uncomment_branch || failures=$((failures + 1))
run_case injected-rollback test_injected_failure_rolls_back || failures=$((failures + 1))

if [[ "$failures" -gt 0 || "$FAILURES" -gt 0 ]]; then
    echo "test_theme_zshrc_managed.sh: $failures case(s) failed, $FAILURES assertion(s) failed"
    exit 1
fi
