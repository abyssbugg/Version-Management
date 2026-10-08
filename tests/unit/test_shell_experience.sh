#!/usr/bin/env bash
# =============================================================================
# Shell-Experience Library Unit Tests (M5 layer — review finding)
# =============================================================================
# Red-state contract (TDD): before lib/shell-experience.sh existed the suite
# had NO shell-experience provisioning or plugins=() management — these tests
# assert the CONTRACT (functions exist, plans are printed, zero writes in
# plan/dry-run modes, already-present fail-open, sudo gate behavior), which
# was red against the pre-existing tree by absence.
#
# Scope: registry completeness, plan-by-default / --dry-run zero-writes,
# already-present fail-open, the /etc/shells-pattern confirm gate for the
# apt (sudo) method, and transaction-level dry-run. All package-manager
# invocations run against FAKE brew/apt-get/sudo binaries on PATH — never a
# real package manager, never the network. Clone installs against network
# are out of scope here: the integration suite covers clones with a local
# file:// fixture only.
# =============================================================================

source ../helpers.sh

set +e

ROOT_DIR="$(cd "$(pwd)/../.." && pwd)"
# shellcheck source=../../lib/shell-experience.sh
source "$ROOT_DIR/lib/shell-experience.sh"

CASE_FAILS=0
_chk() {
    assert_equals "$@" || CASE_FAILS=$((CASE_FAILS + 1))
}
_chk_contains() {
    assert_contains "$@" || CASE_FAILS=$((CASE_FAILS + 1))
}

SBX=""
_setup() {
    SBX=$(mktemp -d "${TMPDIR:-/tmp}/vms-shellxp-unit.XXXXXX")
    export HOME="$SBX"
    mkdir -p "$SBX/bin"
    : > "$SBX/.pkglog"
    unset SHELLXP_CLONE_URL_ZSH_AUTOSUGGESTIONS SHELLXP_CLONE_URL_ZSH_SYNTAX_HIGHLIGHTING \
        SHELLXP_ZSHRC ZSH_CUSTOM TRANSACTION_DRY_RUN 2>/dev/null
    true
}

_teardown() {
    if [[ -n "${SBX:-}" && "$SBX" == */vms-shellxp-unit.* ]]; then
        rm -rf "$SBX"
    fi
    unset HOME
}

_fake_pkg_manager() {
    # Fake sudo: pass through. Fake apt-get: record and stub the binary.
    # Fake brew: record and stub the binary. PATH must have $SBX/bin first.
    cat > "$SBX/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
exec "$@"
SUDO
    cat > "$SBX/bin/apt-get" <<'APT'
#!/usr/bin/env bash
echo "apt-get $*" >> "$PKGLOG"
pkg="${!#}"
touch "$BINDIR/$pkg"
exit 0
APT
    cat > "$SBX/bin/brew" <<'BREW'
#!/usr/bin/env bash
echo "brew $*" >> "$PKGLOG"
pkg="${2:-}"
touch "$BINDIR/$pkg"
exit 0
BREW
    chmod +x "$SBX/bin/sudo" "$SBX/bin/apt-get" "$SBX/bin/brew"
    export PKGLOG="$SBX/.pkglog"
    export BINDIR="$SBX/bin"
    export PATH="$SBX/bin:$PATH"
}

# ── 1. Registry completeness: every tool registered with a per-platform method ─
test_registry_completeness() {
    _setup
    local expected=9 count
    count=$(shellxp_list_tools | wc -l | tr -d ' ')
    _chk "$expected" "$count" "registry lists exactly 9 tools"

    local tool spec ok=0
    while IFS= read -r tool; do
        spec=$(shellxp_registry_lookup "$tool")
        if [[ "$spec" == clone:* || "$spec" == brew:* || "$spec" == apt:* ]]; then
            ok=$((ok + 1))
        else
            _chk "registered" "unregistered" "tool '$tool' has a method:spec entry"
        fi
        case "$spec" in
            clone:*) _chk_contains "https://" "$spec" "clone tool '$tool' uses an https upstream URL (never curl|bash)" ;;
        esac
    done <<< "$(shellxp_list_tools)"
    _chk "9" "$ok" "all 9 registry entries resolve to a valid method"

    if shellxp_registry_lookup not-a-tool >/dev/null 2>&1; then
        _chk "red" "green" "unknown tool fails closed"
    else
        _chk "red" "red" "unknown tool fails closed"
    fi
    _chk_contains "zsh" "$(shellxp_tool_marker zsh-autosuggestions)" "clone tool has a marker file"
    _chk_contains "rg" "$(shellxp_tool_binaries ripgrep)" "ripgrep detects its rg binary"
}

# ── 2. Plan-by-default: plan printed, ZERO writes ──────────────────────────────
test_plan_by_default_zero_writes() {
    _setup
    local out rc
    out=$(shellxp_install fzf 2>&1)
    rc=$?
    _chk "0" "$rc" "shellxp_install without --confirm plans and exits zero (P0-6)"
    _chk_contains "[plan]" "$out" "default mode prints a [plan]"
    _chk_contains "package: fzf" "$out" "plan names the package"

    if [[ -d "$SBX/.oh-my-zsh" || -d "$SBX/.config-backups" ]]; then
        _chk "no-writes" "wrote" "plan mode performs zero filesystem writes"
    else
        _chk "no-writes" "no-writes" "plan mode performs zero filesystem writes"
    fi

    # --dry-run prints the same plan tagged [dry-run], also zero writes.
    out=$(shellxp_install zsh-autosuggestions --dry-run 2>&1)
    rc=$?
    _chk "0" "$rc" "--dry-run exits zero"
    _chk_contains "[dry-run]" "$out" "--dry-run prints a [dry-run] plan"
    _chk_contains "git clone" "$out" "clone plan describes the git-clone method"
    if [[ -d "$SBX/.oh-my-zsh" ]]; then
        _chk "no-writes" "wrote" "clone dry-run must not create the plugin root"
    else
        _chk "no-writes" "no-writes" "clone dry-run must not create the plugin root"
    fi
}

# ── 3. Already-present fail-open (package binary and clone both) ───────────────
test_already_present_fail_open() {
    _setup
    local out rc
    _fake_pkg_manager
    # Fake the tool's presence directly: a binary on PATH.
    touch "$SBX/bin/fzf" && chmod +x "$SBX/bin/fzf"

    out=$(shellxp_install fzf --confirm 2>&1)
    rc=$?
    _chk "0" "$rc" "already-installed tool fails open (exit zero, nothing done)"
    _chk_contains "already present" "$out" "fail-open reports 'already present'"
    if grep -q "brew install fzf" "$SBX/.pkglog" 2>/dev/null; then
        _chk "no-install" "installed" "fail-open must not invoke the package manager"
    else
        _chk "no-install" "no-install" "fail-open must not invoke the package manager"
    fi

    # Clone tool present (marker + .git): fail-open too.
    local pdir
    pdir="$(shellxp_plugins_root)/zsh-syntax-highlighting"
    mkdir -p "$pdir/.git"
    printf '# plugin\n' > "$pdir/zsh-syntax-highlighting.zsh"
    out=$(shellxp_install zsh-syntax-highlighting --confirm 2>&1)
    rc=$?
    _chk "0" "$rc" "already-cloned plugin fails open (exit zero)"
    _chk_contains "already present" "$out" "clone fail-open reports 'already present'"
}

# ── 4. apt (sudo) confirm gate — exact /etc/shells pattern ─────────────────────
test_apt_confirm_gate() {
    _setup
    _fake_pkg_manager
    local out rc

    # Non-interactive without VMS_CONFIRM: refuse loudly, install nothing.
    out=$(VMS_CONFIRM='' _shellxp_apply_apt direnv direnv </dev/null 2>&1)
    rc=$?
    _chk "1" "$rc" "apt apply without confirmation refuses (nonzero)"
    _chk_contains "Confirmation required" "$out" "refusal names the confirmation requirement"
    _chk_contains "VMS_CONFIRM=1" "$out" "refusal points at --confirm / VMS_CONFIRM=1"
    if [[ -e "$SBX/bin/direnv" ]]; then
        _chk "no-install" "installed" "refused apply must not install"
    else
        _chk "no-install" "no-install" "refused apply must not install"
    fi

    # VMS_CONFIRM=1 passes the gate; fake apt-get records and stubs the binary.
    out=$(VMS_CONFIRM=1 _shellxp_apply_apt direnv direnv 2>&1)
    rc=$?
    _chk "0" "$rc" "apt apply with VMS_CONFIRM=1 proceeds"
    _chk_contains "apt-get install -y direnv" "$(cat "$SBX/.pkglog")" "apt apply invokes apt-get install -y"
    if [[ -e "$SBX/bin/direnv" ]]; then
        _chk "produced" "produced" "apt apply produces the tool binary"
    else
        _chk "produced" "absent" "apt apply produces the tool binary"
    fi

    # brew branch: user-level, gate is plan/--confirm only (no sudo prompt).
    out=$(_shellxp_apply_brew fzf fzf 2>&1)
    rc=$?
    _chk "0" "$rc" "brew apply proceeds (user-level method)"
    _chk_contains "brew install fzf" "$(cat "$SBX/.pkglog")" "brew apply invokes brew install"
}

# ── 5. TRANSACTION_DRY_RUN=1 with --confirm stays plan-only ────────────────────
test_transaction_dry_run_plan_only() {
    _setup
    _fake_pkg_manager
    local out rc
    out=$(TRANSACTION_DRY_RUN=1 shellxp_install fzf --confirm 2>&1)
    rc=$?
    _chk "0" "$rc" "transaction-level dry-run exits zero"
    _chk_contains "[dry-run]" "$out" "transaction-level dry-run prints a [dry-run] plan"
    if [[ -e "$SBX/bin/fzf" ]]; then
        _chk "no-install" "installed" "transaction-level dry-run must not install"
    else
        _chk "no-install" "no-install" "transaction-level dry-run must not install"
    fi
    if [[ -d "$SBX/.config-backups" ]]; then
        _chk "no-txn-dirs" "txn-dirs" "transaction-level dry-run must not create transaction state"
    else
        _chk "no-txn-dirs" "no-txn-dirs" "transaction-level dry-run must not create transaction state"
    fi
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
run_case registry-completeness test_registry_completeness || failures=$((failures + 1))
run_case plan-by-default test_plan_by_default_zero_writes || failures=$((failures + 1))
run_case already-present-fail-open test_already_present_fail_open || failures=$((failures + 1))
run_case apt-confirm-gate test_apt_confirm_gate || failures=$((failures + 1))
run_case transaction-dry-run test_transaction_dry_run_plan_only || failures=$((failures + 1))

if [[ "$failures" -gt 0 ]]; then
    echo "test_shell_experience.sh: $failures case(s) failed"
    exit 1
fi
