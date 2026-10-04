#!/usr/bin/env bash
# =============================================================================
# setup-fonts-enhanced Managed-Mutation Adoption Tests (directive M4, P3-1)
# =============================================================================
# Per-adopter GO criteria: the local font file copies (macOS ~/Library/Fonts,
# Linux ~/.local/share/fonts) run under backup transactions (audit journal
# records start/commit/rollback), reruns against unchanged sources are
# byte-identical AND mtime-stable, --dry-run plans with zero writes, and an
# injected root-proof failure exits nonzero with the pre-state preserved
# byte-identically.
#
# Scope guard: the oh-my-posh and Homebrew cask paths are EXTERNAL network
# installers — deliberately NOT wrapped in transactions (no local files are
# mutated by them); they are only exercised as plan-only under --dry-run.
# Menu option 4 delegates to scripts/patch-font.sh (a separate registry
# entry) and is out of scope here.
#
# Font assets: the repository commits no font files, so the font copy loop is
# exercised through a sandbox-local repo layout — the script and lib/ are
# symlinks to the real repo; ONLY the font assets are synthetic .ttf files
# (named exactly as the script's font_files array expects, spaces included).
#
# Injection note: the failure injection is an immutable flag on the target
# font (chflags uchg / chattr +i) — a failure that affects every write path
# (atomic rename AND plain restore) and cannot be silently bypassed, even by
# root. Capability-detected; a capability gap is REPORTED as its own
# assertion, never silently passed.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/../helpers.sh"

set +e

REAL_SCRIPT="$ROOT_DIR/setup-fonts-enhanced.sh"

sha() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

mtime() {
    # ORDER MATTERS: on Linux `stat -f` means FILESYSTEM info (exit 0, wrong
    # data), so the GNU form must be probed first — otherwise Linux reports
    # phantom mtime churn (builds #22/#25 evidence).
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
    SBX=$(mktemp -d "${TMPDIR:-/tmp}/vms-fonts-fix.XXXXXX")
    export HOME="$SBX"
}

_teardown() {
    # Immutable flags would break rm -rf — clear defensively on every sandbox
    # file before removal so /tmp is never littered (M4 lesson).
    if command -v chflags >/dev/null 2>&1; then
        find "$SBX" -type f -exec chflags nouchg {} + 2>/dev/null
    fi
    if command -v chattr >/dev/null 2>&1; then
        find "$SBX" -type f -exec chattr -i {} + 2>/dev/null
    fi
    [[ -n "${SBX:-}" && "$SBX" == */vms-fonts-fix.* ]] && rm -rf "$SBX"
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

# Sandbox-local repo layout: the script + lib are symlinks to the real repo
# (SCRIPT_DIR resolves to the sandbox root), plus synthetic font assets with
# the exact names the script's font_files array expects (spaces included).
_fake_repo() {
    ln -s "$ROOT_DIR/lib" "$SBX/lib"
    ln -s "$REAL_SCRIPT" "$SBX/setup-fonts-enhanced.sh"
    printf 'synthetic-meslo-regular\n' > "$SBX/MesloLGS NF Regular.ttf"
    printf 'synthetic-meslo-bold\n' > "$SBX/MesloLGS NF Bold.ttf"
    printf 'synthetic-meslo-italic\n' > "$SBX/MesloLGS NF Italic.ttf"
    printf 'synthetic-meslo-bold-italic\n' > "$SBX/MesloLGS NF Bold Italic.ttf"
}

_place_user_font() {
    # A different-content pre-existing font the user would lose to a bare cp.
    local tdir
    tdir=$(font_target_dir)
    mkdir -p "$tdir"
    printf 'USER-OWNED meslo content\n' > "$tdir/MesloLGS NF Regular.ttf"
}

# ── a+b. first install writes fonts; rerun byte-identical + audited ──────────
test_fonts_apply_and_rerun() {
    _setup
    _fake_repo
    local script="$SBX/setup-fonts-enhanced.sh"

    bash "$script" fonts < /dev/null > /dev/null 2>&1
    local rc1=$?
    _chk "0" "$rc1" "fonts install applies into a fresh HOME"

    local tdir
    tdir=$(font_target_dir)
    local f1="$tdir/MesloLGS NF Regular.ttf"
    local f2="$tdir/MesloLGS NF Bold.ttf"
    local f3="$tdir/MesloLGS NF Italic.ttf"
    local f4="$tdir/MesloLGS NF Bold Italic.ttf"
    if [[ -f "$f1" && -f "$f2" && -f "$f3" && -f "$f4" ]]; then
        _chk "installed" "installed" "all four font files installed"
    else
        _chk "installed" "missing" "all four font files must be installed"
    fi
    _chk "$(sha "$SBX/MesloLGS NF Regular.ttf")" "$(sha "$f1")" "installed font bytes match source"

    local m1
    m1=$(mtime "$f1")
    sleep 1
    bash "$script" fonts < /dev/null > /dev/null 2>&1
    local rc2=$?
    _chk "0" "$rc2" "fonts rerun exits zero"
    _chk "$(sha "$f1")" "$(sha "$SBX/MesloLGS NF Regular.ttf")" "fonts rerun bytes stable"
    _chk "$m1" "$(mtime "$f1")" "fonts rerun leaves mtime unchanged when bytes identical"

    local audit_state
    if [[ -f "$(audit_path)" ]] && grep -q $'commit\tfonts_enhanced' "$(audit_path)"; then
        audit_state="recorded"
    else
        audit_state="unrecorded"
    fi
    _chk "recorded" "$audit_state" "fonts runs are recorded as transactions in the audit journal"

    if [[ "$rc1" == "0" && "$rc2" == "0" ]]; then rc="ok"; else rc="failed"; fi
    if [[ "$m1" == "$(mtime "$f1")" ]]; then mt="stable"; else mt="churned"; fi
    echo "    [evidence] runs=$rc rerun-mtime=$mt audit=$audit_state"
}

# ── (a). overwrite of a different-content font leaves a backup record ────────
test_fonts_overwrite_recorded() {
    _setup
    _fake_repo
    _place_user_font
    local script="$SBX/setup-fonts-enhanced.sh"
    local tdir target
    tdir=$(font_target_dir)
    target="$tdir/MesloLGS NF Regular.ttf"

    bash "$script" fonts < /dev/null > /dev/null 2>&1
    local rc=$?
    _chk "0" "$rc" "fonts install over an existing different-content font applies"
    _chk "$(sha "$SBX/MesloLGS NF Regular.ttf")" "$(sha "$target")" "overwritten target matches source"

    local audit_state
    if [[ -f "$(audit_path)" ]] && grep -q $'start\tfonts_enhanced' "$(audit_path)" \
        && grep -q $'commit\tfonts_enhanced' "$(audit_path)"; then
        audit_state="recorded"
    else
        audit_state="unrecorded"
    fi
    _chk "recorded" "$audit_state" "overwrite of an existing font is recorded as a backed-up transaction"
}

# ── (c). --dry-run is a supported mode; fonts dry-run writes nothing ─────────
test_fonts_dry_run_plan_zero_writes() {
    _setup
    _fake_repo
    _place_user_font
    local script="$SBX/setup-fonts-enhanced.sh"
    local tdir target pre_custom
    tdir=$(font_target_dir)
    target="$tdir/MesloLGS NF Regular.ttf"
    pre_custom=$(sha "$target")

    local out
    out=$(bash "$script" --dry-run fonts < /dev/null 2>&1)
    local rc=$?
    _chk "0" "$rc" "--dry-run fonts is a supported mode"
    _chk_contains "[dry-run]" "$out" "fonts dry-run prints a plan"
    _chk "$pre_custom" "$(sha "$target")" "fonts dry-run leaves an existing target byte-identical"

    local count
    count=$(find "$tdir" -name 'MesloLGS*' 2>/dev/null | wc -l | tr -d ' ')
    _chk "1" "$count" "dry-run writes no additional font files (only the pre-existing one)"
}

# ── d. injected root-proof failure: nonzero exit + byte-identical pre-state ──
test_injected_failure_preserves_prestate() {
    _setup
    _fake_repo
    _place_user_font
    local script="$SBX/setup-fonts-enhanced.sh"
    local tdir target pre
    tdir=$(font_target_dir)
    target="$tdir/MesloLGS NF Regular.ttf"
    pre=$(sha "$target")

    local injected=0
    if command -v chflags >/dev/null 2>&1; then
        chflags uchg "$target" 2>/dev/null && injected=1
    elif command -v chattr >/dev/null 2>&1; then
        chattr +i "$target" 2>/dev/null && injected=1
    fi

    if [[ "$injected" -eq 1 ]]; then
        bash "$script" fonts < /dev/null > /dev/null 2>&1
        local rc=$?
        if [[ "$rc" -ne 0 ]]; then
            _chk "loud" "loud" "injected failure exits nonzero"
        else
            _chk "loud" "silent-success" "injected failure MUST exit nonzero"
        fi
        _chk "$pre" "$(sha "$target")" "pre-state byte-identical after failed run"

        local rb_state
        if [[ -f "$(audit_path)" ]] && grep -q $'rollback\tfonts_enhanced' "$(audit_path)"; then
            rb_state="recorded"
        else
            rb_state="unrecorded"
        fi
        _chk "recorded" "$rb_state" "transaction failure recorded as a rollback in the audit journal"
    else
        _chk "skip-capability" "skip-capability" "immutable-flag injection unsupported on this FS (reported, not silently passed)"
    fi

    if command -v chflags >/dev/null 2>&1; then chflags nouchg "$target" 2>/dev/null; fi
    if command -v chattr >/dev/null 2>&1; then chattr -i "$target" 2>/dev/null; fi
}

# ── e. user font files with DIFFERENT names are untouched ─────────────────────
test_foreign_name_fonts_untouched() {
    _setup
    _fake_repo
    local script="$SBX/setup-fonts-enhanced.sh"
    local tdir foreign pre_sha
    tdir=$(font_target_dir)
    mkdir -p "$tdir"
    foreign="$tdir/MyCustomFont.ttf"
    printf 'user custom font content\n' > "$foreign"
    pre_sha=$(sha "$foreign")
    local pre_mtime
    pre_mtime=$(mtime "$foreign")

    bash "$script" fonts < /dev/null > /dev/null 2>&1
    local rc=$?
    _chk "0" "$rc" "fonts install applies alongside foreign-named fonts"
    _chk "$pre_sha" "$(sha "$foreign")" "foreign-named font bytes untouched"
    _chk "$pre_mtime" "$(mtime "$foreign")" "foreign-named font mtime untouched"
    _chk "$(sha "$SBX/MesloLGS NF Regular.ttf")" "$(sha "$tdir/MesloLGS NF Regular.ttf")" "MesloLGS font still installed"

    if [[ -f "$foreign" ]]; then foreign_state="present"; else foreign_state="removed"; fi
    echo "    [evidence] foreign-font=$foreign_state"
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
run_case fonts-apply-rerun-audit test_fonts_apply_and_rerun || failures=$((failures + 1))
run_case fonts-overwrite-recorded test_fonts_overwrite_recorded || failures=$((failures + 1))
run_case fonts-dry-run test_fonts_dry_run_plan_zero_writes || failures=$((failures + 1))
run_case injected-failure test_injected_failure_preserves_prestate || failures=$((failures + 1))
run_case foreign-names-untouched test_foreign_name_fonts_untouched || failures=$((failures + 1))

if [[ "$failures" -gt 0 ]]; then
    echo "test_fonts_managed.sh: $failures case(s) failed"
    exit 1
fi
