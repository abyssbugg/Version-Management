#!/usr/bin/env bash
# =============================================================================
# Node-Manager Wiring Adoption Tests (R7: dead-nvm + raw-fnm legacy strip)
# =============================================================================
# GO criteria: `install-fnm` on a machine with fnm present adopts the shell
# wiring transactionally — the managed version-manager-fnm block becomes the
# single owner; the DEAD nvm bootstrap (target dir absent) and the RAW fnm
# eval are stripped by EXACT FULL-LINE matches; a LIVE nvm install keeps its
# lines; unknown user content survives; rerun is byte-identical; dry-run
# writes nothing; an injected block-write failure rolls the strip back.
# =============================================================================

source "${BASH_SOURCE[0]%/*}/../helpers.sh" || { echo "FATAL: cannot source helpers.sh — run via tests/test_runner.sh (P0-3: unsandboxed HOME writes forbidden)" >&2; exit 1; }

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }

# Local inverted assertion (helpers.sh has none).
assert_not_equals() {
    if [[ "$1" == "$2" ]]; then
        echo "✗ $3 (failed): unexpectedly equals '$1'"
        return 1
    fi
    echo "✓ $3 (passed)"
    return 0
}

_fixture_fnm_shim() {
    ORIG_PATH="${ORIG_PATH:-$PATH}"
    mkdir -p "$SBX/bin"
    local m
    # All four managers shimmed: install-* takes the configure-only path
    # (never brew/network) regardless of the host's inventory.
    for m in fnm pyenv rbenv phpenv; do
        printf '#!/usr/bin/env sh\nexit 0\n' > "$SBX/bin/$m"
        chmod +x "$SBX/bin/$m"
    done
    export PATH="$SBX/bin:$PATH"
}

# Dead-nvm + raw-fnm legacy shape (the live-machine evidence, R7/INT-1).
_fixture_rc() {
    cat > "$SBX/.zshrc" << 'RC'
# user preamble
export EDITOR=vim

# ---------- NVM ----------
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

eval "$(fnm env)"
export USER_MARKER=keep-me
RC
}

_setup() {
    SBX=$(mktemp -d "${TMPDIR:-/tmp}/vms-node-wiring.XXXXXX")
    export HOME="$SBX"
    _fixture_fnm_shim
    _fixture_rc
}

_teardown() {
    [[ -n "${SBX:-}" && "$SBX" == */vms-node-wiring.* ]] && rm -rf "$SBX"
    export PATH="$ORIG_PATH"
    unset HOME
}

test_adopt_strips_dead_wiring() {
    _setup
    bash "$ROOT_DIR/version-manager.sh" install-fnm >/dev/null 2>&1
    chk assert_equals "0" "$?" "install-fnm adoption exits zero"
    grep -q 'BEGIN version-management-setup:version-manager-fnm' "$SBX/.zshrc" \
        && chk assert_equals "block" "block" "managed fnm block created" \
        || chk assert_equals "block" "absent" "managed fnm block created"
    ! grep -q 'NVM_DIR' "$SBX/.zshrc" \
        && chk assert_equals "dead-nvm-gone" "dead-nvm-gone" "dead nvm bootstrap stripped (no ~/.nvm)" \
        || chk assert_equals "dead-nvm-gone" "present" "dead nvm bootstrap stripped (no ~/.nvm)"
    ! grep -qF 'eval "$(fnm env)"' "$SBX/.zshrc" \
        && chk assert_equals "raw-fnm-gone" "raw-fnm-gone" "raw fnm eval stripped" \
        || chk assert_equals "raw-fnm-gone" "present" "raw fnm eval stripped"
    grep -q 'export USER_MARKER=keep-me' "$SBX/.zshrc" \
        && chk assert_equals "user-kept" "user-kept" "user content preserved" \
        || chk assert_equals "user-kept" "lost" "user content preserved"
    grep -qF 'eval "$(fnm env --use-on-cd)"' "$SBX/.zshrc" \
        && chk assert_equals "managed-init" "managed-init" "managed init present exactly in the block" \
        || chk assert_equals "managed-init" "absent" "managed init present exactly in the block"
    _teardown
}

test_live_nvm_preserved() {
    _setup
    mkdir -p "$SBX/.nvm"   # a LIVE nvm install: its bootstrap lines are not ours to strip
    bash "$ROOT_DIR/version-manager.sh" install-fnm >/dev/null 2>&1
    grep -qF '[ -s "$NVM_DIR/nvm.sh" ]' "$SBX/.zshrc" \
        && chk assert_equals "live-nvm-kept" "live-nvm-kept" "live nvm bootstrap preserved" \
        || chk assert_equals "live-nvm-kept" "stripped" "live nvm bootstrap preserved"
    ! grep -qF 'eval "$(fnm env)"' "$SBX/.zshrc" \
        && chk assert_equals "raw-fnm-gone" "raw-fnm-gone" "raw fnm eval still stripped" \
        || chk assert_equals "raw-fnm-gone" "present" "raw fnm eval still stripped"
    _teardown
}

test_dry_run_zero_writes() {
    _setup
    local pre; pre=$(sha "$SBX/.zshrc")
    TRANSACTION_DRY_RUN=1 bash "$ROOT_DIR/version-manager.sh" install-fnm >/dev/null 2>&1
    chk assert_equals "0" "$?" "dry-run exits zero"
    chk assert_equals "$pre" "$(sha "$SBX/.zshrc")" "dry-run leaves .zshrc byte-identical"
    _teardown
}

test_injected_failure_rolls_back() {
    _setup
    local pre; pre=$(sha "$SBX/.zshrc")
    printf '# BEGIN version-management-setup:version-manager-fnm\n# END version-management-setup:version-manager-fnm\n# BEGIN version-management-setup:version-manager-fnm\n' >> "$SBX/.zshrc"
    local seeded; seeded=$(sha "$SBX/.zshrc")
    bash "$ROOT_DIR/version-manager.sh" install-fnm >/dev/null 2>&1
    chk assert_not_equals "0" "$?" "malformed markers fail the run"
    chk assert_equals "$seeded" "$(sha "$SBX/.zshrc")" "rollback restores the seeded rc byte-identically"
    _teardown
}

test_pyenv_rbenv_phpenv_adoption() {
    _setup
    # The live-machine legacy shape for the other three managers (R7 set).
    cat >> "$SBX/.zshrc" << 'RC'

# ---------- pyenv ----------
export PYENV_ROOT="$HOME/.pyenv"
path_prepend "$PYENV_ROOT/bin"
command -v pyenv >/dev/null && eval "$(pyenv init -)"

# ---------- rbenv ----------
command -v rbenv >/dev/null && eval "$(rbenv init - zsh)"

# ============================================================================
# phpenv Configuration (added by version-manager)
# ============================================================================
export PHPENV_ROOT="$HOME/.phpenv"
export PATH="$PHPENV_ROOT/bin:$PATH"

# Lazy load phpenv for faster shell startup
phpenv() {
    unset -f phpenv php
    eval "$(command phpenv init -)"
    phpenv "$@"
}

php() {
    unset -f phpenv php
    eval "$(command phpenv init -)"
    php "$@"
}

# Composer global bin
path_prepend "$HOME/.config/composer/vendor/bin"
export USER_MARKER_2=also-keep-me
RC
    bash "$ROOT_DIR/version-manager.sh" install-pyenv >/dev/null 2>&1
    chk assert_equals "0" "$?" "install-pyenv adoption exits zero"
    bash "$ROOT_DIR/version-manager.sh" install-rbenv >/dev/null 2>&1
    chk assert_equals "0" "$?" "install-rbenv adoption exits zero"
    bash "$ROOT_DIR/version-manager.sh" install-phpenv >/dev/null 2>&1
    chk assert_equals "0" "$?" "install-phpenv adoption exits zero"
    ! grep -qF 'command -v pyenv >/dev/null && eval "$(pyenv init -)"' "$SBX/.zshrc" \
        && chk assert_equals "pyenv-legacy-gone" "pyenv-legacy-gone" "legacy pyenv bootstrap stripped" \
        || chk assert_equals "pyenv-legacy-gone" "present" "legacy pyenv bootstrap stripped"
    ! grep -qF 'command -v rbenv >/dev/null && eval "$(rbenv init - zsh)"' "$SBX/.zshrc" \
        && chk assert_equals "rbenv-legacy-gone" "rbenv-legacy-gone" "legacy rbenv line stripped" \
        || chk assert_equals "rbenv-legacy-gone" "present" "legacy rbenv line stripped"
    ! grep -qF 'phpenv Configuration (added by version-manager)' "$SBX/.zshrc" \
        && chk assert_equals "phpenv-block-gone" "phpenv-block-gone" "legacy phpenv block stripped" \
        || chk assert_equals "phpenv-block-gone" "present" "legacy phpenv block stripped"
    # The managed block has its own phpenv() (with composer); the LEGACY
    # body's distinctive line (two-name unset) must be gone.
    ! grep -qFx '    unset -f phpenv php' "$SBX/.zshrc" \
        && chk assert_equals "legacy-phpenv-fn-gone" "legacy-phpenv-fn-gone" "legacy phpenv body gone (managed fn has composer)" \
        || chk assert_equals "legacy-phpenv-fn-gone" "present" "legacy phpenv body gone (managed fn has composer)"
    grep -q 'BEGIN version-management-setup:version-manager-pyenv' "$SBX/.zshrc" \
        && chk assert_equals "pyenv-block" "pyenv-block" "managed pyenv block written" \
        || chk assert_equals "pyenv-block" "absent" "managed pyenv block written"
    grep -q 'BEGIN version-management-setup:version-manager-phpenv' "$SBX/.zshrc" \
        && chk assert_equals "phpenv-block" "phpenv-block" "managed phpenv block written" \
        || chk assert_equals "phpenv-block" "absent" "managed phpenv block written"
    grep -qF 'path_prepend "$HOME/.config/composer/vendor/bin"' "$SBX/.zshrc" \
        && chk assert_equals "composer-kept" "composer-kept" "composer paths survive the range strip" \
        || chk assert_equals "composer-kept" "eaten" "composer paths survive the range strip"
    grep -q 'export USER_MARKER_2=also-keep-me' "$SBX/.zshrc" \
        && chk assert_equals "marker2-kept" "marker2-kept" "user content after the blocks preserved" \
        || chk assert_equals "marker2-kept" "lost" "user content after the blocks preserved"
    # The adopted rc must parse.
    if command -v zsh >/dev/null 2>&1; then
        zsh -n "$SBX/.zshrc" \
            && chk assert_equals "parses" "parses" "adopted rc is zsh-clean" \
            || chk assert_equals "parses" "broken" "adopted rc is zsh-clean"
    fi
    _teardown
}

test_near_miss_lines_survive() {
    _setup
    # Same shape, different content: the exact-match strip must not touch it.
    sed -e 's|export NVM_DIR="$HOME/.nvm"|export NVM_DIR="$HOME/.nvm-custom"|' \
        -e 's|eval "$(fnm env)"|eval "$(fnm env --custom)"|' "$SBX/.zshrc" > "$SBX/.zshrc.new" \
        && mv "$SBX/.zshrc.new" "$SBX/.zshrc"
    # A near-miss fnm variant is UNMANAGED config the exact-match strip does
    # not own: the post-strip signature assertion must refuse (fail closed)
    # rather than write a duplicate init alongside it.
    bash "$ROOT_DIR/version-manager.sh" install-fnm >/dev/null 2>&1
    chk assert_not_equals "0" "$?" "near-miss fnm variant refuses the adoption"
    grep -qF 'export NVM_DIR="$HOME/.nvm-custom"' "$SBX/.zshrc" \
        && chk assert_equals "near-miss-kept" "near-miss-kept" "non-exact nvm line survives" \
        || chk assert_equals "near-miss-kept" "eaten" "non-exact nvm line survives"
    grep -qF 'eval "$(fnm env --custom)"' "$SBX/.zshrc" \
        && chk assert_equals "near-miss-fnm-kept" "near-miss-fnm-kept" "non-exact fnm line survives" \
        || chk assert_equals "near-miss-fnm-kept" "eaten" "non-exact fnm line survives"
    ! grep -q 'BEGIN version-management-setup:version-manager-fnm' "$SBX/.zshrc" \
        && chk assert_equals "no-block" "no-block" "no managed block written on refusal" \
        || chk assert_equals "no-block" "written" "no managed block written on refusal"
    _teardown
}

# chk: executor-style (assert function name first), TH-2-accounted.
FAILURES=0
chk() { "$@" || FAILURES=$((FAILURES + 1)); }
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
run_case adopt-strips test_adopt_strips_dead_wiring || failures=$((failures + 1))
run_case live-nvm-kept test_live_nvm_preserved || failures=$((failures + 1))
run_case dry-run test_dry_run_zero_writes || failures=$((failures + 1))
run_case injected-rollback test_injected_failure_rolls_back || failures=$((failures + 1))
run_case near-miss test_near_miss_lines_survive || failures=$((failures + 1))
run_case manager-set test_pyenv_rbenv_phpenv_adoption || failures=$((failures + 1))

if [[ "$failures" -gt 0 || "$FAILURES" -gt 0 ]]; then
    echo "test_node_wiring_managed.sh: $failures case(s) failed, $FAILURES assertion(s) failed"
    exit 1
fi
