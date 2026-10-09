#!/usr/bin/env bash
# =============================================================================
# scripts/patch-font.sh Managed-Mutation Adoption Tests (AX-6c, P3-1)
# =============================================================================
# GO criteria for the --install font copies (macOS ~/Library/Fonts, Linux
# ~/.local/share/fonts), mirroring tests/integration/test_fonts_managed.sh:
#   a) fresh install: source bytes AND source mode, audited transaction
#   b) rerun against unchanged sources: byte-identical, mtime-stable
#   c) a same-named pre-existing user font + an injected failure on a LATER
#      file: the user font is restored byte-identically (mode included), the
#      earlier newly-installed font is removed, the exit is non-zero
#   d) a font name containing spaces installs correctly
#   e) dry-run (TRANSACTION_DRY_RUN=1 on the function AND the CLI
#      `--dry-run --install` path): HOME/output manifests byte-identical
#      (no new dirs), fc-cache NOT called, plan printed
#   f) Linux apply refreshes the font cache (fc-cache stub called); darwin
#      does not
# Both platform branches are forced via OSTYPE in a subshell (darwin*,
# linux-gnu*) — the function-level cases source the script, which is only
# possible because its entry point is guarded.
#
# Safety: every case runs under a fresh mktemp -d sandbox (HOME, XDG_*,
# TMPDIR) established BEFORE the script is sourced. fontforge, brew and
# fc-cache are recording STUBS first on PATH — the real binaries are never
# run. Every CLI invocation passes --output (the default output directory is
# inside the repository).
#
# Trap note: install_patched_fonts takes the workstation-mutation lock with
# lock_with_trap in a subshell; `trap -p EXIT` inside a subshell reports the
# PARENT's EXIT trap. lib/lock.sh discards that stale display since AX-10;
# each case still clears the inherited EXIT trap first (belt and braces), so
# this file's cleanup trap can never fire mid-case.
# =============================================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/patch-font.sh"

unset TRANSACTION_DRY_RUN TXN_AUDIT_LOG BACKUP_DIR LOG_FILE VMS_STATE_DIR

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vms-patch-font.XXXXXX")"
RUN_DIR="$(cd "$RUN_DIR" && pwd -P)"
TALLY="$RUN_DIR/tally"
: >"$TALLY"
_cleanup() {
    [[ -n "${RUN_DIR:-}" && "$RUN_DIR" == */vms-patch-font.* ]] && rm -rf -- "$RUN_DIR"
}
trap _cleanup EXIT

# ── helpers ──────────────────────────────────────────────────────────────────
pass() {
    printf '  PASS: %s\n' "$1"
    printf 'PASS\t%s\n' "$1" >>"$TALLY"
}
fail() {
    printf '  FAIL: %s\n' "$1"
    [[ $# -gt 1 ]] && printf '        %s\n' "${@:2}"
    printf 'FAIL\t%s\n' "$1" >>"$TALLY"
}
check_eq() { # <expected> <actual> <message>
    if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3" "expected: $1" "actual:   $2"; fi
}
check_contains() { # <needle> <haystack> <message>
    if [[ "$2" == *"$1"* ]]; then pass "$3"; else fail "$3" "missing: $1"; fi
}
check_bytes() { # <source> <installed> <message> — both must exist
    if [[ -f "$1" && -f "$2" && "$(sha "$1")" == "$(sha "$2")" ]]; then
        pass "$3"
    else
        fail "$3" "source:    $1" "installed: $2"
    fi
}
check_true() { # <message> <command...>
    local msg="$1"
    shift
    if "$@"; then pass "$msg"; else fail "$msg"; fi
}

sha() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    fi
}

# GNU-first: on Linux `stat -f` is filesystem info (exit 0, wrong data).
fmode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then
        stat -c '%a' "$1"
    else
        stat -f '%Lp' "$1" 2>/dev/null
    fi
}
mtime() {
    if stat -c %Y "$1" >/dev/null 2>&1; then
        stat -c %Y "$1"
    else
        stat -f %m "$1" 2>/dev/null
    fi
}

# Sorted recursive manifest: type, relative path, mode, sha256 (files).
manifest() {
    local root rel p
    for root in "$@"; do
        if [[ ! -e "$root" ]]; then
            printf 'ABSENT %s\n' "$root"
            continue
        fi
        while IFS= read -r rel; do
            p="$root/${rel#./}"
            if [[ -L "$p" ]]; then
                printf 'L %s -> %s\n' "$rel" "$(readlink "$p")"
            elif [[ -f "$p" ]]; then
                printf 'F %s %s %s\n' "$rel" "$(fmode "$p")" "$(sha "$p")"
            elif [[ -d "$p" ]]; then
                printf 'D %s %s\n' "$rel" "$(fmode "$p")"
            else
                printf 'O %s\n' "$rel"
            fi
        done < <(cd "$root" && find . -print | LC_ALL=C sort)
    done
}

# Fresh per-case sandbox; exported BEFORE anything sources the script.
sandbox() {
    SBX="$RUN_DIR/$1"
    mkdir -p "$SBX/home" "$SBX/tmp" "$SBX/stubs" "$SBX/stub-logs" "$SBX/src"
    export HOME="$SBX/home"
    export TMPDIR="$SBX/tmp"
    export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
    export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
    export VMS_TEST_STUB_LOG_DIR="$SBX/stub-logs"
    _write_stubs "$SBX/stubs"
    export PATH="$SBX/stubs:$PATH"
}

# Recording stubs — the real fontforge/brew/fc-cache are never executed.
_write_stubs() {
    local d="$1"
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s\n" "$*" >>"${VMS_TEST_STUB_LOG_DIR:?}/fc-cache.calls"' >"$d/fc-cache"
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s\n" "$*" >>"${VMS_TEST_STUB_LOG_DIR:?}/brew.calls"' >"$d/brew"
    printf '%s\n' '#!/usr/bin/env bash' \
        '# Test stub: records argv; "patches" by copying the input font.' \
        'log="${VMS_TEST_STUB_LOG_DIR:?}/fontforge.calls"' \
        'printf "%q " "$@" >>"$log"' \
        'printf "\n" >>"$log"' \
        'if [[ "${1:-}" == "--version" ]]; then echo "fontforge-stub 0"; exit 0; fi' \
        'input="${3:-}"; out=""' \
        'while [[ $# -gt 0 ]]; do' \
        '    if [[ "$1" == "--outputdir" ]]; then out="${2:-}"; shift; fi' \
        '    shift' \
        'done' \
        '[[ -n "$out" && -f "$input" ]] || exit 2' \
        'base="${input##*/}"' \
        'cp "$input" "$out/${base%.*} Nerd Font.${base##*.}"' >"$d/fontforge"
    chmod 755 "$d/fc-cache" "$d/brew" "$d/fontforge"
}

dest_for() { # <ostype>
    case "$1" in
        darwin*) printf '%s' "$HOME/Library/Fonts" ;;
        *) printf '%s' "$HOME/.local/share/fonts" ;;
    esac
}

host_dest() {
    case "$(uname -s)" in
        Darwin) printf '%s' "$HOME/Library/Fonts" ;;
        *) printf '%s' "$HOME/.local/share/fonts" ;;
    esac
}

# Source the script in a fresh subshell with OSTYPE forced and call
# install_patched_fonts. Output -> $SBX/out.log; returns the function's rc.
# An optional 3rd argument names a hook function run after sourcing (used to
# inject failures).
run_install() { # <ostype> <source_dir> [hook]
    (
        trap - EXIT
        OSTYPE="$1"
        # shellcheck source=scripts/patch-font.sh
        source "$SCRIPT"
        if [[ -n "${3:-}" ]]; then "$3"; fi
        install_patched_fonts "$2"
    ) >"$SBX/out.log" 2>&1
}

# ── a/b/d/f: fresh install, rerun idempotency, spaces, fc-cache ─────────────
case_apply_rerun() { # <ostype>
    local os="$1" dest rc
    sandbox "apply-$os"
    printf 'alpha-font-bytes\n' >"$SBX/src/Alpha Nerd Font.ttf"
    printf 'beta-font-bytes\n' >"$SBX/src/Beta-Mono.otf"
    printf 'not a font\n' >"$SBX/src/notes.txt"
    chmod 640 "$SBX/src/Alpha Nerd Font.ttf"
    chmod 604 "$SBX/src/Beta-Mono.otf"
    dest=$(dest_for "$os")

    run_install "$os" "$SBX/src"
    rc=$?
    check_eq 0 "$rc" "[$os] fresh install exits 0"
    check_bytes "$SBX/src/Alpha Nerd Font.ttf" "$dest/Alpha Nerd Font.ttf" \
        "[$os] (d) name with spaces installed with source bytes"
    check_bytes "$SBX/src/Beta-Mono.otf" "$dest/Beta-Mono.otf" \
        "[$os] .otf installed with source bytes"
    check_eq 640 "$(fmode "$dest/Alpha Nerd Font.ttf")" "[$os] source mode 640 preserved"
    check_eq 604 "$(fmode "$dest/Beta-Mono.otf")" "[$os] source mode 604 preserved"
    check_true "[$os] non-font file not installed" test ! -e "$dest/notes.txt"
    check_eq "" "$(find "$dest" -name '.vms-font.*' -print 2>/dev/null)" "[$os] no temp files left behind"
    if grep -q $'commit\tpatch_font_install' "$HOME/.config/version-manager/audit.log" 2>/dev/null; then
        pass "[$os] install recorded as a committed transaction"
    else
        fail "[$os] install recorded as a committed transaction"
    fi
    case "$os" in
        linux*)
            check_eq "-f" "$(cat "$SBX/stub-logs/fc-cache.calls" 2>/dev/null)" \
                "[$os] (f) Linux apply refreshes the font cache once (fc-cache -f)"
            ;;
        *)
            check_true "[$os] (f) darwin apply does not call fc-cache" \
                test ! -e "$SBX/stub-logs/fc-cache.calls"
            ;;
    esac

    local m1 m2
    m1=$(mtime "$dest/Alpha Nerd Font.ttf")
    m2=$(mtime "$dest/Beta-Mono.otf")
    sleep 1
    run_install "$os" "$SBX/src"
    rc=$?
    check_eq 0 "$rc" "[$os] (b) rerun exits 0"
    check_bytes "$SBX/src/Alpha Nerd Font.ttf" "$dest/Alpha Nerd Font.ttf" \
        "[$os] (b) rerun bytes identical"
    check_eq "$m1" "$(mtime "$dest/Alpha Nerd Font.ttf")" "[$os] (b) rerun leaves mtime unchanged (spaces)"
    check_eq "$m2" "$(mtime "$dest/Beta-Mono.otf")" "[$os] (b) rerun leaves mtime unchanged (.otf)"
    case "$os" in
        linux*)
            check_eq 1 "$(wc -l <"$SBX/stub-logs/fc-cache.calls" 2>/dev/null | tr -d ' ')" \
                "[$os] (b) unchanged rerun does not rewrite the font cache"
            ;;
    esac
    echo "CASE-DONE apply-$os" >>"$TALLY"
}

# ── c: injected failure on a later file → byte-identical rollback ───────────
_inject_mv_failure() {
    mv() {
        if [[ "${*: -1}" == */"C Fail.ttf" ]]; then
            # Evidence that the earlier replacement really happened before
            # the failure (so the restore below is meaningful).
            cp "$VMS_TEST_DEST/B Shared.otf" "$SBX/evidence-midstate" 2>/dev/null
            return 73
        fi
        command mv "$@"
    }
}

case_rollback() { # <ostype>
    local os="$1" dest rc
    sandbox "rollback-$os"
    printf 'new-font-a\n' >"$SBX/src/A New.ttf"
    printf 'patched-shared-b\n' >"$SBX/src/B Shared.otf"
    printf 'new-font-c\n' >"$SBX/src/C Fail.ttf"
    dest=$(dest_for "$os")
    mkdir -p "$dest"
    printf 'USER-OWNED shared font bytes\n' >"$dest/B Shared.otf"
    chmod 600 "$dest/B Shared.otf"
    printf 'unrelated user font\n' >"$dest/Zeta User.ttf"
    local pre_b pre_z
    pre_b=$(sha "$dest/B Shared.otf")
    pre_z=$(sha "$dest/Zeta User.ttf")
    export VMS_TEST_DEST="$dest"

    run_install "$os" "$SBX/src" _inject_mv_failure
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
        pass "[$os] (c) injected failure exits non-zero"
    else
        fail "[$os] (c) injected failure exits non-zero" "rc=0"
    fi
    check_bytes "$SBX/src/B Shared.otf" "$SBX/evidence-midstate" \
        "[$os] (c) user font was replaced before the failure struck"
    check_eq "$pre_b" "$(sha "$dest/B Shared.otf")" "[$os] (c) pre-existing user font restored byte-identical"
    check_eq 600 "$(fmode "$dest/B Shared.otf")" "[$os] (c) pre-existing user font mode restored"
    check_true "[$os] (c) earlier newly-installed font removed" test ! -e "$dest/A New.ttf"
    check_true "[$os] (c) failing font not installed" test ! -e "$dest/C Fail.ttf"
    check_eq "$pre_z" "$(sha "$dest/Zeta User.ttf")" "[$os] (c) unrelated user font untouched"
    check_eq "" "$(find "$dest" -name '.vms-font.*' -print 2>/dev/null)" "[$os] (c) no temp files left behind"
    if grep -q $'rollback\tpatch_font_install' "$HOME/.config/version-manager/audit.log" 2>/dev/null; then
        pass "[$os] (c) failure recorded as a rollback in the audit journal"
    else
        fail "[$os] (c) failure recorded as a rollback in the audit journal"
    fi
    echo "CASE-DONE rollback-$os" >>"$TALLY"
}

# ── e: function-level dry-run (TRANSACTION_DRY_RUN=1) → zero writes ──────────
case_dry_run_function() { # <ostype>
    local os="$1" dest rc before out
    sandbox "dryrun-$os"
    printf 'alpha-font-bytes\n' >"$SBX/src/Alpha Nerd Font.ttf"
    printf 'beta-font-bytes\n' >"$SBX/src/Beta-Mono.otf"
    dest=$(dest_for "$os")

    # 1) destination directory absent: no new dirs may appear
    before=$(manifest "$HOME" "$SBX/src")
    TRANSACTION_DRY_RUN=1 run_install "$os" "$SBX/src"
    rc=$?
    out=$(cat "$SBX/out.log")
    check_eq 0 "$rc" "[$os] (e) dry-run exits 0"
    check_eq "$before" "$(manifest "$HOME" "$SBX/src")" "[$os] (e) dry-run HOME manifest byte-identical (no new dirs)"
    check_true "[$os] (e) dry-run does not create the font directory" test ! -e "$dest"
    check_contains "[dry-run] would create font directory: $dest" "$out" "[$os] (e) dry-run plans the directory"
    check_contains "[dry-run] would install: $dest/Alpha Nerd Font.ttf" "$out" "[$os] (e) dry-run plans each font"
    check_true "[$os] (e) dry-run does not call fc-cache" test ! -e "$SBX/stub-logs/fc-cache.calls"

    # 2) a different same-named user font exists: still zero writes
    mkdir -p "$dest"
    printf 'USER-OWNED alpha\n' >"$dest/Alpha Nerd Font.ttf"
    before=$(manifest "$HOME" "$SBX/src")
    TRANSACTION_DRY_RUN=1 run_install "$os" "$SBX/src"
    rc=$?
    check_eq 0 "$rc" "[$os] (e) dry-run over an existing user font exits 0"
    check_eq "$before" "$(manifest "$HOME" "$SBX/src")" "[$os] (e) dry-run leaves an existing user font and HOME byte-identical"
    check_true "[$os] (e) dry-run (existing dir) does not call fc-cache" test ! -e "$SBX/stub-logs/fc-cache.calls"
    echo "CASE-DONE dryrun-$os" >>"$TALLY"
}

# ── e (CLI) + apply path end-to-end through the fontforge stub (host OS) ─────
case_cli() {
    local rc before out plan dest
    sandbox "cli"
    dest=$(host_dest)
    mkdir -p "$SBX/in" "$SBX/out"
    printf 'input-font-bytes\n' >"$SBX/in/My Font.ttf"
    printf 'prebuilt-patched-bytes\n' >"$SBX/out/Prebuilt Nerd Font.ttf"

    # 1) --dry-run --install: plans the patch command and the install of the
    #    font files already in the output directory; zero writes; no stub runs.
    before=$(manifest "$HOME" "$SBX/in" "$SBX/out")
    bash "$SCRIPT" --dry-run --install --output "$SBX/out" "$SBX/in/My Font.ttf" \
        </dev/null >"$SBX/cli.stdout" 2>"$SBX/cli.stderr"
    rc=$?
    out="$(cat "$SBX/cli.stdout" "$SBX/cli.stderr")"
    check_eq 0 "$rc" "[cli] (e) --dry-run --install exits 0 without running fontforge"
    check_eq "$before" "$(manifest "$HOME" "$SBX/in" "$SBX/out")" \
        "[cli] (e) --dry-run --install: HOME + output manifests byte-identical"
    check_true "[cli] (e) --dry-run never executes fontforge" test ! -e "$SBX/stub-logs/fontforge.calls"
    check_true "[cli] (e) --dry-run never calls brew" test ! -e "$SBX/stub-logs/brew.calls"
    check_true "[cli] (e) --dry-run never calls fc-cache" test ! -e "$SBX/stub-logs/fc-cache.calls"
    check_contains "[dry-run] Font patching NOT executed" "$out" "[cli] (e) patch step reported as planned"
    plan=$(grep '^  fontforge ' "$SBX/cli.stdout" | head -1)
    check_contains "--outputdir" "$plan" "[cli] (e) planned font-patcher command printed"
    check_contains "[dry-run] would install: $dest/Prebuilt Nerd Font.ttf" "$out" \
        "[cli] (e) install planned from fonts already in the output directory"

    # 2) output directory absent: says so, creates nothing
    before=$(manifest "$HOME" "$SBX/in" "$SBX/out")
    bash "$SCRIPT" --dry-run --install --output "$SBX/out-absent" "$SBX/in/My Font.ttf" \
        </dev/null >"$SBX/cli2.log" 2>&1
    rc=$?
    out="$(cat "$SBX/cli2.log")"
    check_eq 0 "$rc" "[cli] (e) --dry-run --install with no output dir exits 0"
    check_true "[cli] (e) dry-run does not create the output directory" test ! -e "$SBX/out-absent"
    check_contains "No patched font files to plan" "$out" "[cli] (e) dry-run says there are no fonts to plan"
    check_eq "$before" "$(manifest "$HOME" "$SBX/in" "$SBX/out")" "[cli] (e) no-output-dir dry-run: zero writes"

    # 3) fontforge absent (brew stub present): dry-run plans, never installs
    mkdir -p "$SBX/stubs-noff"
    cp "$SBX/stubs/brew" "$SBX/stubs/fc-cache" "$SBX/stubs-noff/"
    local noff_path
    noff_path="$SBX/stubs-noff:${PATH#"$SBX/stubs:"}"
    if PATH="$noff_path" command -v fontforge >/dev/null 2>&1; then
        pass "[cli] (e) fontforge-absent dry-run skipped: a real fontforge is on PATH (capability, reported)"
    else
        before=$(manifest "$HOME" "$SBX/in" "$SBX/out")
        PATH="$noff_path" bash "$SCRIPT" --dry-run --install --output "$SBX/out" "$SBX/in/My Font.ttf" \
            </dev/null >"$SBX/cli3.log" 2>&1
        rc=$?
        out="$(cat "$SBX/cli3.log")"
        check_eq 0 "$rc" "[cli] (e) dry-run without fontforge still plans (exit 0)"
        check_true "[cli] (e) dry-run without fontforge never runs brew install" test ! -e "$SBX/stub-logs/brew.calls"
        check_contains "brew install fontforge" "$out" "[cli] (e) dry-run reports the FontForge install plan"
        check_eq "$before" "$(manifest "$HOME" "$SBX/in" "$SBX/out")" "[cli] (e) fontforge-absent dry-run: zero writes"
    fi

    # 4) apply --install through the fontforge stub: the executed command is
    #    exactly the planned one; both output fonts land in the font dir.
    bash "$SCRIPT" --install --output "$SBX/out" "$SBX/in/My Font.ttf" </dev/null >"$SBX/cli4.log" 2>&1
    rc=$?
    check_eq 0 "$rc" "[cli] apply --install exits 0"
    local executed
    executed=$(grep -- '^--script ' "$SBX/stub-logs/fontforge.calls" 2>/dev/null | head -1)
    check_eq "$plan" "  fontforge ${executed% }" "[cli] dry-run plan is exactly the executed font-patcher command"
    check_bytes "$SBX/out/My Font Nerd Font.ttf" "$dest/My Font Nerd Font.ttf" \
        "[cli] patched font installed with output bytes"
    check_bytes "$SBX/out/Prebuilt Nerd Font.ttf" "$dest/Prebuilt Nerd Font.ttf" \
        "[cli] pre-existing output font installed with its bytes"
    case "$(uname -s)" in
        Linux) check_true "[cli] (f) Linux CLI apply refreshes the font cache" test -s "$SBX/stub-logs/fc-cache.calls" ;;
        *) check_true "[cli] (f) non-Linux CLI apply does not call fc-cache" test ! -e "$SBX/stub-logs/fc-cache.calls" ;;
    esac

    # 5) apply without --install: patches into a fresh output dir, installs
    #    nothing, prints the install hint (non-install path unchanged).
    before=$(manifest "$dest")
    bash "$SCRIPT" --output "$SBX/out-new" "$SBX/in/My Font.ttf" </dev/null >"$SBX/cli5.log" 2>&1
    rc=$?
    out="$(cat "$SBX/cli5.log")"
    check_eq 0 "$rc" "[cli] patch without --install exits 0"
    check_true "[cli] patch without --install creates the output font" test -f "$SBX/out-new/My Font Nerd Font.ttf"
    check_eq "$before" "$(manifest "$dest")" "[cli] patch without --install leaves the font directory untouched"
    check_contains "To install the patched font, run:" "$out" "[cli] install hint printed"
    echo "CASE-DONE cli" >>"$TALLY"
}

# ── runner ───────────────────────────────────────────────────────────────────
# Each case runs in its own subshell: its sandbox exports never leak, and the
# inherited EXIT trap is cleared first (see header "Trap note").
run_case() {
    echo "── $* ──"
    (
        trap - EXIT
        "$@"
    )
}

EXPECTED_CASES=0
for os in darwin23 linux-gnu; do
    run_case case_apply_rerun "$os"
    run_case case_rollback "$os"
    run_case case_dry_run_function "$os"
    EXPECTED_CASES=$((EXPECTED_CASES + 3))
done
run_case case_cli
EXPECTED_CASES=$((EXPECTED_CASES + 1))

passes=$(grep -c '^PASS' "$TALLY")
failures=$(grep -c '^FAIL' "$TALLY")
done_cases=$(grep -c '^CASE-DONE' "$TALLY")
echo
echo "test_patch_font_managed.sh: $passes passed, $failures failed, $done_cases/$EXPECTED_CASES cases completed"
if [[ "$failures" -gt 0 || "$done_cases" -ne "$EXPECTED_CASES" || "$passes" -eq 0 ]]; then
    exit 1
fi
exit 0
