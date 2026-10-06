#!/usr/bin/env bash
# =============================================================================
# update-global-node-symlinks Managed-Mutation Adoption Tests (M4 / P3-1)
# =============================================================================
# Per-adopter GO criteria: the privileged mutation sequence runs under a
# lib/backup.sh transaction — hash-verified registration of every
# /usr/local/bin destination BEFORE mutation, audit-journal records via the
# primitive, commit on success, rollback + loud nonzero on injected failure;
# byte-compare skip makes idempotent reruns churn-free; plan-by-default and
# the --confirm gate are preserved. No test ever touches the real $HOME.
#
# PRIVILEGE RULE (M3): every privileged-path test runs tests/shims/sudo FIRST
# on PATH — it records full argv and performs NO elevation. The one exception
# is the failure-injection case, which installs a sandbox-local sudo double
# with the SAME recording discipline that exits 1: the canonical shim cannot
# fail by design, and "a sudo that refuses (policy/prompt)" is the root-proof
# way to drive the rollback path. Neither double executes the wrapped command.
#
# SCOPE NOTE (honest NO-GO): /usr/local/bin is hardcoded in the tool — NOT
# sandbox-parameterizable. Symlink state after a "successful" apply is
# therefore NOT observable in-sandbox (the recording shim deliberately applies
# nothing). The matrix asserts plan/backup paths in-sandbox plus sudo argv +
# transaction + audit-journal records. The byte-compare skip is exercised
# (i) end-to-end only where the host already has a readable
# /usr/local/bin/node whose bytes can be mirrored into the fake NVM tree
# (capability-gated, skip reported as its own assertion), and (ii)
# deterministically at the predicate level against sandbox paths.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# CWD-independent: resolves regardless of where the suite is invoked from.
source "$SCRIPT_DIR/../helpers.sh"

set +e

CASE_FAILED=0
chk() { "$@" || CASE_FAILED=1; }

sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }

FAKE_NODE_VERSION="22.17.0"
TOOL="$ROOT_DIR/tools/update-global-node-symlinks.sh"

# Newest transaction dir for a transaction name (empty string when absent).
_txn_dir() {
    local d
    d=$(ls -d "$HOME/.config-backups/transactions/$1."* 2>/dev/null | sort | tail -1)
    printf '%s' "$d"
}

# Canonical audit-journal location (lib/backup.sh default under sandboxed HOME).
_journal() { printf '%s' "$HOME/.config/version-manager/audit.log"; }

_setup() {
    SBX=$(mktemp -d "${TMPDIR:-/tmp}/vms-symlinks.XXXXXX")
    export HOME="$SBX"
    unset TXN_AUDIT_LOG TRANSACTION_DRY_RUN 2>/dev/null || true
    mkdir -p "$SBX/tmp"
    export TMPDIR="$SBX/tmp"
    export SUDO_SHIM_LOG="$SBX/sudo-shim.log"
    : > "$SUDO_SHIM_LOG"
    # Recording shim FIRST on PATH (M3 privilege rule).
    export PATH="$ROOT_DIR/tests/shims:$PATH"
    # Fake NVM installation: nvm.sh stub + fake versioned binaries.
    mkdir -p "$SBX/.nvm/versions/node/v$FAKE_NODE_VERSION/bin"
    cat > "$SBX/.nvm/nvm.sh" <<NVMSH
nvm() {
    case "\${1:-}" in
        current) printf 'v$FAKE_NODE_VERSION' ;;
        --version) printf '0.0.0-sandbox' ;;
    esac
    return 0
}
NVMSH
    export NVM_DIR="$SBX/.nvm"
    for cmd in node npm npx; do
        printf '#!/bin/sh\necho fake-%s\n' "$cmd" > "$NVM_DIR/versions/node/v$FAKE_NODE_VERSION/bin/$cmd"
        chmod +x "$NVM_DIR/versions/node/v$FAKE_NODE_VERSION/bin/$cmd"
    done
}

_teardown() {
    [[ -n "${SBX:-}" && "$SBX" == */vms-symlinks.* ]] && rm -rf "$SBX"
    unset HOME NVM_DIR TMPDIR SUDO_SHIM_LOG 2>/dev/null || true
}

# ── a. Apply (via recording shim): transaction + audit journal + shim argv ───
test_apply_records_transaction_journal_and_argv() {
    CASE_FAILED=0
    _setup
    local out rc
    out=$(bash "$TOOL" --confirm 2>&1)
    rc=$?
    chk assert_equals "0" "$rc" "apply via recording shim exits zero"
    # The privileged invocation path is preserved verbatim: three sudo ln -sf
    # calls with exactly the pre-adoption argv, recorded by the shim.
    for cmd in node npm npx; do
        chk assert_contains \
            "$(printf 'ln\t-sf\t%s/versions/node/v%s/bin/%s\t/usr/local/bin/%s' "$NVM_DIR" "$FAKE_NODE_VERSION" "$cmd" "$cmd")" \
            "$(cat "$SUDO_SHIM_LOG" 2>/dev/null)" \
            "recording shim captured sudo ln -sf argv for $cmd"
    done
    # Transaction (P3-1): destinations registered BEFORE mutation, committed.
    local tdir
    tdir=$(_txn_dir update_node_symlinks)
    chk assert_file_exists "$tdir/metadata.json" "transaction directory + metadata exist for update_node_symlinks"
    chk assert_contains '"status": "committed"' "$(cat "$tdir/metadata.json" 2>/dev/null)" "transaction committed"
    chk assert_equals "3" "$(cat "$tdir/files.tsv" "$tdir/new_files.txt" 2>/dev/null | grep -c '/usr/local/bin/')" \
        "all three /usr/local/bin destinations registered with the transaction"
    # Audit journal (P3-2): start + commit recorded by the primitive itself.
    chk assert_contains "$(printf '\tstart\tupdate_node_symlinks\t')" "$(cat "$(_journal)" 2>/dev/null)" \
        "audit journal: transaction start recorded"
    chk assert_contains "$(printf '\tcommit\tupdate_node_symlinks\t')" "$(cat "$(_journal)" 2>/dev/null)" \
        "audit journal: transaction commit recorded"
    _teardown
    return "$CASE_FAILED"
}

# ── b2. Skip predicate + portable byte-compare, sandbox-deterministic ────────
# Runs the tool's own skip predicate against sandbox paths (never
# /usr/local/bin). Sourcing the tool must NOT execute main (execution guard).
_test_shell() {
    (
        unset -f log_info log_warn log_error log_success log_debug init_logger 2>/dev/null || true
        # shellcheck source=tools/update-global-node-symlinks.sh
        source "$TOOL"
        if declare -F symlink_dest_matches >/dev/null 2>&1; then
            symlink_dest_matches "$1" "$2"
        else
            echo "PREDICATE-MISSING"
            exit 97
        fi
    ) 2>&1
}

test_skip_predicate_byte_compare() {
    CASE_FAILED=0
    _setup
    local fd="$SBX/fakebin"
    mkdir -p "$fd" "$SBX/nvmbin"
    printf 'same-bytes\n' > "$fd/node"
    printf 'same-bytes\n' > "$SBX/nvmbin/node"     # identical pair
    printf 'aaa\n' > "$fd/npm"
    printf 'bbb\n' > "$SBX/nvmbin/npm"             # differing pair
    ln -s "$SBX/nvmbin/node" "$fd/npx"             # symlink -> identical-bytes target
    printf 'zzz\n' > "$SBX/nvmbin/other"
    ln -s "$SBX/nvmbin/other" "$fd/npmlink"        # symlink -> differing target
    local probe prc
    probe=$(_test_shell "$fd/node" "$SBX/nvmbin/node")
    prc=$?
    if grep -q "Dry run only" <<<"$probe"; then
        chk assert_equals "no-main-on-source" "main-executed" "sourcing the tool must NOT execute main (execution guard)"
    else
        chk assert_equals "no-main-on-source" "no-main-on-source" "sourcing the tool does not execute main"
    fi
    chk assert_equals "0" "$prc" "identical bytes -> skip predicate true (regular-file dest)"
    chk assert_equals "0" "$(_test_shell "$fd/npx" "$SBX/nvmbin/node" >/dev/null 2>&1; echo $?)" \
        "symlink -> identical target bytes -> skip true"
    chk assert_equals "1" "$(_test_shell "$fd/npm" "$SBX/nvmbin/npm" >/dev/null 2>&1; echo $?)" \
        "differing bytes -> skip predicate false"
    chk assert_equals "1" "$(_test_shell "$fd/npmlink" "$SBX/nvmbin/node" >/dev/null 2>&1; echo $?)" \
        "symlink -> differing target -> skip false"
    chk assert_equals "1" "$(_test_shell "$fd/absent" "$SBX/nvmbin/node" >/dev/null 2>&1; echo $?)" \
        "absent destination -> skip false (must create)"
    chk assert_equals "1" "$(_test_shell "$fd/node" "$SBX/nvmbin/gone" >/dev/null 2>&1; echo $?)" \
        "missing source -> skip false"
    _teardown
    return "$CASE_FAILED"
}

# ── b. Idempotent rerun: byte-identical destination -> no privileged churn ───
# Capability-gated: only exercisable where /usr/local/bin/node exists, is
# readable, and its bytes can be mirrored into the fake NVM tree. Otherwise
# the skip is reported as its own assertion (never a silent pass).
test_idempotent_skip_capability() {
    CASE_FAILED=0
    _setup
    if [[ -e /usr/local/bin/node && -r /usr/local/bin/node ]]; then
        # SC2031 disabled: false positive — the _test_shell subshell SOURCES the
        # tool (defining verify_nvm_installation, which assigns NVM_DIR) but
        # never executes it; NVM_DIR here is this function's exported value.
        # shellcheck disable=SC2031
        cp /usr/local/bin/node "$NVM_DIR/versions/node/v$FAKE_NODE_VERSION/bin/node" 2>/dev/null
        # shellcheck disable=SC2031
        if [[ -f "$NVM_DIR/versions/node/v$FAKE_NODE_VERSION/bin/node" ]] \
            && [[ "$(sha /usr/local/bin/node)" == "$(sha "$NVM_DIR/versions/node/v$FAKE_NODE_VERSION/bin/node")" ]]; then
            bash "$TOOL" --confirm >/dev/null 2>&1
            local rc=$?
            chk assert_equals "0" "$rc" "apply with byte-identical node destination exits zero"
            local node_lines
            node_lines=$(grep -c '/usr/local/bin/node$' "$SUDO_SHIM_LOG" 2>/dev/null)
            [[ -z "$node_lines" ]] && node_lines=0
            chk assert_equals "0" "$node_lines" "byte-identical /usr/local/bin/node skipped (no sudo churn)"
            chk assert_contains "already identical" "$(bash "$TOOL" --confirm 2>&1)" \
                "skip logged as 'already identical'"
        else
            chk assert_equals "skip-copy" "skip-copy" \
                "could not mirror host node bytes (capability partial — reported, not silently passed)"
        fi
    else
        chk assert_equals "skip-capability" "skip-capability" \
            "no readable /usr/local/bin/node on this host — e2e skip not exercisable (reported, not silently passed)"
    fi
    _teardown
    return "$CASE_FAILED"
}

# ── c. Injected sudo failure: loud nonzero + rollback record (root-proof) ────
test_injected_sudo_failure_rolls_back_loud() {
    CASE_FAILED=0
    _setup
    # Capability guard: on a host where /usr/local/bin is user-writable AND
    # holds real entries, the transaction primitive's unprivileged rollback
    # could rewrite (unlink+recreate) a real privileged path. The test refuses
    # that risk and reports the capability instead.
    local risky=0
    if [[ -w /usr/local/bin ]]; then
        for cmd in node npm npx; do
            [[ -e "/usr/local/bin/$cmd" ]] && risky=1
        done
    fi
    if [[ $risky -eq 1 ]]; then
        chk assert_equals "skip-capability" "skip-capability" \
            "user-writable /usr/local/bin with live entries — rollback case skipped to avoid real-path writes"
        _teardown
        return "$CASE_FAILED"
    fi
    # Sandbox sudo double: SAME recording discipline as tests/shims/sudo
    # (argv appended, command never executed, no elevation) but exit 1 —
    # simulates a sudo that refuses (policy/prompt).
    mkdir -p "$SBX/failbin"
    cat > "$SBX/failbin/sudo" <<'FAILSUDO'
#!/usr/bin/env bash
line=""
for arg in "$@"; do
    [[ -n "$line" ]] && line+=$'\t'
    line+="$arg"
done
[[ -n "${SUDO_SHIM_LOG:-}" ]] && printf '%s\n' "$line" >> "$SUDO_SHIM_LOG" 2>/dev/null
exit 1
FAILSUDO
    chmod +x "$SBX/failbin/sudo"
    export PATH="$SBX/failbin:$PATH"
    bash "$TOOL" --confirm >/dev/null 2>&1
    local rc=$?
    [[ $rc -ne 0 ]] \
        && chk assert_equals "loud" "loud" "injected sudo failure exits nonzero" \
        || chk assert_equals "loud" "silent-success" "injected sudo failure MUST exit nonzero"
    chk assert_contains "$(printf '\trollback\tupdate_node_symlinks\t')" "$(cat "$(_journal)" 2>/dev/null)" \
        "audit journal records the rollback of update_node_symlinks"
    local tdir
    tdir=$(_txn_dir update_node_symlinks)
    if [[ -n "$tdir" && -f "$tdir/metadata.json" ]]; then
        chk assert_contains "rolled_back" "$(cat "$tdir/metadata.json")" "transaction metadata shows the rollback"
        if grep -q '"status": "committed"' "$tdir/metadata.json"; then
            chk assert_equals "not-committed" "committed" "failed run must NOT commit"
        else
            chk assert_equals "not-committed" "not-committed" "failed run never commits"
        fi
    else
        chk assert_equals "txn-dir" "missing" "transaction dir must exist even for a failed run (records the attempt)"
    fi
    _teardown
    return "$CASE_FAILED"
}

# ── c1. Pre-flight fail-closed: backup failure aborts before ANY sudo ────────
test_preflight_failclosed_zero_sudo() {
    CASE_FAILED=0
    _setup
    # Root-proof injection: permission bits do not stop root (the hosted CI
    # agents run as root — chmod 000 silently succeeded there, build #29).
    # Making TMPDIR resolve THROUGH a regular file fails mkdir -p with
    # ENOTDIR for every uid.
    printf 'not a directory\n' > "$SBX/notadir"
    export TMPDIR="$SBX/notadir/inner"
    bash "$TOOL" --confirm >/dev/null 2>&1
    local rc=$?
    unset TMPDIR
    [[ $rc -ne 0 ]] \
        && chk assert_equals "loud" "loud" "unwritable backup location exits nonzero" \
        || chk assert_equals "loud" "silent-success" "unwritable backup location MUST exit nonzero"
    chk assert_equals "" "$(cat "$SUDO_SHIM_LOG" 2>/dev/null)" \
        "backup failure aborts BEFORE any privileged invocation"
    chk assert_equals "" "$(_txn_dir update_node_symlinks)" \
        "backup failure aborts BEFORE any transaction"
    _teardown
    return "$CASE_FAILED"
}

# ── d. Plan/dry-run: zero writes preserved (plan-by-default regression) ──────
test_plan_mode_zero_writes() {
    CASE_FAILED=0
    _setup
    local out rc
    out=$(bash "$TOOL" 2>&1)
    rc=$?
    chk assert_equals "0" "$rc" "plan (no args) exits zero"
    chk assert_contains "Dry run only" "$out" "plan mode announces dry-run"
    chk assert_equals "" "$(cat "$SUDO_SHIM_LOG" 2>/dev/null)" "plan performs zero privileged invocations"
    chk assert_equals "" "$(_txn_dir update_node_symlinks)" "plan creates no transaction"
    if [[ -e "$(_journal)" ]]; then
        chk assert_equals "no-journal" "journal-present" "plan must not write the audit journal"
    else
        chk assert_equals "no-journal" "no-journal" "plan writes no audit journal"
    fi
    # explicit --dry-run flag
    : > "$SUDO_SHIM_LOG"
    out=$(bash "$TOOL" --dry-run 2>&1)
    rc=$?
    chk assert_equals "0" "$rc" "--dry-run exits zero"
    chk assert_equals "" "$(cat "$SUDO_SHIM_LOG" 2>/dev/null)" "--dry-run zero privileged invocations"
    # status subcommand is read-only
    : > "$SUDO_SHIM_LOG"
    out=$(bash "$TOOL" status 2>&1)
    rc=$?
    chk assert_equals "0" "$rc" "status exits zero"
    chk assert_equals "" "$(cat "$SUDO_SHIM_LOG" 2>/dev/null)" "status performs zero privileged invocations"
    _teardown
    return "$CASE_FAILED"
}

# ── d2. TRANSACTION_DRY_RUN=1 + --confirm: zero privileged writes ────────────
# The lib contract (plan-only transaction, zero filesystem writes) must hold
# for the whole apply path, including the privileged mutation sequence.
test_transaction_dry_run_zero_writes() {
    CASE_FAILED=0
    _setup
    local out rc
    out=$(TRANSACTION_DRY_RUN=1 bash "$TOOL" --confirm 2>&1)
    rc=$?
    chk assert_equals "0" "$rc" "TRANSACTION_DRY_RUN=1 apply exits zero"
    chk assert_equals "" "$(cat "$SUDO_SHIM_LOG" 2>/dev/null)" \
        "TRANSACTION_DRY_RUN=1 performs zero privileged invocations"
    chk assert_equals "" "$(_txn_dir update_node_symlinks)" \
        "TRANSACTION_DRY_RUN=1 creates no transaction directory (zero writes)"
    chk assert_contains "Transaction (dry-run, zero writes)" "$out" \
        "dry-run transaction remains visible on the console"
    chk assert_file_not_exists "$(_journal)" \
        "dry-run transaction does not write an audit journal"
    _teardown
    return "$CASE_FAILED"
}

# ── e. Restore path: plan gate preserved; --confirm runs under a transaction ─
test_restore_gate_and_transaction() {
    CASE_FAILED=0
    _setup
    mkdir -p "$SBX/fakebackup"
    for cmd in node npm npx; do
        printf '#!/bin/sh\n' > "$SBX/fakebackup/$cmd"
        chmod +x "$SBX/fakebackup/$cmd"
    done
    # e1: restore WITHOUT --confirm -> plan only, zero privileged writes.
    local out rc
    out=$(bash "$TOOL" restore "$SBX/fakebackup" 2>&1)
    rc=$?
    chk assert_equals "0" "$rc" "restore plan exits zero"
    chk assert_contains "Plan to restore" "$out" "restore plan printed"
    chk assert_equals "" "$(cat "$SUDO_SHIM_LOG" 2>/dev/null)" "restore plan performs zero privileged invocations"
    # e2: restore WITH --confirm -> shim cp argv + transaction + journal.
    out=$(bash "$TOOL" --confirm restore "$SBX/fakebackup" 2>&1)
    rc=$?
    chk assert_equals "0" "$rc" "confirm restore via recording shim exits zero"
    chk assert_contains "$(printf 'cp\t-P\t%s/fakebackup/node\t/usr/local/bin/' "$SBX")" \
        "$(cat "$SUDO_SHIM_LOG" 2>/dev/null)" \
        "recording shim captured sudo cp -P restore argv"
    local tdir
    tdir=$(_txn_dir restore_node_symlinks)
    chk assert_file_exists "$tdir/metadata.json" "restore transaction metadata exists"
    chk assert_contains '"status": "committed"' "$(cat "$tdir/metadata.json" 2>/dev/null)" "restore transaction committed"
    chk assert_contains "$(printf '\tcommit\trestore_node_symlinks\t')" "$(cat "$(_journal)" 2>/dev/null)" \
        "audit journal: restore commit recorded"
    _teardown
    return "$CASE_FAILED"
}

failures=0
test_apply_records_transaction_journal_and_argv || failures=$((failures + 1))
test_skip_predicate_byte_compare || failures=$((failures + 1))
test_idempotent_skip_capability || failures=$((failures + 1))
test_injected_sudo_failure_rolls_back_loud || failures=$((failures + 1))
test_preflight_failclosed_zero_sudo || failures=$((failures + 1))
test_plan_mode_zero_writes || failures=$((failures + 1))
test_transaction_dry_run_zero_writes || failures=$((failures + 1))
test_restore_gate_and_transaction || failures=$((failures + 1))

if [[ "$failures" -gt 0 ]]; then
    echo "test_symlinks_managed.sh: $failures case(s) failed"
    exit 1
fi
