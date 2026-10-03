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
# Scope guard: /etc/shells and chsh paths are pre-existing gated surfaces
# (confirm prompt + backup, landed by earlier remediation) and are
# deliberately NOT exercised here.
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
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
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

if [[ "$failures" -gt 0 ]]; then
    echo "test_fix_terminal_managed.sh: $failures case(s) failed"
    exit 1
fi
