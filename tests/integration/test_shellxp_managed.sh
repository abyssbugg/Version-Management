#!/usr/bin/env bash
# =============================================================================
# Shell-Experience Managed-Mutation Integration Tests (M5 layer — review finding)
# =============================================================================
# GO criteria, mirroring the per-adopter discipline of test_fix_terminal_managed.sh:
#   - the managed plugins=() editor updates the user's .zshrc array in place
#     (managed block), preserving user entries and non-array content, with a
#     z-syntax-validated result (zsh -n; capability-detected, honestly reported);
#   - zsh-syntax-highlighting is enforced LAST in the array (upstream requirement);
#   - removal and reruns are idempotent: byte-identical AND mtime-stable;
#   - an injected root-proof failure (immutable flag on .zshrc) exits nonzero
#     with the pre-state preserved byte-identically and a rollback recorded in
#     the audit journal;
#   - clone-based plugin installs run against a LOCAL file:// fixture repo ONLY
#     (never the network), fail open on rerun, and NEVER auto-edit plugins=();
#   - dry-run plans write nothing.
#
# Every case runs in a fresh mktemp sandbox as $HOME (never the real HOME).
# Package-manager methods (brew/apt) are covered by fake binaries in the unit
# suite; nothing here invokes a package manager.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/../helpers.sh"

set +e

# shellcheck source=../../lib/shell-experience.sh
source "$ROOT_DIR/lib/shell-experience.sh"

SBX=""
FIXTURE_URL=""

sha() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

mtime() {
    # GNU form first (on Linux `stat -f` is filesystem info, exit 0, wrong data).
    if stat -c %Y "$1" >/dev/null 2>&1; then
        stat -c %Y "$1"
    else
        stat -f %m "$1" 2>/dev/null
    fi
}

audit_path() {
    printf '%s' "$SBX/.config/version-manager/audit.log"
}

_setup() {
    SBX=$(mktemp -d "${TMPDIR:-/tmp}/vms-shellxp-it.XXXXXX")
    export HOME="$SBX"
    unset SHELLXP_CLONE_URL_ZSH_AUTOSUGGESTIONS SHELLXP_CLONE_URL_ZSH_SYNTAX_HIGHLIGHTING \
        SHELLXP_CLONE_COMMIT_ZSH_AUTOSUGGESTIONS SHELLXP_CLONE_COMMIT_ZSH_SYNTAX_HIGHLIGHTING 2>/dev/null
    # Fabricated user .zshrc: content before and after the array, array holds
    # user entries this suite does not own.
    cat > "$SBX/.zshrc" <<'ZSHRC'
# user zshrc header
export EDITOR=vim
plugins=(git
  docker
)
# user footer
alias ll='ls -la'
ZSHRC
}

_teardown() {
    if [[ -n "${SBX:-}" && -f "$SBX/.zshrc" ]]; then
        # Defensive: never leave an immutable flag behind.
        if command -v chflags >/dev/null 2>&1; then chflags nouchg "$SBX/.zshrc" 2>/dev/null; fi
        if command -v chattr >/dev/null 2>&1; then chattr -i "$SBX/.zshrc" 2>/dev/null; fi
    fi
    if [[ -n "${SBX:-}" && "$SBX" == */vms-shellxp-it.* ]]; then
        rm -rf "$SBX"
    fi
    unset HOME
    unset SHELLXP_CLONE_URL_ZSH_AUTOSUGGESTIONS SHELLXP_CLONE_URL_ZSH_SYNTAX_HIGHLIGHTING \
        SHELLXP_CLONE_COMMIT_ZSH_AUTOSUGGESTIONS SHELLXP_CLONE_COMMIT_ZSH_SYNTAX_HIGHLIGHTING 2>/dev/null
    FIXTURE_URL=""
}

CASE_FAILS=0
_chk() {
    assert_equals "$@" || CASE_FAILS=$((CASE_FAILS + 1))
}
_chk_contains() {
    assert_contains "$@" || CASE_FAILS=$((CASE_FAILS + 1))
}

# ── a. plugins_add updates the array; user entries + content preserved; zsh-clean
test_plugins_add_managed() {
    _setup
    local out rc
    out=$(shellxp_plugins_add zsh-autosuggestions 2>&1)
    rc=$?
    _chk "0" "$rc" "shellxp_plugins_add applies in a sandboxed HOME"

    local listed
    listed=$(shellxp_plugins_list)
    _chk_contains "git" "$listed" "user entry 'git' preserved in the managed array"
    _chk_contains "docker" "$listed" "user entry 'docker' preserved in the managed array"
    _chk_contains "zsh-autosuggestions" "$listed" "added entry present in the managed array"

    _chk_contains "export EDITOR=vim" "$(cat "$SBX/.zshrc")" "user content before the array preserved"
    _chk_contains "alias ll='ls -la'" "$(cat "$SBX/.zshrc")" "user content after the array preserved"
    _chk_contains "# BEGIN version-management-setup:plugins-array" "$(cat "$SBX/.zshrc")" \
        "array adopted into a managed block"

    if command -v zsh >/dev/null 2>&1; then
        zsh -n "$SBX/.zshrc" 2>&1
        _chk "0" "$?" "edited .zshrc is zsh-syntax clean (zsh -n)"
    else
        _chk "no-zsh" "no-zsh" "zsh not installed on this agent — syntax gate reported, not silently passed"
    fi

    if [[ -f "$(audit_path)" ]] && grep -q $'commit\tshellxp_plugins' "$(audit_path)"; then
        _chk "recorded" "recorded" "plugins_add runs are recorded as committed transactions"
    else
        _chk "recorded" "unrecorded" "plugins_add runs are recorded as committed transactions"
    fi

    # The clone installer must NEVER auto-activate: with no reachable source
    # (a guaranteed-unreachable LOCAL file:// path — never the network) it
    # fails closed and the rc file is untouched. plugins=() edits are the
    # separate, explicit shellxp_plugins_add step only.
    local pre
    pre=$(sha "$SBX/.zshrc")
    SHELLXP_CLONE_URL_ZSH_AUTOSUGGESTIONS="file://$SBX/no-such-source" \
        shellxp_install zsh-autosuggestions --confirm >/dev/null 2>&1
    rc=$?
    _chk "1" "$rc" "clone install without a reachable source fails closed"
    _chk "$pre" "$(sha "$SBX/.zshrc")" "failed clone install leaves .zshrc byte-identical"
}

# ── b. zsh-syntax-highlighting is enforced LAST in the array ───────────────────
test_syntax_highlighting_last() {
    _setup
    local rc
    shellxp_plugins_add zsh-autosuggestions >/dev/null 2>&1
    shellxp_plugins_add zsh-syntax-highlighting >/dev/null 2>&1
    rc=$?
    _chk "0" "$rc" "adding zsh-syntax-highlighting succeeds"

    local listed
    listed=$(shellxp_plugins_list)
    _chk "zsh-syntax-highlighting" "$(printf '%s\n' "$listed" | tail -1)" \
        "zsh-syntax-highlighting is the LAST entry (upstream requirement)"

    shellxp_plugins_add zoxide >/dev/null 2>&1
    listed=$(shellxp_plugins_list)
    _chk "zsh-syntax-highlighting" "$(printf '%s\n' "$listed" | tail -1)" \
        "a later add does not displace zsh-syntax-highlighting from last place"

    # A user array that already violates the order is canonicalized on add.
    printf 'plugins=(zsh-syntax-highlighting git)\n' > "$SBX/.zshrc"
    shellxp_plugins_add zoxide >/dev/null 2>&1
    listed=$(shellxp_plugins_list)
    _chk "zsh-syntax-highlighting" "$(printf '%s\n' "$listed" | tail -1)" \
        "misordered user array canonicalized on add (syntax-highlighting last)"
    _chk_contains "git" "$listed" "canonicalization preserves user entries"
}

# ── c. remove + idempotent rerun: byte-identical AND mtime-stable ──────────────
test_remove_and_idempotent_rerun() {
    _setup
    shellxp_plugins_add zsh-autosuggestions >/dev/null 2>&1

    # Idempotent add rerun: nothing is rewritten — same bytes, same mtime.
    local h1 m1 h2 m2 h3
    h1=$(sha "$SBX/.zshrc")
    m1=$(mtime "$SBX/.zshrc")
    sleep 1
    shellxp_plugins_add zsh-autosuggestions >/dev/null 2>&1
    _chk "0" "$?" "idempotent add rerun exits zero"
    h2=$(sha "$SBX/.zshrc")
    m2=$(mtime "$SBX/.zshrc")
    _chk "$h1" "$h2" "rerun leaves .zshrc byte-identical (sha-stable)"
    _chk "$m1" "$m2" "rerun leaves mtime unchanged when bytes identical"

    # Removal: entry gone, user entries preserved.
    local rc listed
    shellxp_plugins_remove zsh-autosuggestions >/dev/null 2>&1
    rc=$?
    _chk "0" "$rc" "shellxp_plugins_remove applies"
    listed=$(shellxp_plugins_list)
    if printf '%s\n' "$listed" | grep -qxF "zsh-autosuggestions"; then
        _chk "removed" "still-present" "removed entry is gone from the array"
    else
        _chk "removed" "removed" "removed entry is gone from the array"
    fi
    _chk_contains "git" "$listed" "user entries survive removal"

    # Remove of an absent entry: tolerant no-op (idempotent), no rewrite.
    h3=$(sha "$SBX/.zshrc")
    shellxp_plugins_remove zsh-autosuggestions >/dev/null 2>&1
    _chk "0" "$?" "remove of an absent entry is idempotent (tolerant)"
    _chk "$h3" "$(sha "$SBX/.zshrc")" "tolerant remove leaves .zshrc byte-identical"

    # Removing from a .zshrc with no plugins array at all: tolerant, untouched.
    printf '# no array here\n' > "$SBX/.zshrc"
    local bare
    bare=$(sha "$SBX/.zshrc")
    shellxp_plugins_remove zsh-autosuggestions >/dev/null 2>&1
    _chk "0" "$?" "remove with no array present is a tolerant no-op"
    _chk "$bare" "$(sha "$SBX/.zshrc")" \
        "tolerant remove leaves a non-array .zshrc untouched (no managed block injected)"
}

# ── d. injected root-proof failure: nonzero exit + byte-identical pre-state ────
test_injected_failure_rollback() {
    _setup
    shellxp_plugins_add zsh-autosuggestions >/dev/null 2>&1
    local pre
    pre=$(sha "$SBX/.zshrc")

    local injected=0
    if command -v chflags >/dev/null 2>&1; then
        chflags uchg "$SBX/.zshrc" 2>/dev/null && injected=1
    elif command -v chattr >/dev/null 2>&1; then
        chattr +i "$SBX/.zshrc" 2>/dev/null && injected=1
    fi

    if [[ "$injected" -eq 1 ]]; then
        shellxp_plugins_add zoxide >/dev/null 2>&1
        local rc=$?
        if [[ "$rc" -ne 0 ]]; then
            _chk "loud" "loud" "injected failure exits nonzero"
        else
            _chk "loud" "silent-success" "injected failure MUST exit nonzero"
        fi
        chflags nouchg "$SBX/.zshrc" 2>/dev/null
        chattr -i "$SBX/.zshrc" 2>/dev/null
        _chk "$pre" "$(sha "$SBX/.zshrc")" "pre-state byte-identical after failed run"
        if [[ -f "$(audit_path)" ]] && grep -q $'rollback\tshellxp_plugins' "$(audit_path)"; then
            _chk "recorded" "recorded" "injected failure recorded as a rollback in the audit journal"
        else
            _chk "recorded" "unrecorded" "injected failure recorded as a rollback in the audit journal"
        fi
    else
        _chk "skip-capability" "skip-capability" \
            "immutable-flag injection unsupported on this FS (reported, not silently passed)"
    fi
}

# ── e. clone installs against a LOCAL file:// fixture only; never network ──────
test_clone_local_fixture() {
    _setup
    _chk "0" "$(command -v git >/dev/null 2>&1; echo $?)" "git available for the fixture clone"

    # Local fixture repo (never network): marker file the presence check requires.
    local fix
    fix="$SBX/fixture-src"
    mkdir -p "$fix"
    printf '# synthetic zsh-autosuggestions\n' > "$fix/zsh-autosuggestions.zsh"
    (cd "$fix" && git init -q && git add -A && \
        git -c user.email=vms@test -c user.name=vms commit -qm fixture) >/dev/null 2>&1
    FIXTURE_URL="file://$fix"
    export SHELLXP_CLONE_URL_ZSH_AUTOSUGGESTIONS="$FIXTURE_URL"
    # SC-1: a mirror/fixture must name the exact commit to check out.
    export SHELLXP_CLONE_COMMIT_ZSH_AUTOSUGGESTIONS
    SHELLXP_CLONE_COMMIT_ZSH_AUTOSUGGESTIONS=$(git -C "$fix" rev-parse HEAD)

    local pre out rc
    pre=$(sha "$SBX/.zshrc")
    out=$(shellxp_install zsh-autosuggestions --confirm 2>&1)
    rc=$?
    _chk "0" "$rc" "clone install from a local file:// fixture succeeds"
    if [[ -f "$SBX/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ]]; then
        _chk "present" "present" "cloned plugin directory contains the marker file"
    else
        _chk "present" "absent" "cloned plugin directory contains the marker file"
    fi
    if [[ -f "$(audit_path)" ]] && grep -q "shellxp_clone" "$(audit_path)"; then
        _chk "recorded" "recorded" "clone install journaled (shellxp_clone)"
    else
        _chk "recorded" "unrecorded" "clone install journaled (shellxp_clone)"
    fi
    _chk "$pre" "$(sha "$SBX/.zshrc")" "clone install NEVER auto-edits plugins=()"

    # Rerun: fail-open, no re-clone, still no rc mutation.
    out=$(shellxp_install zsh-autosuggestions --confirm 2>&1)
    rc=$?
    _chk "0" "$rc" "clone rerun fails open"
    _chk_contains "already present" "$out" "clone rerun reports already-present"
    _chk "$pre" "$(sha "$SBX/.zshrc")" "clone rerun leaves .zshrc byte-identical"

    # Activation is a separate explicit step; status reflects both dimensions.
    shellxp_plugins_add zsh-autosuggestions >/dev/null 2>&1
    out=$(shellxp_status 2>/dev/null)
    _chk_contains "zsh-autosuggestions: present (activated in plugins=())" "$out" \
        "status reports the cloned tool as present and activated"
    _chk_contains "fzf: missing" "$out" "status reports uninstalled tools as missing"

    # Unknown/unreachable source for a tool that is NOT yet installed:
    # fail closed, no target, transaction rolls back. (zsh-autosuggestions is
    # already installed by the successful clone above and would fail open
    # before any URL is consulted — the wrong subject for this assertion.)
    export SHELLXP_CLONE_URL_ZSH_SYNTAX_HIGHLIGHTING="file://$SBX/does-not-exist"
    shellxp_install zsh-syntax-highlighting --confirm >/dev/null 2>&1
    rc=$?
    _chk "1" "$rc" "unreachable clone source fails closed (nonzero)"
    if [[ -d "$SBX/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting" ]]; then
        _chk "absent" "created" "failed clone run leaves no partial target directory"
    else
        _chk "absent" "absent" "failed clone run leaves no partial target directory"
    fi
}

# ── f. dry-run plans: zero writes across both surfaces ─────────────────────────
test_dry_run_zero_writes() {
    _setup
    local out rc pre
    pre=$(sha "$SBX/.zshrc")

    out=$(shellxp_plugins_add zsh-autosuggestions --dry-run 2>&1)
    rc=$?
    _chk "0" "$rc" "plugins add --dry-run exits zero"
    _chk_contains "[dry-run]" "$out" "plugins add --dry-run prints a plan"
    _chk "$pre" "$(sha "$SBX/.zshrc")" "plugins add --dry-run leaves .zshrc byte-identical"

    out=$(shellxp_install fzf 2>&1)
    rc=$?
    _chk "0" "$rc" "install plan-by-default exits zero"
    _chk_contains "[plan]" "$out" "install plan-by-default prints a plan"
    if [[ -d "$SBX/.config-backups" ]]; then
        _chk "no-txn" "txn-created" "plan mode must not create transaction state"
    else
        _chk "no-txn" "no-txn" "plan mode must not create transaction state"
    fi
    _chk "$pre" "$(sha "$SBX/.zshrc")" "plan mode leaves .zshrc byte-identical"
}

# ── g. F7: a clone never joins a caller-owned transaction ──────────────────────
# The file-level transaction cannot remove a directory on rollback, so a
# clone registered inside a CALLER's transaction left the plugin directory
# behind and made the caller's rollback fail (rc=1). Refuse instead.
_make_fixture_repo() {
    # Two commits; the marker exists in both. Prints nothing; sets FIX_FIRST/FIX_HEAD.
    local fix="$1"
    mkdir -p "$fix"
    printf '# synthetic zsh-autosuggestions v1\n' > "$fix/zsh-autosuggestions.zsh"
    (cd "$fix" && git init -q && git add -A && \
        git -c user.email=vms@test -c user.name=vms commit -qm one) >/dev/null 2>&1
    FIX_FIRST=$(git -C "$fix" rev-parse HEAD)
    printf '# synthetic zsh-autosuggestions v2 (unreviewed)\n' > "$fix/zsh-autosuggestions.zsh"
    (cd "$fix" && git add -A && \
        git -c user.email=vms@test -c user.name=vms commit -qm two) >/dev/null 2>&1
    FIX_HEAD=$(git -C "$fix" rev-parse HEAD)
}

test_clone_refused_in_caller_transaction() {
    _setup
    local fix="$SBX/fixture-src" target rc
    _make_fixture_repo "$fix"
    export SHELLXP_CLONE_URL_ZSH_AUTOSUGGESTIONS="file://$fix"
    export SHELLXP_CLONE_COMMIT_ZSH_AUTOSUGGESTIONS="$FIX_HEAD"
    target="$SBX/.oh-my-zsh/custom/plugins/zsh-autosuggestions"

    transaction_start outer_caller >/dev/null 2>&1
    shellxp_install zsh-autosuggestions --confirm >/dev/null 2>&1
    rc=$?
    _chk "1" "$rc" "clone install inside a caller-owned transaction is refused"
    if [[ -e "$target" ]]; then
        _chk "absent" "created" "refused clone creates no plugin directory"
    else
        _chk "absent" "absent" "refused clone creates no plugin directory"
    fi
    transaction_rollback >/dev/null 2>&1
    rc=$?
    _chk "0" "$rc" "the caller's rollback stays clean"
    if [[ -e "$target" ]]; then
        _chk "absent" "left-behind" "no directory survives the caller's rollback"
    else
        _chk "absent" "absent" "no directory survives the caller's rollback"
    fi
    unset SHELLXP_CLONE_COMMIT_ZSH_AUTOSUGGESTIONS
}

# ── h. SC-1: clones check out the reviewed commit, never the branch tip ───────
test_clone_checks_out_pinned_commit() {
    _setup
    local fix="$SBX/fixture-src" target rc
    _make_fixture_repo "$fix"
    export SHELLXP_CLONE_URL_ZSH_AUTOSUGGESTIONS="file://$fix"
    target="$SBX/.oh-my-zsh/custom/plugins/zsh-autosuggestions"

    # A commit absent from the source fails closed (the default pin is not in
    # this local fixture) — nothing is left behind.
    unset SHELLXP_CLONE_COMMIT_ZSH_AUTOSUGGESTIONS
    shellxp_install zsh-autosuggestions --confirm >/dev/null 2>&1
    rc=$?
    _chk "1" "$rc" "a source lacking the pinned commit fails closed"
    _chk "absent" "$([[ -e "$target" ]] && echo present || echo absent)" "no target after a missing pin"

    # A branch/tag name is not a pin.
    export SHELLXP_CLONE_COMMIT_ZSH_AUTOSUGGESTIONS="master"
    shellxp_install zsh-autosuggestions --confirm >/dev/null 2>&1
    rc=$?
    _chk "1" "$rc" "a non-SHA commit override is refused"
    _chk "absent" "$([[ -e "$target" ]] && echo present || echo absent)" "no target after a refused override"

    # Pinned to the FIRST commit: that exact commit is installed even though
    # the source's branch tip has moved on.
    export SHELLXP_CLONE_COMMIT_ZSH_AUTOSUGGESTIONS="$FIX_FIRST"
    shellxp_install zsh-autosuggestions --confirm >/dev/null 2>&1
    rc=$?
    _chk "0" "$rc" "install at the pinned commit succeeds"
    _chk "$FIX_FIRST" "$(git -C "$target" rev-parse HEAD 2>/dev/null)" "installed HEAD equals the pin, not the branch tip"
    _chk_contains "v1" "$(cat "$target/zsh-autosuggestions.zsh" 2>/dev/null)" "installed content is the pinned revision"
    if [[ -f "$(audit_path)" ]] && grep -q "head=${FIX_FIRST:0:12}" "$(audit_path)"; then
        _chk "recorded" "recorded" "journal records the pinned head"
    else
        _chk "recorded" "unrecorded" "journal records the pinned head"
    fi
    unset SHELLXP_CLONE_COMMIT_ZSH_AUTOSUGGESTIONS
}

# Case runner: fresh failure counter, guaranteed teardown, honest exit status.
run_case() {
    local name="$1"
    shift
    CASE_FAILS=0
    "$@"
    local failed=$CASE_FAILS
    _teardown
    if [[ "$failed" -gt 0 ]]; then
        echo "    [case $name] $failed assertion(s) failed"
        return 1
    fi
    return 0
}

failures=0
run_case plugins-add-managed test_plugins_add_managed || failures=$((failures + 1))
run_case syntax-highlighting-last test_syntax_highlighting_last || failures=$((failures + 1))
run_case remove-and-idempotent test_remove_and_idempotent_rerun || failures=$((failures + 1))
run_case injected-failure test_injected_failure_rollback || failures=$((failures + 1))
run_case clone-local-fixture test_clone_local_fixture || failures=$((failures + 1))
run_case dry-run-zero-writes test_dry_run_zero_writes || failures=$((failures + 1))
run_case clone-refused-in-caller-txn test_clone_refused_in_caller_transaction || failures=$((failures + 1))
run_case clone-pinned-commit test_clone_checks_out_pinned_commit || failures=$((failures + 1))

if [[ "$failures" -gt 0 ]]; then
    echo "test_shellxp_managed.sh: $failures case(s) failed"
    exit 1
fi
