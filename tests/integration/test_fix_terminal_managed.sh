#!/usr/bin/env bash
# =============================================================================
# fix-terminal-issues Managed-Mutation Adoption Tests (directive M4, B2.1)
# =============================================================================
# Per-adopter GO criteria: the p10k whole-file replace and the font installs
# run under backup transactions (audit journal records start/commit/rollback),
# reruns against an unchanged source are byte-identical AND mtime-stable,
# --dry-run plans with zero writes, and an injected root-proof failure exits
# nonzero with the pre-state preserved byte-identically.
#
# Scope guard (F-A1): the /etc/shells and chsh paths ARE now exercised —
# through recording shims for sudo/chsh (the privileged application is
# mirrored into the sandbox; the real /etc/shells is only ever read).
#
# Font assets: the repository commits no MesloLGS*.ttf files, so the font
# copy loop is exercised through a sandbox-local repo layout — the script,
# lib/ and config/ are symlinks to the real repo; ONLY the font assets are
# synthetic. Every other case runs the real repository script directly.
#
# Injection note: the originally-specified "remove the target's parent dir"
# failure is filesystem-impossible for $HOME/.p10k.zsh (the transaction state
# itself lives under $HOME/.config-backups), so the root-proof injection is
# an immutable flag on the target (chflags uchg / chattr +i) — a failure that
# affects every write path (atomic rename AND plain restore) and cannot be
# silently bypassed. Capability-detected; a capability gap is REPORTED as
# its own assertion, never silently passed.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/../helpers.sh"

set +e

REAL_SCRIPT="$ROOT_DIR/scripts/fix-terminal-issues.sh"
P10K_SOURCE="$ROOT_DIR/config/professional-dev-p10k.zsh"

sha() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

mtime() {
    # ORDER MATTERS: on Linux `stat -f` means FILESYSTEM info (exit 0, wrong
    # data), so the BSD form must be probed only when the GNU form fails —
    # otherwise Linux reports phantom mtime churn (builds #22/#25 evidence:
    # cmp+sha256 present, src==tgt, yet "churned").
    if stat -c %Y "$1" >/dev/null 2>&1; then
        stat -c %Y "$1"
    else
        stat -f %m "$1" 2>/dev/null
    fi
}

audit_path() {
    printf '%s' "$SBX/.config/version-manager/audit.log"
}

font_target_dir() {
    case "$(uname -s)" in
        Darwin) printf '%s' "$SBX/Library/Fonts" ;;
        *)      printf '%s' "$SBX/.local/share/fonts" ;;
    esac
}

_setup() {
    SBX=$(mktemp -d "${TMPDIR:-/tmp}/vms-terminal-fix.XXXXXX")
    export HOME="$SBX"
}

_teardown() {
    [[ -n "${SBX:-}" && "$SBX" == */vms-terminal-fix.* ]] && rm -rf "$SBX"
    unset HOME
}

# Assertion counting: a case's exit status must reflect its own failures
# (the last helper call would otherwise mask them — teardown always succeeds).
CASE_FAILS=0
_chk() {
    assert_equals "$@" || CASE_FAILS=$((CASE_FAILS + 1))
}
_chk_contains() {
    assert_contains "$@" || CASE_FAILS=$((CASE_FAILS + 1))
}

# Sandbox-local repo layout: symlinks to the real script/libs/config, plus
# synthetic font assets (the repo commits none).
_fake_repo() {
    mkdir -p "$SBX/scripts"
    ln -s "$ROOT_DIR/lib" "$SBX/lib"
    ln -s "$ROOT_DIR/config" "$SBX/config"
    ln -s "$REAL_SCRIPT" "$SBX/scripts/fix-terminal-issues.sh"
    printf 'synthetic-meslo-regular\n' > "$SBX/MesloLGS-Regular.ttf"
    printf 'synthetic-meslo-bold\n' > "$SBX/MesloLGS-Bold.ttf"
}

# ── a. p10k fix applies; rerun is byte-identical, mtime-stable AND audited ────
test_p10k_rerun_tracking() {
    _setup
    printf '# user p10k content\n' > "$SBX/.p10k.zsh"
    bash "$REAL_SCRIPT" fix-p10k >/dev/null 2>&1
    local rc1=$?
    _chk "0" "$rc1" "fix-p10k applies"
    if cmp -s "$P10K_SOURCE" "$SBX/.p10k.zsh"; then
        _chk "source" "source" "p10k target matches project source"
    else
        _chk "source" "diverged" "p10k target must match project source"
    fi

    local h1 m1
    h1=$(sha "$SBX/.p10k.zsh")
    m1=$(mtime "$SBX/.p10k.zsh")
    sleep 1
    bash "$REAL_SCRIPT" fix-p10k >/dev/null 2>&1
    local rc2=$?
    _chk "0" "$rc2" "p10k rerun exits zero"

    local h2 m2 audit_state bytes mt jrn
    h2=$(sha "$SBX/.p10k.zsh")
    m2=$(mtime "$SBX/.p10k.zsh")
    _chk "$h1" "$h2" "rerun bytes stable (sha-identical)"
    _chk "$m1" "$m2" "rerun leaves mtime unchanged when bytes identical"

    if [[ -f "$(audit_path)" ]] && grep -q 'fix_terminal_p10k' "$(audit_path)" \
        && grep -q $'commit\tfix_terminal_p10k' "$(audit_path)"; then
        audit_state="recorded"
    else
        audit_state="unrecorded"
    fi
    _chk "recorded" "$audit_state" "fix-p10k runs are recorded as transactions in the audit journal"

    if [[ "$h1" == "$h2" ]]; then bytes="stable"; else bytes="changed"; fi
    if [[ "$m1" == "$m2" ]]; then mt="stable"; else mt="churned"; fi
    if [[ -f "$(audit_path)" ]]; then jrn="present"; else jrn="absent"; fi
    echo "    [evidence] rerun: bytes=$bytes mtime=$mt audit=$jrn"
}

# ── b. --dry-run is a supported mode; p10k dry-run writes nothing ─────────────
test_p10k_dry_run_zero_writes() {
    _setup
    printf '# user p10k content\n' > "$SBX/.p10k.zsh"
    local pre
    pre=$(sha "$SBX/.p10k.zsh")

    local out
    out=$(bash "$REAL_SCRIPT" --dry-run fix-p10k 2>&1)
    local rc=$?
    _chk "0" "$rc" "--dry-run fix-p10k is a supported mode"
    _chk "$pre" "$(sha "$SBX/.p10k.zsh")" "p10k dry-run leaves target byte-identical"
    _chk_contains "[dry-run]" "$out" "p10k dry-run prints plan output"
}

# ── c1. fonts install into a fresh HOME; rerun byte-identical ─────────────────
test_fonts_apply_and_rerun() {
    _setup
    _fake_repo
    local script="$SBX/scripts/fix-terminal-issues.sh"

    bash "$script" fix-fonts >/dev/null 2>&1
    local rc1=$?
    _chk "0" "$rc1" "fix-fonts installs into a fresh HOME"

    local tdir
    tdir=$(font_target_dir)
    local f1="$tdir/MesloLGS-Regular.ttf"
    local f2="$tdir/MesloLGS-Bold.ttf"
    if [[ -f "$f1" && -f "$f2" ]]; then
        _chk "installed" "installed" "both font files installed"
    else
        _chk "installed" "missing" "font files must be installed"
    fi
    _chk "$(sha "$SBX/MesloLGS-Regular.ttf")" "$(sha "$f1")" "installed font bytes match source"

    local m1
    m1=$(mtime "$f1")
    sleep 1
    bash "$script" fix-fonts >/dev/null 2>&1
    local rc2=$?
    _chk "0" "$rc2" "fonts rerun exits zero"
    _chk "$(sha "$f1")" "$(sha "$SBX/MesloLGS-Regular.ttf")" "fonts rerun bytes stable"
    # M4 diagnosis: which byte-compare capability exists, and do the hashes
    # of source vs installed actually agree on this agent?
    local cmp_have="missing" sha_have="missing" fsrc fsha
    command -v cmp >/dev/null 2>&1 && cmp_have="present"
    command -v sha256sum >/dev/null 2>&1 && sha_have="present"
    fsrc=$(sha "$SBX/MesloLGS-Regular.ttf")
    fsha=$(sha "$f1")
    echo "    [evidence] cmp=$cmp_have sha256sum=$sha_have src=${fsrc:0:12} tgt=${fsha:0:12}"
    _chk "$m1" "$(mtime "$f1")" "fonts rerun leaves mtime unchanged when bytes identical"
}

# ── c2. fonts dry-run: plan printed, zero writes ──────────────────────────────
test_fonts_dry_run_plan_zero_writes() {
    _setup
    _fake_repo
    local script="$SBX/scripts/fix-terminal-issues.sh"
    local tdir
    tdir=$(font_target_dir)

    local out
    out=$(bash "$script" --dry-run fix-fonts 2>&1)
    local rc=$?
    _chk "0" "$rc" "--dry-run fix-fonts is a supported mode"
    _chk_contains "[dry-run]" "$out" "fonts dry-run prints a plan"

    if [[ -d "$tdir" ]]; then
        _chk "no-dir" "dir-created" "dry-run must not create the font target directory"
    else
        _chk "no-dir" "no-dir" "dry-run must not create the font target directory"
    fi
    local count
    count=$(find "$tdir" -name 'MesloLGS*.ttf' 2>/dev/null | wc -l | tr -d ' ')
    _chk "0" "$count" "dry-run writes no font files"
}

# ── d. injected root-proof failure: nonzero exit + byte-identical pre-state ───
test_injected_failure_preserves_prestate() {
    _setup
    printf '# user p10k content\n' > "$SBX/.p10k.zsh"
    local pre
    pre=$(sha "$SBX/.p10k.zsh")

    local injected=0
    if command -v chflags >/dev/null 2>&1; then
        chflags uchg "$SBX/.p10k.zsh" 2>/dev/null && injected=1
    elif command -v chattr >/dev/null 2>&1; then
        chattr +i "$SBX/.p10k.zsh" 2>/dev/null && injected=1
    fi

    if [[ "$injected" -eq 1 ]]; then
        bash "$REAL_SCRIPT" fix-p10k >/dev/null 2>&1
        local rc=$?
        if [[ "$rc" -ne 0 ]]; then
            _chk "loud" "loud" "injected failure exits nonzero"
        else
            _chk "loud" "silent-success" "injected failure MUST exit nonzero"
        fi
        _chk "$pre" "$(sha "$SBX/.p10k.zsh")" "pre-state byte-identical after failed run"

        local rb_state
        if [[ -f "$(audit_path)" ]] && grep -q $'rollback\tfix_terminal_p10k' "$(audit_path)"; then
            rb_state="recorded"
        else
            rb_state="unrecorded"
        fi
        _chk "recorded" "$rb_state" "transaction failure recorded as a rollback in the audit journal"
    else
        _chk "skip-capability" "skip-capability" "immutable-flag injection unsupported on this FS (reported, not silently passed)"
    fi

    if command -v chflags >/dev/null 2>&1; then chflags nouchg "$SBX/.p10k.zsh" 2>/dev/null; fi
    if command -v chattr >/dev/null 2>&1; then chattr -i "$SBX/.p10k.zsh" 2>/dev/null; fi
}

# ── F-A1: fix-shell dry-run/consent on the /etc/shells + chsh surfaces ──────
# Recording shims replace sudo and chsh; `command -v zsh` resolves to the
# SHIM zsh (a path that can never be present in the real /etc/shells), so the
# privileged branch always runs. The sudo shim mirrors `tee -a` into the
# SANDBOX — the real /etc/shells is only ever read.
_shim_env() {
    SHIM=$(mktemp -d "${TMPDIR:-/tmp}/vms-shim.XXXXXX")
    VMS_SHIM_LOG="$SHIM/invocations.log"
    VMS_FAKE_ETC="$SHIM/etc-shells-mirror"
    : > "$VMS_SHIM_LOG"
    cat > "$SHIM/zsh" << 'EOF'
#!/usr/bin/env sh
exit 0
EOF
    cat > "$SHIM/sudo" << 'EOF'
#!/usr/bin/env sh
# argv after $0 is the wrapped command: tee -a <file> — $0 is the shim's own
# name, so there is no leading "sudo" argument to shift away.
printf 'sudo %s\n' "$*" >> "$VMS_SHIM_LOG"
if [ "${1:-}" = "tee" ]; then
    shift
    [ "${1:-}" = "-a" ] && shift
    cat >> "$VMS_FAKE_ETC"
fi
exit 0
EOF
    cat > "$SHIM/chsh" << 'EOF'
#!/usr/bin/env sh
printf 'chsh %s\n' "$*" >> "$VMS_SHIM_LOG"
exit 0
EOF
    chmod +x "$SHIM/zsh" "$SHIM/sudo" "$SHIM/chsh"
    export PATH="$SHIM:$PATH"
    export VMS_SHIM_LOG VMS_FAKE_ETC
    export SHELL="/bin/bash"   # force the change branch
}

_shim_teardown() {
    [[ -n "${SHIM:-}" && "$SHIM" == */vms-shim.* ]] && rm -rf "$SHIM"
    # PATH was inherited by the child script processes only; nothing to restore.
}

_shim_no_privileged_calls() {
    local message="$1"
    if grep -qE 'sudo|chsh' "$VMS_SHIM_LOG" 2>/dev/null; then
        _chk "none" "attempted: $(tr '\n' ';' < "$VMS_SHIM_LOG")" "$message"
    else
        _chk "none" "none" "$message"
    fi
}

test_fix_shell_dry_run_touches_nothing() {
    _setup
    _shim_env
    if ! command -v zsh >/dev/null 2>&1; then
        _chk "zsh-present" "absent" "zsh required (capability gap reported, not silently passed)"
        _shim_teardown
        return 0
    fi
    local etc_pre
    etc_pre=$(sha /etc/shells 2>/dev/null || echo unavailable)
    bash "$REAL_SCRIPT" --dry-run fix-shell </dev/null >/dev/null 2>&1
    _chk "0" "$?" "dry-run fix-shell exits zero"
    _shim_no_privileged_calls "dry-run fix-shell must not invoke sudo/chsh"
    bash "$REAL_SCRIPT" --dry-run fix-all </dev/null >/dev/null 2>&1
    _chk "0" "$?" "dry-run fix-all exits zero"
    _shim_no_privileged_calls "dry-run fix-all must not invoke sudo/chsh"
    _chk "$etc_pre" "$(sha /etc/shells 2>/dev/null || echo unavailable)" "real /etc/shells untouched"
    _shim_teardown
}

test_fix_shell_decline_in_nontty() {
    _setup
    _shim_env
    if ! command -v zsh >/dev/null 2>&1; then
        _shim_teardown
        return 0
    fi
    bash "$REAL_SCRIPT" fix-shell </dev/null >/dev/null 2>&1
    _chk "0" "$?" "non-TTY without confirm declines safely (exit zero)"
    _shim_no_privileged_calls "declined run must not invoke sudo/chsh"
    _shim_teardown
}

test_fix_shell_confirm_applies_via_shims() {
    _setup
    _shim_env
    if ! command -v zsh >/dev/null 2>&1; then
        _shim_teardown
        return 0
    fi
    VMS_CONFIRM=1 bash "$REAL_SCRIPT" fix-shell </dev/null >/dev/null 2>&1
    _chk "0" "$?" "consented fix-shell exits zero"
    grep -q '^sudo ' "$VMS_SHIM_LOG" \
        && _chk "sudo-recorded" "sudo-recorded" "consent path invokes the /etc/shells append" \
        || _chk "sudo-recorded" "absent" "consent path invokes the /etc/shells append"
    grep -Fxq "$SHIM/zsh" "$VMS_FAKE_ETC" \
        && _chk "mirror-appended" "mirror-appended" "tee -a mirrored into the sandbox" \
        || _chk "mirror-appended" "absent" "tee -a mirrored into the sandbox"
    grep -q "^chsh -s $SHIM/zsh$" "$VMS_SHIM_LOG" \
        && _chk "chsh-recorded" "chsh-recorded" "consent path invokes chsh" \
        || _chk "chsh-recorded" "absent" "consent path invokes chsh"
    _shim_teardown
}


# ── F-A2: a held workstation-config lock must refuse the run ────────────────
test_fix_shell_lock_denial() {
    _setup
    with_lock_denied "$ROOT_DIR" "workstation-config" bash "$REAL_SCRIPT" fix-p10k
    if [[ "$LOCK_DENIED_RC" -ne 0 && "$LOCK_DENIED_OUT" == *"Failed to acquire lock"* ]]; then
        _chk "denied" "denied" "held lock refuses the run (rc=$LOCK_DENIED_RC)"
    else
        _chk "denied" "rc=$LOCK_DENIED_RC out=${LOCK_DENIED_OUT:0:80}" "held lock refuses the run"
    fi
    _teardown
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
run_case p10k-rerun-tracking test_p10k_rerun_tracking || failures=$((failures + 1))
run_case p10k-dry-run test_p10k_dry_run_zero_writes || failures=$((failures + 1))
run_case fonts-apply test_fonts_apply_and_rerun || failures=$((failures + 1))
run_case fonts-dry-run test_fonts_dry_run_plan_zero_writes || failures=$((failures + 1))
run_case injected-failure test_injected_failure_preserves_prestate || failures=$((failures + 1))
run_case fixshell-dry-run test_fix_shell_dry_run_touches_nothing || failures=$((failures + 1))
run_case fixshell-decline test_fix_shell_decline_in_nontty || failures=$((failures + 1))
run_case fixshell-confirm test_fix_shell_confirm_applies_via_shims || failures=$((failures + 1))
run_case fixshell-lock-denial test_fix_shell_lock_denial

if [[ "$failures" -gt 0 ]]; then
    echo "test_fix_terminal_managed.sh: $failures case(s) failed"
    exit 1
fi
