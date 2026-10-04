#!/usr/bin/env bash
# =============================================================================
# M5 Adverse-Condition Scenario Tests (directive M5, ROADMAP "validation
# scenarios": clean-HOME / no-network / permission / symlink)
# =============================================================================
# Proves the transaction-routed mutation adopters (scripts/fix-terminal-issues.sh,
# scripts/fix-nvm-issues.sh, setup-versions.sh configure-nvm) behave safely
# under adverse environments. Every case asserts BOTH the loud-failure /
# no-partial-write property AND dry-run equivalence where applicable.
#
#   1. CLEAN-HOME  — sandbox HOME exists but is empty. The script either
#      succeeds creating what it needs or exits nonzero loudly: never a
#      silent zero-write exit 0, never an unset-variable crash trace, never
#      a half-created target. Final-state invariants asserted (audit journal
#      start/commit/rollback records, created-or-absent targets).
#   2. NO-NETWORK  — a per-case mocks dir (mktemp) holds curl/wget/git stubs
#      that print a network error to stderr and exit 7/4/128; the dir is
#      prepended to PATH FOR THE INVOCATION ONLY (via env). The mock is the
#      hermetic mechanism (never host firewalling). Every invocation is
#      watchdog-bounded: background child + poll + kill at the bound (the
#      B1.8 pattern — output goes to a FILE, never a pipe a survivor could
#      hold). A hung invocation records rc=124 and FAILS the case.
#   3. PERMISSION  — the write surface is made read-only for the invoking
#      user (chmod 555 dir / 444 file inside the sandbox). Transaction and
#      journal infrastructure is pre-created first (mkdir -p is idempotent
#      on existing dirs), so the failure lands AFTER registration and the
#      rollback path genuinely runs. The mutation must exit nonzero and the
#      pre-state must survive byte-identically (sha256). Cases are MARKED
#      SKIPPED when running as root (chmod cannot restrict root) — never a
#      false pass.
#   4. SYMLINK     — ~/.zshrc is a symlink to a user dotfiles file OUTSIDE
#      the sandbox HOME (inside the sandbox, outside HOME/.zshrc's path).
#      M2 transaction semantics as implemented: the pre-state LINK is
#      registered (transaction files.tsv kind=symlink), user content
#      survives, dry-run never touches the link, and the failure path
#      rolls back to the link.
#
# RED→GREEN (directive Rule 5): each group carries one NEGATIVE CONTROL — a
# deliberately property-violating stub (e.g. a "mutator" that writes partial
# state and exits 0, defeats the read-only surface, or hangs) fed through the
# SAME assertion helpers must trip them; each control prints a
# "NEGATIVE CONTROL ... RED (expected)" evidence line, and a control that
# does NOT trip fails the suite (assertions without teeth are a defect).
# Control stubs are generated inside the mktemp sandbox at runtime; no repo
# script is modified by this file.
#
# Scope note (M5 lane Y remediation, [B1.10-new][B1.11-new][B1.12-new]): the
# two defects this file previously reported as out-of-scope handoffs are now
# fixed in lib/ and pinned HERE:
#   (1) B1.10-new — mutation_block_write's commit path used to atomically
#       rename OVER a symlinked rc, destroying the link (final-type used to
#       print regular-file). The write now replaces the RESOLVED content file
#       (temp file in the resolved file's directory) and the link survives.
#       Assertions: still-symlink + link-target-verbatim + block-in-resolved
#       (groups 4a/4c) and the editor-level byte-identical rerun probe (4d).
#   (2) B1.11-new — transaction_rollback's symlink branch used to run a bare
#       `rm -f`; an EACCES unlink aborted the rollback under an adopter's
#       set -e BEFORE the rollback journal/metadata record. 4b now injects
#       the failure via a 555 resolved-dir (write fails after registration)
#       + 555 HOME (hostile unlink) and asserts the rollback record survives.
#   (3) B1.12-new — lib/cache.sh used to run an unredirected batch mkdir at
#       SOURCE TIME; a 555 HOME killed any strict caller at load. Case 3d
#       proves the sourcing executable now degrades and survives.
# Residual handoff (NOT fixed by this lane — adopter scripts are out of
# scope): scripts/fix-nvm-issues.sh _fix_nvm_strip_legacy and
# setup-versions.sh _setup_versions_strip_legacy_nvm still do their own
# mktemp+mv over the rc path; when legacy drift lines exist, that mv replaces
# a symlinked rc with a regular file (same defect class as B1.10-new). These
# cases avoid legacy drift lines, so the link-preserving assertions hold.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/../helpers.sh"

set +e

REAL_TERMINAL="$ROOT_DIR/scripts/fix-terminal-issues.sh"
REAL_NVM="$ROOT_DIR/scripts/fix-nvm-issues.sh"
REAL_SETUP="$ROOT_DIR/setup-versions.sh"
P10K_SOURCE="$ROOT_DIR/config/professional-dev-p10k.zsh"

ENV_BIN="$(command -v env 2>/dev/null || printf '/usr/bin/env')"
RUN_LIMIT_S=45   # watchdog bound for every real script invocation
NC_LIMIT_S=3     # tighter bound for the hang-control stub

sha() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

# ── Assertion counting ────────────────────────────────────────────────────────
# A case's exit status must reflect its own failures (teardown always
# succeeds). NC_MODE reroutes assertion failures into NC_TRIPPED so negative
# controls REUSE the exact assertion helpers of the real cases.
CASE_FAILS=0
CASE_SKIP=0
NC_MODE=0
NC_TRIPPED=0
SKIPPED_CASES=0

_chk() {
    if (( NC_MODE )); then
        assert_equals "$@" || NC_TRIPPED=$((NC_TRIPPED + 1))
    else
        assert_equals "$@" || CASE_FAILS=$((CASE_FAILS + 1))
    fi
}

_mark_skip() {
    CASE_SKIP=1
    echo "    [skip] $1"
}

# ── Bounded run (B1.8 pattern) ────────────────────────────────────────────────
# Background child + 0.1s poll + kill at the bound. Output is redirected to a
# FILE (never a command-substitution pipe — a descendant holding an inherited
# pipe is how hosted macOS legs died, builds #22/#24-#26). Returns the child's
# exit code; 124 when the watchdog killed it.
_bounded_run() {
    local log_file="$1" limit_s="$2"
    shift 2
    local out_file rc=0 waited=0 pid
    out_file=$(mktemp "${TMPDIR:-/tmp}/vms-adverse-out.XXXXXX") || return 125
    "$@" >"$out_file" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if (( waited >= limit_s * 10 )); then
            kill "$pid" 2>/dev/null
            sleep 0.2
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            rc=124
            break
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    if (( rc == 0 )); then
        wait "$pid" 2>/dev/null || rc=$?
    fi
    mv "$out_file" "$log_file" 2>/dev/null || { cat "$out_file" > "$log_file"; rm -f "$out_file"; }
    return "$rc"
}

# Bounded run of a repo script: bash <script> <args...>
_vrun() {
    local log="$1" secs="$2"
    shift 2
    _bounded_run "$log" "$secs" bash "$@"
}

# Bounded run with per-invocation environment assignments (env VAR=... bash ...):
# used for the PATH-prepended network mocks and TRANSACTION_DRY_RUN=1.
_vrun_env() {
    local log="$1" secs="$2"
    shift 2
    _bounded_run "$log" "$secs" "$ENV_BIN" "$@"
}

# ── Sandboxes ─────────────────────────────────────────────────────────────────
# HOME is a subdirectory of the sandbox ($SBX/home) so the SYMLINK group can
# anchor the user dotfiles file OUTSIDE HOME (at $SBX/user-dotfiles/) while
# staying inside the mktemp sandbox. Nothing is ever written outside the
# sandbox + TMPDIR.
_setup() {
    SBX=$(mktemp -d "${TMPDIR:-/tmp}/vms-adverse.XXXXXX")
    mkdir -p "$SBX/home"
    export HOME="$SBX/home"
}

_teardown() {
    if [[ -n "${SBX:-}" && "$SBX" == */vms-adverse.* ]]; then
        # Release any read-only surface left by the permission group, then remove.
        chmod -R u+rwx "$SBX" 2>/dev/null
        rm -rf "$SBX"
    fi
    if [[ -n "${MOCKS:-}" && "$MOCKS" == */vms-adverse-mocks.* ]]; then
        rm -rf "$MOCKS"
    fi
    unset HOME
    unset SBX MOCKS
}

# ── Fixtures ──────────────────────────────────────────────────────────────────
# Fail-network mocks: curl exit 7 (connection refused), wget exit 4 (network
# failure), git exit 128. Printed to stderr; never succeed.
_mocks_install() {
    MOCKS=$(mktemp -d "${TMPDIR:-/tmp}/vms-adverse-mocks.XXXXXX")
    printf '#!/bin/sh\necho "mock-curl: (7) Failed to connect (hermetic no-network mock)" >&2\nexit 7\n' > "$MOCKS/curl"
    printf '#!/bin/sh\necho "mock-wget: (4) Network failure (hermetic no-network mock)" >&2\nexit 4\n' > "$MOCKS/wget"
    printf '#!/bin/sh\necho "mock-git: fatal: unable to access network (hermetic no-network mock)" >&2\nexit 128\n' > "$MOCKS/git"
    chmod +x "$MOCKS/curl" "$MOCKS/wget" "$MOCKS/git"
}

# Deterministic NVM presence: detect_nvm probes $HOME/.nvm/nvm.sh FIRST, so a
# sandbox stub makes configure-nvm's NVM check independent of host paths.
_stub_nvm() {
    mkdir -p "$HOME/.nvm"
    printf '# synthetic nvm stub (test fixture; detection probes -f)\n' > "$HOME/.nvm/nvm.sh"
}

# Pre-create the transaction/journal/lock infrastructure so the PERMISSION
# group's 555 chmod lands after registration (mkdir -p is idempotent
# on existing dirs), so transaction_start still succeeds under the read-only
# HOME. The cache tree is pre-created for setup-versions.sh specifically:
# it sources lib/nvm.sh -> lib/cache.sh, whose cache_init runs AT SOURCE TIME
# (cache.sh bottom). Since B1.12-new the source-time init degrades instead of
# aborting, so the pre-creation is no longer load-bearing for cache.sh — it
# is kept for the transaction/journal/lock infra, which still must exist
# before the 555 chmod lands.
_precreate_txn_infra() {
    mkdir -p "$HOME/.config-backups/transactions" \
             "$HOME/.config/version-manager" \
             "$HOME/.local/state/version-manager/locks" \
             "$HOME/.cache/version-management-setup"/{version-managers,files,commands,themes,metadata}
}

# Sandbox-local repo layout for fix-terminal-issues.sh (the repo commits no
# font assets; lib/ and config/ are symlinks, only fonts are synthetic).
_fake_repo() {
    mkdir -p "$SBX/scripts"
    ln -s "$ROOT_DIR/lib" "$SBX/lib"
    ln -s "$ROOT_DIR/config" "$SBX/config"
    ln -s "$REAL_TERMINAL" "$SBX/scripts/fix-terminal-issues.sh"
    printf 'synthetic-meslo-regular\n' > "$SBX/MesloLGS-Regular.ttf"
    printf 'synthetic-meslo-bold\n' > "$SBX/MesloLGS-Bold.ttf"
}

# ~/.zshrc as a symlink to a user dotfiles file OUTSIDE the sandbox HOME.
_sym_setup() {
    mkdir -p "$SBX/user-dotfiles"
    printf '# user dotfiles preamble\nexport EDITOR=vim\n' > "$SBX/user-dotfiles/zshrc-real"
    ln -s "$SBX/user-dotfiles/zshrc-real" "$HOME/.zshrc"
}

font_target_dir() {
    case "$(uname -s)" in
        Darwin) printf '%s' "$HOME/Library/Fonts" ;;
        *)      printf '%s' "$HOME/.local/share/fonts" ;;
    esac
}

# ── Verdict helpers (state words so every verdict flows through _chk) ────────
_state_grep() {  # $1 fixed needle, $2 file -> present|absent
    if [[ -f "$2" ]] && grep -qF -- "$1" "$2" 2>/dev/null; then
        printf 'present'
    else
        printf 'absent'
    fi
}

_rc_state() {  # $1 rc -> zero|nonzero|hung-killed
    if (( $1 == 124 )); then printf 'hung-killed'
    elif (( $1 == 0 )); then printf 'zero'
    else printf 'nonzero'
    fi
}

_journal_state() {  # $1 event, $2 txn name -> present|absent
    local j="$HOME/.config/version-manager/audit.log"
    if [[ -f "$j" ]] && grep -q "$(printf '%s\t%s' "$1" "$2")" "$j"; then
        printf 'present'
    else
        printf 'absent'
    fi
}

_txn_tsv_kind() {  # $1 txn name -> symlink|file|new|no-txn (first registered entry)
    local d
    d=$(ls -d "$HOME/.config-backups/transactions/$1."* 2>/dev/null | sort | tail -1)
    if [[ -z "$d" || ! -f "$d/files.tsv" ]]; then
        printf 'no-txn'
        return
    fi
    awk -F'\t' 'NR==1{print $1; exit}' "$d/files.tsv"
}

# ── Shared green assertions (real cases AND negative controls) ───────────────
assert_p10k_created_full() {  # $1 rc, $2 log — clean-home apply path
    _chk "zero" "$(_rc_state "$1")" "apply succeeds and creates its target (rc=$1)"
    if cmp -s "$P10K_SOURCE" "$HOME/.p10k.zsh" 2>/dev/null; then full="full"; else full="partial-or-missing"; fi
    _chk "full" "$full" "created target holds the FULL project p10k source (no partial write)"
    _chk "absent" "$(_state_grep 'unbound variable' "$2")" "no unset-variable crash trace"
}

assert_loud_fail_preserved() {  # $1 rc, $2 log, $3 file, $4 pre-sha
    if (( $1 != 0 )); then loud="loud"; else loud="silent-success"; fi
    _chk "loud" "$loud" "mutation failure exits nonzero (rc=$1)"
    _chk "present" "$(_state_grep '[ERROR]' "$2")" "failure is loud on stderr ([ERROR] marker)"
    if [[ -f "$3" ]] && [[ "$(sha "$3")" == "$4" ]]; then same="identical"; else same="mutated"; fi
    _chk "identical" "$same" "pre-state byte-identical after the failed run (hash)"
    _chk "absent" "$(_state_grep 'unbound variable' "$2")" "no unset-variable crash trace"
}

assert_nvm_block_applied() {  # $1 rc, $2 log, $3 zshrc, $4 user content line
    _chk "zero" "$(_rc_state "$1")" "managed-block apply succeeds (rc=$1)"
    _chk "present" "$(_state_grep '# BEGIN version-management-setup:nvm' "$3")" "canonical managed block present"
    _chk "present" "$(_state_grep 'NVM_SILENT=true' "$3")" "canonical NVM_SILENT=true posture (P1-3)"
    _chk "absent" "$(_state_grep 'NVM_SILENT=1' "$3")" "no legacy NVM_SILENT=1 drift line"
    _chk "present" "$(_state_grep "$4" "$3")" "user rc content preserved"
    _chk "absent" "$(_state_grep 'unbound variable' "$2")" "no unset-variable crash trace"
}

assert_symlink_apply() {  # $1 rc, $2 log, $3 zshrc, $4 user content line
    _chk "zero" "$(_rc_state "$1")" "apply over a symlinked rc exits 0"
    _chk "present" "$(_state_grep "$4" "$3")" "user dotfiles content survives the managed write"
    _chk "symlink" "$(_txn_tsv_kind fix_nvm_silent)" "transaction registered the pre-state as kind=symlink (M2)"
    _chk "absent" "$(_state_grep 'unbound variable' "$2")" "no unset-variable crash trace"
}

assert_dry_run_green() {  # $1 rc, $2 log — dry-run equivalence base
    _chk "zero" "$(_rc_state "$1")" "dry-run is a supported mode (rc=$1)"
    _chk "present" "$(_state_grep '[dry-run]' "$2")" "dry-run prints plan output"
    _chk "absent" "$(_state_grep 'unbound variable' "$2")" "no unset-variable crash trace"
}

assert_bounded() {  # $1 rc — no invocation may hang
    if (( $1 == 124 )); then b="hung-killed"; else b="completed"; fi
    _chk "completed" "$b" "invocation completed within the watchdog bound (no hang)"
}

assert_txn_committed() {  # $1 txn name
    _chk "present" "$(_journal_state start "$1")" "$1 transaction recorded in the audit journal"
    _chk "present" "$(_journal_state commit "$1")" "$1 commit recorded in the audit journal"
}

# ═════════════════════════════════════════════════════════════════════════════
# GROUP 1 — CLEAN-HOME: sandbox HOME exists but is empty
# ═════════════════════════════════════════════════════════════════════════════

# ── 1a. whole-file replace creates what it needs; audited ────────────────────
test_clean_home_terminal_p10k() {
    _setup
    local log="$SBX/run-a1.log" rc
    _vrun "$log" "$RUN_LIMIT_S" "$REAL_TERMINAL" fix-p10k
    rc=$?
    assert_p10k_created_full "$rc" "$log"
    assert_txn_committed fix_terminal_p10k
    local created="no"
    [[ -f "$HOME/.p10k.zsh" ]] && created="yes"
    echo "    [evidence] clean-home fix-p10k: rc=$rc created=$created journal-commit=$(_journal_state commit fix_terminal_p10k)"
}

# ── 1b. rc-editor on a missing rc fails loudly, writes nothing ───────────────
test_clean_home_nvm_silent() {
    _setup
    local log="$SBX/run-a2.log" rc
    _vrun "$log" "$RUN_LIMIT_S" "$REAL_NVM" --silent
    rc=$?
    assert_bounded "$rc"
    local state="created"
    [[ -e "$HOME/.zshrc" ]] || state="absent"
    _chk "absent" "$state" "clean-home rc-editor failure creates no .zshrc (no partial write)"
    if (( rc != 0 )); then loud="loud"; else loud="silent-success"; fi
    _chk "loud" "$loud" "clean-home rc-editor failure exits nonzero (rc=$rc)"
    _chk "present" "$(_state_grep '[ERROR]' "$log")" "failure is loud on stderr ([ERROR] marker)"
    _chk "present" "$(_journal_state rollback fix_nvm_silent)" "clean-home failure journals the transaction rollback"
    _chk "absent" "$(_state_grep 'unbound variable' "$log")" "no unset-variable crash trace"
    echo "    [evidence] clean-home fix-nvm --silent: rc=$rc zshrc=$state journal-rollback=$(_journal_state rollback fix_nvm_silent)"
}

# ── 1c. configure-nvm on a missing rc fails loudly, no commit, no target ─────
test_clean_home_setup_versions() {
    _setup
    _stub_nvm
    local log="$SBX/run-a3.log" rc
    _vrun "$log" "$RUN_LIMIT_S" "$REAL_SETUP" configure-nvm
    rc=$?
    assert_bounded "$rc"
    local state="created"
    [[ -e "$HOME/.zshrc" ]] || state="absent"
    _chk "absent" "$state" "clean-home configure-nvm failure creates no .zshrc (no partial write)"
    if (( rc != 0 )); then loud="loud"; else loud="silent-success"; fi
    _chk "loud" "$loud" "clean-home configure-nvm failure exits nonzero (rc=$rc)"
    _chk "present" "$(_state_grep '[ERROR]' "$log")" "failure is loud on stderr ([ERROR] marker)"
    _chk "absent" "$(_journal_state commit setup_versions_nvm)" "failed run records no commit in the audit journal"
    _chk "absent" "$(_state_grep 'unbound variable' "$log")" "no unset-variable crash trace"
    echo "    [evidence] clean-home configure-nvm: rc=$rc zshrc=$state journal-commit=$(_journal_state commit setup_versions_nvm)"
}

# ── 1d. clean-home dry-run: plans, writes nothing ─────────────────────────────
test_clean_home_dry_run_p10k() {
    _setup
    local log="$SBX/run-a4.log" rc
    _vrun "$log" "$RUN_LIMIT_S" "$REAL_TERMINAL" --dry-run fix-p10k
    rc=$?
    assert_dry_run_green "$rc" "$log"
    local written="written"
    [[ -e "$HOME/.p10k.zsh" ]] || written="absent"
    _chk "absent" "$written" "clean-home dry-run creates nothing (zero writes)"
    echo "    [evidence] clean-home dry-run fix-p10k: rc=$rc target=$written"
}

# ── 1e. clean-home dry-run of the rc editors: same loud failure, zero writes ─
test_clean_home_dry_run_rc_editors() {
    _setup
    _stub_nvm
    local log1="$SBX/run-a5a.log" log2="$SBX/run-a5b.log" rc1 rc2
    _vrun "$log1" "$RUN_LIMIT_S" "$REAL_NVM" --dry-run --silent
    rc1=$?
    if (( rc1 != 0 )); then loud="loud"; else loud="silent-success"; fi
    _chk "loud" "$loud" "clean-home dry-run fix-nvm fails loudly like the apply path (rc=$rc1)"
    _chk "present" "$(_state_grep 'dry-run' "$log1")" "fix-nvm dry-run marks itself as a plan"
    _vrun_env "$log2" "$RUN_LIMIT_S" TRANSACTION_DRY_RUN=1 bash "$REAL_SETUP" configure-nvm
    rc2=$?
    if (( rc2 != 0 )); then loud="loud"; else loud="silent-success"; fi
    _chk "loud" "$loud" "clean-home dry-run configure-nvm fails loudly like the apply path (rc=$rc2)"
    local written="written"
    [[ -e "$HOME/.zshrc" ]] || written="absent"
    _chk "absent" "$written" "clean-home dry-run rc editors create no .zshrc (zero writes)"
    echo "    [evidence] clean-home dry-run rc editors: fix-nvm rc=$rc1 configure-nvm rc=$rc2 zshrc=$written"
}

# ═════════════════════════════════════════════════════════════════════════════
# GROUP 2 — NO-NETWORK: fail-stubs for curl/wget/git, PATH for the invocation
# only; every invocation watchdog-bounded
# ═════════════════════════════════════════════════════════════════════════════

# ── 2a. the hermetic mechanism is real: mocks resolve ahead of real tools ────
test_network_mocks_active() {
    _setup
    _mocks_install
    local log="$SBX/run-b0.log" tool resolved rc
    for tool in curl wget git; do
        _bounded_run "$log" "$NC_LIMIT_S" "$ENV_BIN" PATH="$MOCKS:$PATH" bash -c 'command -v "$1"' bash "$tool"
        rc=$?
        resolved=$(tr -d '[:space:]' < "$log" 2>/dev/null)
        _chk "0" "$rc" "mock resolution probe for $tool exits 0"
        _chk "$MOCKS/$tool" "$resolved" "$tool resolves to the fail-stub under the invocation PATH"
    done
    echo "    [evidence] mocks active: curl/wget/git all resolve to the mktemp fail-stub dir"
}

# ── 2b. fix-nvm-issues under dead network: local mutation unaffected ─────────
test_no_network_nvm_silent() {
    _setup
    _mocks_install
    printf '# user preamble\nexport EDITOR=vim\n' > "$HOME/.zshrc"
    local log="$SBX/run-b1.log" dry_log="$SBX/run-b1d.log" rc pre_dry
    _vrun_env "$log" "$RUN_LIMIT_S" PATH="$MOCKS:$PATH" bash "$REAL_NVM" --silent
    rc=$?
    assert_bounded "$rc"
    assert_nvm_block_applied "$rc" "$log" "$HOME/.zshrc" "export EDITOR=vim"
    assert_txn_committed fix_nvm_silent
    echo "    [evidence] no-network fix-nvm --silent: rc=$rc block=$(_state_grep 'NVM_SILENT=true' "$HOME/.zshrc")"
    # dry-run equivalence under the same dead network: plan, zero writes.
    # The hash anchor is the POST-APPLY state (the apply legitimately changed
    # the file; the dry-run must not change it again).
    pre_dry=$(sha "$HOME/.zshrc")
    _vrun_env "$dry_log" "$RUN_LIMIT_S" PATH="$MOCKS:$PATH" bash "$REAL_NVM" --dry-run --silent
    rc=$?
    assert_dry_run_green "$rc" "$dry_log"
    _chk "$pre_dry" "$(sha "$HOME/.zshrc")" "dry-run under dead network writes nothing (hash)"
    echo "    [evidence] no-network fix-nvm dry-run: rc=$rc bytes-hash-stable"
}

# ── 2c. setup-versions configure-nvm under dead network ──────────────────────
test_no_network_setup_versions() {
    _setup
    _mocks_install
    _stub_nvm
    printf '# user preamble\nexport EDITOR=vim\n' > "$HOME/.zshrc"
    local log="$SBX/run-b2.log" dry_log="$SBX/run-b2d.log" rc pre_dry
    _vrun_env "$log" "$RUN_LIMIT_S" PATH="$MOCKS:$PATH" bash "$REAL_SETUP" configure-nvm
    rc=$?
    assert_bounded "$rc"
    assert_nvm_block_applied "$rc" "$log" "$HOME/.zshrc" "export EDITOR=vim"
    assert_txn_committed setup_versions_nvm
    echo "    [evidence] no-network configure-nvm: rc=$rc journal-commit=$(_journal_state commit setup_versions_nvm)"
    # dry-run equivalence under the same dead network (post-apply hash anchor)
    pre_dry=$(sha "$HOME/.zshrc")
    _vrun_env "$dry_log" "$RUN_LIMIT_S" PATH="$MOCKS:$PATH" TRANSACTION_DRY_RUN=1 bash "$REAL_SETUP" configure-nvm
    rc=$?
    assert_dry_run_green "$rc" "$dry_log"
    _chk "$pre_dry" "$(sha "$HOME/.zshrc")" "dry-run under dead network writes nothing (hash)"
    echo "    [evidence] no-network configure-nvm dry-run: rc=$rc bytes-hash-stable"
}

# ── 2d. fix-terminal-issues fix-p10k under dead network ──────────────────────
test_no_network_terminal_p10k() {
    _setup
    _mocks_install
    local log="$SBX/run-b3.log" dry_log="$SBX/run-b3d.log" rc pre
    _vrun_env "$log" "$RUN_LIMIT_S" PATH="$MOCKS:$PATH" bash "$REAL_TERMINAL" fix-p10k
    rc=$?
    assert_bounded "$rc"
    assert_p10k_created_full "$rc" "$log"
    assert_txn_committed fix_terminal_p10k
    pre=$(sha "$HOME/.p10k.zsh")
    echo "    [evidence] no-network fix-p10k: rc=$rc target=full journal-commit=$(_journal_state commit fix_terminal_p10k)"
    # dry-run equivalence under the same dead network: plan, zero writes
    _vrun_env "$dry_log" "$RUN_LIMIT_S" PATH="$MOCKS:$PATH" bash "$REAL_TERMINAL" --dry-run fix-p10k
    rc=$?
    assert_dry_run_green "$rc" "$dry_log"
    _chk "$pre" "$(sha "$HOME/.p10k.zsh")" "dry-run under dead network writes nothing (hash)"
    echo "    [evidence] no-network fix-p10k dry-run: rc=$rc bytes-hash-stable"
}

# ═════════════════════════════════════════════════════════════════════════════
# GROUP 3 — PERMISSION: read-only write surface; root runs are MARKED SKIPS
# ═════════════════════════════════════════════════════════════════════════════

# ── 3a. read-only font dir: loud fail, user font intact, rollback journaled ──
test_permission_fonts_readonly() {
    if [[ "$(id -u)" == "0" ]]; then
        _mark_skip "permission case is meaningless as root (chmod cannot restrict root)"
        return 0
    fi
    _setup
    _fake_repo
    local tdir
    tdir=$(font_target_dir)
    mkdir -p "$tdir"
    printf 'user-font-v1\n' > "$tdir/MesloLGS-Regular.ttf"
    local pre log="$SBX/run-c1.log" dry_log="$SBX/run-c1d.log" rc
    pre=$(sha "$tdir/MesloLGS-Regular.ttf")
    chmod 555 "$tdir"
    _vrun "$log" "$RUN_LIMIT_S" "$SBX/scripts/fix-terminal-issues.sh" fix-fonts
    rc=$?
    chmod u+rwx "$tdir"
    if (( rc != 0 )); then loud="loud"; else loud="silent-success"; fi
    _chk "loud" "$loud" "read-only font dir forces nonzero exit (rc=$rc)"
    _chk "present" "$(_state_grep '[ERROR]' "$log")" "failure is loud on stderr ([ERROR] marker)"
    _chk "$pre" "$(sha "$tdir/MesloLGS-Regular.ttf")" "pre-existing user font byte-identical (hash)"
    local bold="present"
    [[ -f "$tdir/MesloLGS-Bold.ttf" ]] || bold="absent"
    _chk "absent" "$bold" "no partial install of the second font"
    _chk "present" "$(_journal_state rollback fix_terminal_fonts)" "transaction rollback journaled for the failed install"
    _chk "absent" "$(_state_grep 'unbound variable' "$log")" "no unset-variable crash trace"
    echo "    [evidence] permission fix-fonts: rc=$rc user-font-sha=${pre:0:12} bold=$bold journal-rollback=$(_journal_state rollback fix_terminal_fonts)"
    # dry-run equivalence in the same read-only dir: plan only, zero writes
    chmod 555 "$tdir"
    _vrun "$dry_log" "$RUN_LIMIT_S" "$SBX/scripts/fix-terminal-issues.sh" --dry-run fix-fonts
    rc=$?
    chmod u+rwx "$tdir"
    assert_dry_run_green "$rc" "$dry_log"
    _chk "$pre" "$(sha "$tdir/MesloLGS-Regular.ttf")" "dry-run in read-only dir writes nothing (hash)"
    echo "    [evidence] permission fix-fonts dry-run: rc=$rc bytes-hash-stable"
}

# ── 3b. read-only HOME: rc-editor fails after registration, rollback runs ────
test_permission_nvm_readonly_home() {
    if [[ "$(id -u)" == "0" ]]; then
        _mark_skip "permission case is meaningless as root (chmod cannot restrict root)"
        return 0
    fi
    _setup
    printf '# user preamble\nexport EDITOR=vim\n' > "$HOME/.zshrc"
    chmod 444 "$HOME/.zshrc"
    _precreate_txn_infra
    local pre log="$SBX/run-c2.log" dry_log="$SBX/run-c2d.log" rc
    pre=$(sha "$HOME/.zshrc")
    chmod 555 "$SBX/home"
    _vrun "$log" "$RUN_LIMIT_S" "$REAL_NVM" --silent
    rc=$?
    chmod u+rwx "$SBX/home"
    assert_loud_fail_preserved "$rc" "$log" "$HOME/.zshrc" "$pre"
    _chk "present" "$(_journal_state rollback fix_nvm_silent)" "rollback attempted + journaled under the read-only HOME"
    echo "    [evidence] permission fix-nvm: rc=$rc zshrc-sha=${pre:0:12} journal-rollback=$(_journal_state rollback fix_nvm_silent)"
    # dry-run equivalence: same loud failure class, zero writes
    chmod 555 "$SBX/home"
    _vrun_env "$dry_log" "$RUN_LIMIT_S" TRANSACTION_DRY_RUN=1 bash "$REAL_NVM" --dry-run --silent
    rc=$?
    chmod u+rwx "$SBX/home"
    if (( rc != 0 )); then loud="loud"; else loud="silent-success"; fi
    _chk "loud" "$loud" "dry-run under read-only HOME fails loudly the same way (rc=$rc)"
    _chk "$pre" "$(sha "$HOME/.zshrc")" "dry-run under read-only HOME writes nothing (hash)"
    echo "    [evidence] permission fix-nvm dry-run: rc=$rc bytes-hash-stable"
}

# ── 3c. read-only HOME: configure-nvm fails after registration ───────────────
test_permission_setup_versions_readonly() {
    if [[ "$(id -u)" == "0" ]]; then
        _mark_skip "permission case is meaningless as root (chmod cannot restrict root)"
        return 0
    fi
    _setup
    _stub_nvm
    printf '# user preamble\nexport EDITOR=vim\n' > "$HOME/.zshrc"
    chmod 444 "$HOME/.zshrc"
    _precreate_txn_infra
    local pre log="$SBX/run-c3.log" dry_log="$SBX/run-c3d.log" rc
    pre=$(sha "$HOME/.zshrc")
    chmod 555 "$SBX/home"
    _vrun "$log" "$RUN_LIMIT_S" "$REAL_SETUP" configure-nvm
    rc=$?
    chmod u+rwx "$SBX/home"
    assert_loud_fail_preserved "$rc" "$log" "$HOME/.zshrc" "$pre"
    _chk "present" "$(_journal_state rollback setup_versions_nvm)" "rollback attempted + journaled under the read-only HOME"
    echo "    [evidence] permission configure-nvm: rc=$rc zshrc-sha=${pre:0:12} journal-rollback=$(_journal_state rollback setup_versions_nvm)"
    # dry-run equivalence: same loud failure class, zero writes
    chmod 555 "$SBX/home"
    _vrun_env "$dry_log" "$RUN_LIMIT_S" TRANSACTION_DRY_RUN=1 bash "$REAL_SETUP" configure-nvm
    rc=$?
    chmod u+rwx "$SBX/home"
    if (( rc != 0 )); then loud="loud"; else loud="silent-success"; fi
    _chk "loud" "$loud" "dry-run under read-only HOME fails loudly the same way (rc=$rc)"
    _chk "$pre" "$(sha "$HOME/.zshrc")" "dry-run under read-only HOME writes nothing (hash)"
    echo "    [evidence] permission configure-nvm dry-run: rc=$rc bytes-hash-stable"
}

# ── 3d. source-time cache init under a read-only HOME (B1.12-new) ────────────
# lib/cache.sh runs cache_init AT SOURCE TIME. It used to run an unredirected
# batch mkdir there, so ANY strict caller sourcing the chain (e.g.
# setup-versions.sh -> lib/nvm.sh -> lib/cache.sh) died at load under a 555
# HOME. Proven here at the source posture directly: (a) writable HOME keeps
# the cache fully functional (unchanged behavior), (b) a 555 HOME must let
# the sourcing executable survive with a stderr-only degradation warning and
# stdout that carries the caller's output exactly (B2.4 stream contract).
test_cache_source_survives_readonly_home() {
    if [[ "$(id -u)" == "0" ]]; then
        _mark_skip "cache source case is meaningless as root (chmod cannot restrict root)"
        return 0
    fi
    _setup
    local out err rc_w rc_ro
    out=$(mktemp "${TMPDIR:-/tmp}/vms-adverse-cache.XXXXXX")
    err=$(mktemp "${TMPDIR:-/tmp}/vms-adverse-cache.XXXXXX")
    # (a) writable HOME: sourcing + cache set/get unchanged
    env -u CACHE_DIR -u CACHE_ENABLED HOME="$SBX/home" \
        bash -c "set -euo pipefail; source '$ROOT_DIR/lib/cache.sh'; cache_set probe v-probe; printf 'GOT:%s\n' \"\$(cache_get probe 2>/dev/null)\"" >"$out" 2>"$err"
    rc_w=$?
    _chk "zero" "$(_rc_state "$rc_w")" "writable HOME: source-time cache init + set/get unchanged (rc=$rc_w)"
    _chk "GOT:v-probe" "$(tr -d '[:space:]' < "$out")" "writable HOME: cache roundtrip returns the stored value"
    # (b) read-only HOME: source survives, degrades loudly on stderr only
    local ro="$SBX/home-ro"
    mkdir "$ro"
    chmod 555 "$ro"
    : > "$out"; : > "$err"
    env -u CACHE_DIR -u CACHE_ENABLED HOME="$ro" \
        bash -c "set -euo pipefail; source '$ROOT_DIR/lib/cache.sh'; echo SURVIVED" >"$out" 2>"$err"
    rc_ro=$?
    _chk "zero" "$(_rc_state "$rc_ro")" "read-only HOME: sourcing lib/cache.sh does not abort a strict caller (B1.12-new, rc=$rc_ro)"
    _chk "SURVIVED" "$(tr -d '[:space:]' < "$out")" "read-only HOME: stdout carries the caller's output exactly (no cache noise)"
    _chk "present" "$(_state_grep 'degrading' "$err")" "read-only HOME: degradation is warned on stderr (never stdout)"
    local warn_state
    warn_state=$(_state_grep 'degrading' "$err")
    rm -f "$out" "$err"
    echo "    [evidence] cache source probe: writable-rc=$rc_w read-only-rc=$rc_ro survived=yes stderr-warn=$warn_state"
}

# ═════════════════════════════════════════════════════════════════════════════
# GROUP 4 — SYMLINK: ~/.zshrc -> $SBX/user-dotfiles/zshrc-real (outside HOME)
# ═════════════════════════════════════════════════════════════════════════════

# ── 4a. dry-run never touches the link; then apply preserves user content ────
# Order matters: the dry-run runs on the PRISTINE link (proving zero writes),
# then the apply runs on the same pristine state.
test_symlink_nvm_silent() {
    _setup
    _sym_setup
    local userf="$SBX/user-dotfiles/zshrc-real"
    local pre log="$SBX/run-d1.log" dry_log="$SBX/run-d1d.log" rc rl
    pre=$(sha "$userf")
    rl=$(readlink "$HOME/.zshrc")
    # dry-run purity first (pristine link)
    _vrun "$dry_log" "$RUN_LIMIT_S" "$REAL_NVM" --dry-run --silent
    rc=$?
    assert_dry_run_green "$rc" "$dry_log"
    if [[ -L "$HOME/.zshrc" ]]; then dtype="still-symlink"; else dtype="replaced"; fi
    _chk "still-symlink" "$dtype" "dry-run leaves the symlink untouched (zero writes)"
    _chk "$rl" "$(readlink "$HOME/.zshrc")" "dry-run preserves the link target"
    _chk "$pre" "$(sha "$userf")" "dry-run leaves the user dotfiles file byte-identical"
    echo "    [evidence] symlink dry-run: rc=$rc link=$dtype bytes-hash-stable"
    # apply on the same pristine state
    _vrun "$log" "$RUN_LIMIT_S" "$REAL_NVM" --silent
    rc=$?
    assert_symlink_apply "$rc" "$log" "$HOME/.zshrc" "export EDITOR=vim"
    assert_txn_committed fix_nvm_silent
    if [[ -L "$HOME/.zshrc" ]]; then ftype="symlink"; else ftype="regular-file"; fi
    _chk "symlink" "$ftype" "commit path preserves the symlink itself (M2 link semantics, B1.10-new)"
    _chk "$rl" "$(readlink "$HOME/.zshrc" 2>/dev/null)" "link target preserved verbatim through the managed write"
    _chk "present" "$(_state_grep '# BEGIN version-management-setup:nvm' "$userf")" "managed block landed in the RESOLVED user dotfiles file"
    echo "    [evidence] symlink commit path: rc=$rc final-type=$ftype user-sha=$(sha "$userf" | cut -c1-12) tsv-kind=$(_txn_tsv_kind fix_nvm_silent)"
}

# ── 4b. failure path: link intact, user file untouched, rollback RECORDED ───
# Mechanism (B1.10-new/B1.11-new): the managed write's surface is now the
# RESOLVED file's directory, so the read-only injection lands there (555
# user-dotfiles) — the write fails AFTER the link AND the resolved content
# file were registered. The 555 HOME additionally makes the rollback's
# unlink of the registered symlink EACCES — the hostile-unlink condition.
# The rollback branch must guard it (B1.11-new): complete the run, record
# the partial restore (journal + metadata), surface nonzero — never abort
# mid-way under the adopter's set -e losing the record.
test_symlink_rollback_restores_link() {
    if [[ "$(id -u)" == "0" ]]; then
        _mark_skip "rollback-injection needs a user-restricted surface (chmod is a no-op for root)"
        return 0
    fi
    _setup
    _sym_setup
    _precreate_txn_infra
    local userf="$SBX/user-dotfiles/zshrc-real"
    local pre log="$SBX/run-d2.log" rc
    pre=$(sha "$userf")
    chmod 555 "$SBX/home"
    chmod 555 "$SBX/user-dotfiles"   # B1.10-new: the write surface is the resolved file's dir
    _vrun "$log" "$RUN_LIMIT_S" "$REAL_NVM" --silent
    rc=$?
    chmod u+rwx "$SBX/home"
    chmod u+rwx "$SBX/user-dotfiles"
    assert_loud_fail_preserved "$rc" "$log" "$userf" "$pre"
    if [[ -L "$HOME/.zshrc" ]]; then lstate="still-symlink"; else lstate="destroyed"; fi
    _chk "still-symlink" "$lstate" "failed run keeps the ~/.zshrc symlink (M2 link semantics)"
    _chk "$SBX/user-dotfiles/zshrc-real" "$(readlink "$HOME/.zshrc" 2>/dev/null)" "link still points at the user dotfiles file"
    _chk "absent" "$(_state_grep '# BEGIN version-management-setup:nvm' "$userf")" "no managed content written into the user file (no partial write)"
    _chk "present" "$(_journal_state start fix_nvm_silent)" "failed run's link pre-state was registered in the audit journal"
    _chk "present" "$(_journal_state rollback fix_nvm_silent)" "symlink rollback record journaled despite the hostile unlink (B1.11-new)"
    echo "    [evidence] symlink rollback: rc=$rc link=$lstate user-sha=${pre:0:12} block-in-userfile=$(_state_grep '# BEGIN version-management-setup:nvm' "$userf") journal-start=$(_journal_state start fix_nvm_silent) journal-rollback=$(_journal_state rollback fix_nvm_silent)"
}

# ── 4c. second rc adopter (configure-nvm): same symlink semantics ────────────
test_symlink_setup_versions() {
    _setup
    _sym_setup
    _stub_nvm
    local userf="$SBX/user-dotfiles/zshrc-real"
    local pre log="$SBX/run-d3.log" dry_log="$SBX/run-d3d.log" rc rl
    pre=$(sha "$userf")
    rl=$(readlink "$HOME/.zshrc")
    # dry-run purity first (pristine link)
    _vrun_env "$dry_log" "$RUN_LIMIT_S" TRANSACTION_DRY_RUN=1 bash "$REAL_SETUP" configure-nvm
    rc=$?
    assert_dry_run_green "$rc" "$dry_log"
    if [[ -L "$HOME/.zshrc" ]]; then dtype="still-symlink"; else dtype="replaced"; fi
    _chk "still-symlink" "$dtype" "dry-run leaves the symlink untouched (zero writes)"
    _chk "$pre" "$(sha "$userf")" "dry-run leaves the user dotfiles file byte-identical"
    echo "    [evidence] configure-nvm symlink dry-run: rc=$rc link=$dtype bytes-hash-stable"
    # apply on the same pristine state
    _vrun "$log" "$RUN_LIMIT_S" "$REAL_SETUP" configure-nvm
    rc=$?
    assert_symlink_setup "$rc" "$log" "$HOME/.zshrc" "export EDITOR=vim"
    assert_txn_committed setup_versions_nvm
    if [[ -L "$HOME/.zshrc" ]]; then ftype="symlink"; else ftype="regular-file"; fi
    _chk "symlink" "$ftype" "configure-nvm commit preserves the symlink itself (M2 link semantics, B1.10-new)"
    _chk "$rl" "$(readlink "$HOME/.zshrc" 2>/dev/null)" "link target preserved verbatim through the managed write"
    _chk "present" "$(_state_grep '# BEGIN version-management-setup:nvm' "$userf")" "managed block landed in the RESOLVED user dotfiles file"
    echo "    [evidence] configure-nvm symlink commit: rc=$rc final-type=$ftype user-sha=$(sha "$userf" | cut -c1-12) tsv-kind=$(_txn_tsv_kind setup_versions_nvm)"
}

# setup-versions variant of the symlink apply assertion (different txn name).
assert_symlink_setup() {  # $1 rc, $2 log, $3 zshrc, $4 user content line
    _chk "zero" "$(_rc_state "$1")" "configure-nvm apply over a symlinked rc exits 0"
    _chk "present" "$(_state_grep "$4" "$3")" "user dotfiles content survives the managed write"
    _chk "symlink" "$(_txn_tsv_kind setup_versions_nvm)" "transaction registered the pre-state as kind=symlink (M2)"
    _chk "absent" "$(_state_grep 'unbound variable' "$2")" "no unset-variable crash trace"
}

# ── 4d. editor-level pin (B1.10-new): RELATIVE link target, byte-identical
# rerun, link survives write AND remove ───────────────────────────────────────
# Runs the lib/mutation.sh primitives directly (caller-owned transaction) so
# the contract is pinned at the primitive, not only through the adopters:
# relative link targets must resolve (no realpath dependency — cd+pwd), the
# second write must be a byte-identical no-op, and mutation_block_remove must
# keep the link a link too (same rename-over-target defect class).
test_symlink_editor_idempotent() {
    _setup
    mkdir -p "$SBX/user-dotfiles"
    printf '# user dotfiles preamble\nexport EDITOR=vim\n' > "$SBX/user-dotfiles/zshrc-real"
    # RELATIVE link target ON PURPOSE — and via '..' so it still points at the
    # user dotfiles file OUTSIDE the sandbox HOME (exercises the resolver's
    # '..' handling; a dangling link would fail closed by design).
    ln -s ../user-dotfiles/zshrc-real "$HOME/.zshrc"
    local userf="$SBX/user-dotfiles/zshrc-real"
    local blk="$SBX/probe-block"
    printf 'PROBE-CONTENT-v1\n' > "$blk"
    source "$ROOT_DIR/lib/mutation.sh"
    local rl_pre ok d
    rl_pre=$(readlink "$HOME/.zshrc")
    transaction_start b1_10_probe >/dev/null 2>&1
    if mutation_block_write "$HOME/.zshrc" b1_10_probe "$blk" >/dev/null 2>&1; then ok="written"; else ok="failed"; fi
    _chk "written" "$ok" "editor-level managed write over a symlinked rc exits 0"
    if [[ -L "$HOME/.zshrc" ]]; then d="still-symlink"; else d="replaced"; fi
    _chk "still-symlink" "$d" "editor commit keeps the link a link (B1.10-new)"
    _chk "$rl_pre" "$(readlink "$HOME/.zshrc" 2>/dev/null)" "RELATIVE link target preserved verbatim"
    _chk "present" "$(_state_grep 'PROBE-CONTENT-v1' "$userf")" "content written into the resolved dotfiles file"
    transaction_commit >/dev/null 2>&1
    local h1 h2
    h1=$(sha "$userf")
    transaction_start b1_10_probe >/dev/null 2>&1
    mutation_block_write "$HOME/.zshrc" b1_10_probe "$blk" >/dev/null 2>&1
    transaction_commit >/dev/null 2>&1
    h2=$(sha "$userf")
    _chk "$h1" "$h2" "byte-identical rerun is a no-op (idempotency over a symlink)"
    if [[ -L "$HOME/.zshrc" ]]; then d="still-symlink"; else d="replaced"; fi
    _chk "still-symlink" "$d" "rerun leaves the link intact"
    # remove path (same M2 semantics): block gone from the resolved file, link survives
    transaction_start b1_10_probe >/dev/null 2>&1
    mutation_block_remove "$HOME/.zshrc" b1_10_probe >/dev/null 2>&1
    transaction_commit >/dev/null 2>&1
    _chk "absent" "$(_state_grep 'PROBE-CONTENT-v1' "$userf")" "block removed from the resolved file"
    if [[ -L "$HOME/.zshrc" ]]; then d="still-symlink"; else d="replaced"; fi
    _chk "still-symlink" "$d" "remove keeps the link a link (B1.10-new, same-class)"
    _chk "symlink" "$(_txn_tsv_kind b1_10_probe)" "first registered pre-state is the link itself (kind=symlink)"
    echo "    [evidence] editor probe: write+rerun+remove link=$d user-sha=$(sha "$userf" | cut -c1-12) tsv-kind=$(_txn_tsv_kind b1_10_probe)"
}

# ── 4e. legacy-strip through a symlinked rc (Lane Y handoffs, B1.10-new
# class): drift lines are seeded in the USER dotfiles file; the strip
# helpers must operate on the RESOLVED content file. The pre-fix helpers
# mktemp'd beside the link and renamed over the LINK path, destroying it.
test_symlink_strip_fix_nvm() {
    _setup
    _sym_setup
    _stub_nvm
    local userf="$SBX/user-dotfiles/zshrc-real"
    local rl log="$SBX/run-d5.log" rc ftype
    printf '# user preamble\n# NVM Permanent Silence Configuration\nexport EDITOR=vim\n' > "$userf"
    rl=$(readlink "$HOME/.zshrc")
    _vrun "$log" "$RUN_LIMIT_S" "$REAL_NVM" --silent
    rc=$?
    _chk "zero" "$(_rc_state "$rc")" "fix-nvm apply with seeded drift over a symlinked rc exits 0"
    if [[ -L "$HOME/.zshrc" ]]; then ftype="still-symlink"; else ftype="replaced"; fi
    _chk "still-symlink" "$ftype" "legacy strip keeps the symlink (strip must resolve, not rename over the link, B1.10-new class)"
    _chk "$rl" "$(readlink "$HOME/.zshrc" 2>/dev/null)" "link target preserved through the strip"
    _chk "absent" "$(_state_grep 'NVM Permanent Silence Configuration' "$userf")" "legacy drift line removed from the RESOLVED user file"
    _chk "present" "$(_state_grep '# BEGIN version-management-setup:nvm' "$userf")" "managed block present in the resolved user file"
    echo "    [evidence] strip fix-nvm: rc=$rc link=$ftype drift-gone user-sha=$(sha "$userf" | cut -c1-12)"
}

test_symlink_strip_setup_versions() {
    _setup
    _sym_setup
    _stub_nvm
    local userf="$SBX/user-dotfiles/zshrc-real"
    local rl log="$SBX/run-d6.log" rc ftype
    printf '# user preamble\nexport NVM_SILENT=true\nexport EDITOR=vim\n' > "$userf"
    rl=$(readlink "$HOME/.zshrc")
    _vrun "$log" "$RUN_LIMIT_S" "$REAL_SETUP" configure-nvm
    rc=$?
    _chk "zero" "$(_rc_state "$rc")" "configure-nvm apply with seeded drift over a symlinked rc exits 0"
    if [[ -L "$HOME/.zshrc" ]]; then ftype="still-symlink"; else ftype="replaced"; fi
    _chk "still-symlink" "$ftype" "legacy strip keeps the symlink (setup-versions strip, B1.10-new class)"
    _chk "$rl" "$(readlink "$HOME/.zshrc" 2>/dev/null)" "link target preserved through the strip"
    _chk "absent" "$(_state_grep 'export NVM_SILENT=true' "$userf")" "legacy exported NVM_SILENT removed from the RESOLVED user file"
    _chk "present" "$(_state_grep '# BEGIN version-management-setup:nvm' "$userf")" "managed block present in the resolved user file"
    echo "    [evidence] strip setup-versions: rc=$rc link=$ftype drift-gone user-sha=$(sha "$userf" | cut -c1-12)"
}

# ═════════════════════════════════════════════════════════════════════════════
# NEGATIVE CONTROLS (directive Rule 5) — property-violating stubs fed through
# the SAME assertion helpers must trip them; a non-tripping control fails.
# ═════════════════════════════════════════════════════════════════════════════

# Control 1 (clean-home): claims success, writes PARTIAL content, exits 0.
test_control_clean_home() {
    _setup
    local log="$SBX/nc1.log" stub="$SBX/nc1-stub.sh"
    cat > "$stub" <<EOF
#!/usr/bin/env bash
# VIOLATING STUB: partial write + fake success + exit 0.
head -c 60 "$P10K_SOURCE" > "$HOME/.p10k.zsh" 2>/dev/null || printf 'partial\n' > "$HOME/.p10k.zsh"
echo "stub: p10k fixed successfully"
exit 0
EOF
    chmod +x "$stub"
    local rc
    _vrun "$log" "$NC_LIMIT_S" "$stub"
    rc=$?
    assert_p10k_created_full "$rc" "$log"
}

# Control 2 (no-network): partial legacy-drift mutation, then hangs — the
# watchdog must kill it (rc=124) and the block assertions must trip.
test_control_no_network() {
    _setup
    _mocks_install
    printf '# user preamble\nexport EDITOR=vim\n' > "$HOME/.zshrc"
    local log="$SBX/nc2.log" stub="$SBX/nc2-stub.sh"
    cat > "$stub" <<EOF
#!/usr/bin/env bash
# VIOLATING STUB: partial mutation (P1-3 drift) then hang.
printf 'export NVM_SILENT=1\n' >> "$HOME/.zshrc"
sleep 300
EOF
    chmod +x "$stub"
    local rc
    _vrun_env "$log" "$NC_LIMIT_S" PATH="$MOCKS:$PATH" bash "$stub"
    rc=$?
    assert_bounded "$rc"
    assert_nvm_block_applied "$rc" "$log" "$HOME/.zshrc" "export EDITOR=vim"
}

# Control 3 (permission): DEFEATS the read-only surface, writes partial,
# exits 0 — proves the loud-fail + hash-identical assertions have teeth.
test_control_permission() {
    if [[ "$(id -u)" == "0" ]]; then
        _mark_skip "permission control is meaningless as root (chmod cannot restrict root)"
        return 0
    fi
    _setup
    printf '# user preamble\nexport EDITOR=vim\n' > "$HOME/.zshrc"
    chmod 444 "$HOME/.zshrc"
    local pre log="$SBX/nc3.log" stub="$SBX/nc3-stub.sh"
    pre=$(sha "$HOME/.zshrc")
    cat > "$stub" <<EOF
#!/usr/bin/env bash
# VIOLATING STUB: defeats the read-only file, writes partial, exits 0.
chmod u+w "$HOME/.zshrc"
printf 'VIOLATING-PARTIAL\n' > "$HOME/.zshrc"
echo "stub: fixed successfully"
exit 0
EOF
    chmod +x "$stub"
    local rc
    _vrun "$log" "$NC_LIMIT_S" "$stub"
    rc=$?
    assert_loud_fail_preserved "$rc" "$log" "$HOME/.zshrc" "$pre"
}

# Control 4 (symlink): destroys the link, strips user content, exits 0 —
# proves the content-survival + kind=symlink registration assertions bite.
test_control_symlink() {
    _setup
    _sym_setup
    local log="$SBX/nc4.log" stub="$SBX/nc4-stub.sh"
    cat > "$stub" <<EOF
#!/usr/bin/env bash
# VIOLATING STUB: destroys the link, strips user content, exits 0.
rm -f "$HOME/.zshrc"
printf '# BEGIN version-management-setup:nvm\nexport NVM_SILENT=1\n# END version-management-setup:nvm\n' > "$HOME/.zshrc"
echo "stub: applied"
exit 0
EOF
    chmod +x "$stub"
    local rc
    _vrun "$log" "$NC_LIMIT_S" "$stub"
    rc=$?
    assert_symlink_apply "$rc" "$log" "$HOME/.zshrc" "export EDITOR=vim"
}

# ── Case runners ──────────────────────────────────────────────────────────────
# Fresh counters, guaranteed teardown, honest exit status. Control cases
# REUSE the same assertion helpers in NC_MODE and must trip at least one
# assertion; a control that trips nothing fails the suite (no teeth).
run_case() {
    local name="$1"
    shift
    CASE_FAILS=0
    CASE_SKIP=0
    NC_MODE=0
    NC_TRIPPED=0
    "$@"
    local failed=$CASE_FAILS skipped=$CASE_SKIP
    _teardown
    if (( skipped )); then
        SKIPPED_CASES=$((SKIPPED_CASES + 1))
        echo "    [case $name] SKIPPED (marked) — not counted as a pass"
        return 0
    fi
    if (( failed > 0 )); then
        echo "    [case $name] $failed assertion(s) failed"
        return 1
    fi
    return 0
}

run_control_case() {
    local name="$1"
    shift
    CASE_FAILS=0
    CASE_SKIP=0
    NC_MODE=1
    NC_TRIPPED=0
    "$@"
    NC_MODE=0
    local tripped=$NC_TRIPPED failed=$CASE_FAILS skipped=$CASE_SKIP
    _teardown
    if (( skipped )); then
        SKIPPED_CASES=$((SKIPPED_CASES + 1))
        echo "    [control $name] SKIPPED (marked) — not counted as a pass"
        return 0
    fi
    if (( failed > 0 )); then
        echo "    [control $name] $failed harness assertion(s) failed"
        return 1
    fi
    if (( tripped > 0 )); then
        echo "    [evidence] NEGATIVE CONTROL $name RED (expected): $tripped assertion(s) tripped"
        return 0
    fi
    echo "    [control $name] DID NOT TRIP — assertions have no teeth"
    return 1
}

# ── Suite ─────────────────────────────────────────────────────────────────────
failures=0
controls=0

# GROUP 1: clean-HOME
run_case clean-home-terminal-p10k       test_clean_home_terminal_p10k            || failures=$((failures + 1))
run_case clean-home-nvm-silent          test_clean_home_nvm_silent               || failures=$((failures + 1))
run_case clean-home-setup-versions      test_clean_home_setup_versions           || failures=$((failures + 1))
run_case clean-home-dry-run-p10k        test_clean_home_dry_run_p10k             || failures=$((failures + 1))
run_case clean-home-dry-run-rc-editors  test_clean_home_dry_run_rc_editors       || failures=$((failures + 1))

# GROUP 2: no-network
run_case network-mocks-active           test_network_mocks_active                || failures=$((failures + 1))
run_case no-network-nvm-silent          test_no_network_nvm_silent               || failures=$((failures + 1))
run_case no-network-setup-versions      test_no_network_setup_versions           || failures=$((failures + 1))
run_case no-network-terminal-p10k       test_no_network_terminal_p10k            || failures=$((failures + 1))

# GROUP 3: permission
run_case permission-fonts-readonly-dir  test_permission_fonts_readonly           || failures=$((failures + 1))
run_case permission-nvm-readonly-home   test_permission_nvm_readonly_home        || failures=$((failures + 1))
run_case permission-setup-versions      test_permission_setup_versions_readonly  || failures=$((failures + 1))
run_case cache-source-readonly-home     test_cache_source_survives_readonly_home || failures=$((failures + 1))

# GROUP 4: symlink
run_case symlink-nvm-silent             test_symlink_nvm_silent                  || failures=$((failures + 1))
run_case symlink-rollback-restores-link test_symlink_rollback_restores_link      || failures=$((failures + 1))
run_case symlink-setup-versions         test_symlink_setup_versions              || failures=$((failures + 1))
run_case symlink-editor-idempotent      test_symlink_editor_idempotent           || failures=$((failures + 1))
run_case symlink-strip-fix-nvm          test_symlink_strip_fix_nvm               || failures=$((failures + 1))
run_case symlink-strip-setup-versions   test_symlink_strip_setup_versions        || failures=$((failures + 1))

# NEGATIVE CONTROLS (red-then-green per directive Rule 5)
run_control_case control-clean-home     test_control_clean_home                  || controls=$((controls + 1))
run_control_case control-no-network     test_control_no_network                  || controls=$((controls + 1))
run_control_case control-permission     test_control_permission                  || controls=$((controls + 1))
run_control_case control-symlink        test_control_symlink                     || controls=$((controls + 1))

echo ""
echo "====== Adverse-Condition Summary ======"
echo "scenario cases: 19 (failed: $failures, marked-skips: $SKIPPED_CASES)"
echo "negative controls: 4 (untripped: $controls — 0 required)"
echo "======================================"

if (( failures > 0 || controls > 0 )); then
    echo "test_adverse_conditions.sh: $failures scenario case(s) failed, $controls negative-control case(s) failed"
    exit 1
fi
echo "test_adverse_conditions.sh: all scenario cases green; all negative controls tripped red as expected"
exit 0
