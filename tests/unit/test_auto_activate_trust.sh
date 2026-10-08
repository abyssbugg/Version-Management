#!/usr/bin/env bash
# =============================================================================
# Auto-Activation Trust-Boundary Tests (remediation directive B1.2)
# =============================================================================
# Binding model (directive): directory hooks may only SWITCH between
# already-installed versions. Everything else — sourcing repo-controlled
# scripts (.venv/bin/activate), installing MISSING versions, privileged
# /usr/local/bin symlink sync (ln -sf / sudo -n ln -sf) — requires an
# EXPLICIT, per-project trusted capability in a persistent registry:
#
#   $HOME/.config/version-manager/trusted-projects
#   <sha256-of-canonical-project-dir><TAB><capability>
#
#   capabilities: venv_source | node_install | symlink_sync
#
# When a capability is not trusted the hook must do NOTHING for it
# (no prompt, no write, no install; at most a logger notice).
#
# Privilege testing contract: real sudo is NEVER invoked and nothing is ever
# written to /usr/local/bin. All privileged paths are exercised through
# tests/shims/sudo (recording shim, no elevation) plus a runtime-generated
# recording `ln` shim that fails (exit 1) so the sudo fallback is reached —
# exactly the non-root permission-failure shape the vulnerability rode on.
# =============================================================================

source "${BASH_SOURCE[0]%/*}/../helpers.sh" || { echo "FATAL: cannot source helpers.sh — run via tests/test_runner.sh (P0-3: unsandboxed HOME writes forbidden)" >&2; exit 1; }

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Sandbox HOME BEFORE sourcing the library: logger.sh / backup.sh capture
# sandboxed paths ($DEFAULT_BACKUP_DIR, registry dir) at source time.
setup_test

SILENT_MODE=true   # keep assertion output readable; failures still assert

source "$ROOT_DIR/lib/auto-activate.sh"

REGISTRY_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/version-manager/trusted-projects"

failures=0

# ── fixtures ─────────────────────────────────────────────────────────────────
_new_project() {
    # $1 = name; echoes the project dir; creates the dir only.
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/vms-trust-proj.XXXXXX")"
    printf '%s\n' "$d"
}

_make_venv_canary() {
    # $1 = project dir; writes .venv/bin/activate that drops a marker file
    # when SOURCED (the code-execution primitive under test).
    local proj="$1"
    mkdir -p "$proj/.venv/bin"
    cat > "$proj/.venv/bin/activate" <<EOF
# canary activation script — records sourcing
echo sourced >> "$proj/venv-marker"
export VIRTUAL_ENV="$proj/.venv"
EOF
}

# Fake nvm SHELL FUNCTION (nvm is a function in real shells — never a binary).
# Records use/install to $NVM_LOG; honors $NVM_INSTALLED (comma-separated).
NVM_LOG=""
NVM_INSTALLED="20.0.0"
NVM_CURRENT="20.0.0"
nvm() {
    case "${1:-}" in
        current)  printf '%s\n' "$NVM_CURRENT" ;;
        use)
            if [[ ",$NVM_INSTALLED," == *",${2#v},"* ]]; then
                NVM_CURRENT="${2#v}"
                printf 'use\t%s\n' "${2#v}" >> "$NVM_LOG"
                return 0
            fi
            return 1   # version missing -> the hook sees "not installed"
            ;;
        install)
            printf 'install\t%s\n' "${2#v}" >> "$NVM_LOG"
            NVM_INSTALLED="$NVM_INSTALLED,${2#v}"
            return 0
            ;;
        *)        return 0 ;;
    esac
}

# Recording `ln` shim: logs argv (tab-delimited) then FAILS like a non-root
# user would, forcing the `sudo -n ln` fallback through tests/shims/sudo.
_make_ln_shim_dir() {
    local dir="$1"
    cat > "$dir/ln" <<'EOF'
#!/usr/bin/env bash
line=""
for a in "$@"; do
    [[ -n "$line" ]] && line+=$'\t'
    line+="$a"
done
printf '%s\n' "$line" >> "${LN_SHIM_LOG:?LN_SHIM_LOG required}"
exit 1   # simulate permission failure — never performs a real link
EOF
    chmod +x "$dir/ln"
}

# Recording pyenv shim (switch regression — pyenv is a PATH binary).
_make_pyenv_shim_dir() {
    local dir="$1"
    cat > "$dir/pyenv" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    versions)      printf '3.11.0\n3.12.0\n' ;;
    version-name)  printf '%s\n' "${PYENV_CURRENT:-3.11.0}" ;;
    local)         printf 'local\t%s\n' "${2:-}" >> "$PYENV_LOG" ;;
    *)             return 0 ;;
esac
EOF
    chmod +x "$dir/pyenv"
}

_snapshot_usr_local_bin() {
    # Existence + listing snapshot; used to prove /usr/local/bin was not mutated.
    if [[ -d /usr/local/bin ]]; then
        (cd /usr/local/bin && ls -1 2>/dev/null) | sha256sum 2>/dev/null | awk '{print $1}'
    else
        printf 'no-dir\n'
    fi
}

# =============================================================================
# 1. Registry API: auto_trust / auto_is_trusted (format, idempotency, validation)
# =============================================================================
test_registry_api() {
    local f=0 rc
    rm -rf "$REGISTRY_FILE"
    local proj; proj="$(_new_project)"

    # Empty/missing registry -> not trusted (fail closed)
    auto_is_trusted "$proj" venv_source >/dev/null 2>&1; rc=$?
    [[ $rc -ne 0 ]] \
        && assert_equals "untrusted" "untrusted" "missing registry -> not trusted" \
        || { assert_equals "untrusted" "trusted" "missing registry must not trust"; f=$((f+1)); }

    auto_trust "$proj" venv_source >/dev/null 2>&1; rc=$?
    [[ $rc -eq 0 ]] \
        && assert_equals "0" "$rc" "auto_trust succeeds" \
        || { assert_equals "0" "$rc" "auto_trust must succeed"; f=$((f+1)); }

    assert_file_exists "$REGISTRY_FILE" "registry file created"
    local nlines; nlines="$(grep -c . "$REGISTRY_FILE" 2>/dev/null || true)"
    assert_equals "1" "$nlines" "exactly one registry entry after first trust"

    # Entry format: <sha256(canonical dir)><TAB><capability>
    local canon want_hash want_line line
    canon="$(cd "$proj" && pwd -P)"
    want_hash="$(printf '%s' "$canon" | sha256sum | awk '{print $1}')"
    want_line="$(printf '%s\t%s' "$want_hash" "venv_source")"
    line="$(head -n 1 "$REGISTRY_FILE")"
    assert_equals "$want_line" "$line" "entry is sha256(canonical-dir) TAB capability"

    # Idempotent re-trust: still one entry
    auto_trust "$proj" venv_source >/dev/null 2>&1
    nlines="$(grep -c . "$REGISTRY_FILE" 2>/dev/null || true)"
    assert_equals "1" "$nlines" "auto_trust is idempotent (no duplicate entry)"

    # Trusted check now succeeds; other capability still untrusted
    auto_is_trusted "$proj" venv_source >/dev/null 2>&1; rc=$?
    [[ $rc -eq 0 ]] \
        && assert_equals "trusted" "trusted" "auto_is_trusted honors entry" \
        || { assert_equals "trusted" "untrusted" "auto_is_trusted must honor entry"; f=$((f+1)); }
    auto_is_trusted "$proj" symlink_sync >/dev/null 2>&1; rc=$?
    [[ $rc -ne 0 ]] \
        && assert_equals "untrusted" "untrusted" "other capability remains untrusted" \
        || { assert_equals "untrusted" "trusted" "capabilities must be independent"; f=$((f+1)); }

    # Validation: unknown capability and missing dir fail closed
    auto_trust "$proj" "rm -rf /" >/dev/null 2>&1; rc=$?
    [[ $rc -ne 0 ]] \
        && assert_equals "rejected" "rejected" "unknown capability rejected" \
        || { assert_equals "rejected" "accepted" "unknown capability MUST be rejected"; f=$((f+1)); }
    auto_trust "/nonexistent/vms-dir-$$" venv_source >/dev/null 2>&1; rc=$?
    [[ $rc -ne 0 ]] \
        && assert_equals "rejected" "rejected" "nonexistent dir rejected" \
        || { assert_equals "rejected" "accepted" "nonexistent dir MUST be rejected"; f=$((f+1)); }

    rm -rf "$proj"
    return "$f"
}

# =============================================================================
# 2. Registry API: auto_untrust (removal, per-capability scope, no-op case)
# =============================================================================
test_registry_untrust() {
    local f=0 rc
    rm -rf "$REGISTRY_FILE"
    local proj; proj="$(_new_project)"

    auto_trust "$proj" venv_source >/dev/null 2>&1
    auto_trust "$proj" symlink_sync >/dev/null 2>&1
    local nlines; nlines="$(grep -c . "$REGISTRY_FILE")"
    assert_equals "2" "$nlines" "two capabilities registered"

    auto_untrust "$proj" venv_source >/dev/null 2>&1; rc=$?
    [[ $rc -eq 0 ]] \
        && assert_equals "0" "$rc" "auto_untrust succeeds" \
        || { assert_equals "0" "$rc" "auto_untrust must succeed"; f=$((f+1)); }

    nlines="$(grep -c . "$REGISTRY_FILE")"
    assert_equals "1" "$nlines" "only the targeted capability removed"

    auto_is_trusted "$proj" venv_source >/dev/null 2>&1; rc=$?
    [[ $rc -ne 0 ]] \
        && assert_equals "untrusted" "untrusted" "removed capability untrusted" \
        || { assert_equals "untrusted" "trusted" "removed capability must be untrusted"; f=$((f+1)); }
    auto_is_trusted "$proj" symlink_sync >/dev/null 2>&1; rc=$?
    [[ $rc -eq 0 ]] \
        && assert_equals "trusted" "trusted" "sibling capability preserved" \
        || { assert_equals "trusted" "untrusted" "sibling capability must survive untrust of another"; f=$((f+1)); }

    # Untrust of anything, with no registry at all: no-op success, no file created
    rm -rf "$REGISTRY_FILE"
    auto_untrust "$proj" node_install >/dev/null 2>&1; rc=$?
    [[ $rc -eq 0 && ! -e "$REGISTRY_FILE" ]] \
        && assert_equals "no-op" "no-op" "untrust with no registry is a clean no-op" \
        || { assert_equals "no-op" "side-effect" "untrust with no registry must not create artifacts"; f=$((f+1)); }

    rm -rf "$proj"
    return "$f"
}

# =============================================================================
# 3. Registry canonicalization: symlinked path and canonical dir are the same
#    trust identity (hash of the REAL path, not the raw string)
# =============================================================================
test_registry_canonicalization() {
    local f=0 rc
    rm -rf "$REGISTRY_FILE"
    local real link
    real="$(_new_project)"
    link="${TMPDIR:-/tmp}/vms-trust-link.$$"
    ln -s "$real" "$link"

    auto_trust "$link" venv_source >/dev/null 2>&1; rc=$?
    [[ $rc -eq 0 ]] \
        && assert_equals "0" "$rc" "auto_trust accepts symlinked path" \
        || { assert_equals "0" "$rc" "auto_trust must accept symlinked path"; f=$((f+1)); }

    # The stored hash must be of the CANONICAL dir
    local want_hash stored_hash
    want_hash="$(printf '%s' "$(cd "$real" && pwd -P)" | sha256sum | awk '{print $1}')"
    stored_hash="$(head -n 1 "$REGISTRY_FILE" | cut -f1)"
    assert_equals "$want_hash" "$stored_hash" "registry stores hash of canonical dir"

    auto_is_trusted "$real" venv_source >/dev/null 2>&1; rc=$?
    [[ $rc -eq 0 ]] \
        && assert_equals "trusted" "trusted" "canonical path resolves to same trust identity" \
        || { assert_equals "trusted" "untrusted" "trust must follow canonical dir, not raw path"; f=$((f+1)); }

    rm -rf "$real" "$link"
    return "$f"
}

# =============================================================================
# 4. Venv capability — UNTRUSTED (case a): repo-controlled activate script
#    must NOT be sourced. The live-vuln sub-check calls the library handler
#    directly: against the unpatched library the canary IS sourced.
# =============================================================================
test_venv_untrusted() {
    local f=0 rc
    rm -rf "$REGISTRY_FILE"
    local proj; proj="$(_new_project)"
    _make_venv_canary "$proj"

    # Primary: the hook function must not source the canary
    auto_activate_on_cd "$proj" >/dev/null 2>&1; rc=$?
    [[ $rc -eq 0 ]] \
        && assert_equals "0" "$rc" "hook runs cleanly on untrusted project" \
        || { assert_equals "0" "$rc" "hook must run cleanly (rc) on untrusted project"; f=$((f+1)); }
    [[ ! -e "$proj/venv-marker" ]] \
        && assert_equals "not-sourced" "not-sourced" "UNTRUSTED venv: activate script NOT sourced" \
        || { assert_equals "not-sourced" "SOURCED" "UNTRUSTED venv must NOT be sourced (code exec from repo)"; f=$((f+1)); }

    # Live-vuln demonstration: the library handler itself is gated
    rm -f "$proj/venv-marker"
    ( cd "$proj" && aa_python ) >/dev/null 2>&1
    [[ ! -e "$proj/venv-marker" ]] \
        && assert_equals "not-sourced" "not-sourced" "aa_python gated without venv_source trust" \
        || { assert_equals "not-sourced" "SOURCED" "aa_python sourced untrusted repo script (live vuln)"; f=$((f+1)); }

    rm -rf "$proj"
    return "$f"
}

# =============================================================================
# 5. Venv capability — TRUSTED (case b): after auto_trust, the hook activates
# =============================================================================
test_venv_trusted() {
    local f=0 rc
    rm -rf "$REGISTRY_FILE"
    local proj; proj="$(_new_project)"
    _make_venv_canary "$proj"

    auto_trust "$proj" venv_source >/dev/null 2>&1
    auto_activate_on_cd "$proj" >/dev/null 2>&1; rc=$?
    [[ $rc -eq 0 ]] \
        && assert_equals "0" "$rc" "hook runs cleanly on trusted project" \
        || { assert_equals "0" "$rc" "hook must run cleanly (rc) on trusted project"; f=$((f+1)); }
    [[ -e "$proj/venv-marker" ]] \
        && assert_equals "sourced" "sourced" "TRUSTED venv: activate script sourced" \
        || { assert_equals "sourced" "not-sourced" "TRUSTED venv must be sourced (capability works)"; f=$((f+1)); }
    assert_equals "$proj/.venv" "${VIRTUAL_ENV:-}" "VIRTUAL_ENV exported by trusted activation"

    unset VIRTUAL_ENV
    rm -rf "$proj"
    return "$f"
}

# =============================================================================
# 6. Node-install capability — UNTRUSTED (case c): a MISSING version in
#    .nvmrc must NOT be installed. Live-vuln sub-check calls aa_node directly.
# =============================================================================
test_node_install_untrusted() {
    local f=0 rc
    rm -rf "$REGISTRY_FILE"
    local proj; proj="$(_new_project)"
    printf '23.0.0\n' > "$proj/.nvmrc"
    NVM_LOG="$proj/nvm.log"; : > "$NVM_LOG"

    auto_activate_on_cd "$proj" >/dev/null 2>&1; rc=$?
    [[ $rc -eq 0 ]] \
        && assert_equals "0" "$rc" "hook runs cleanly with untrusted missing node version" \
        || { assert_equals "0" "$rc" "hook must run cleanly (rc) with untrusted missing version"; f=$((f+1)); }
    [[ ! -e "$NVM_LOG" || ! -s "$NVM_LOG" ]] \
        && assert_equals "no-install" "no-install" "UNTRUSTED missing node version: no installer invoked" \
        || { assert_equals "no-install" "$(cat "$NVM_LOG" | tr '\n' ';')" "UNTRUSTED missing version must NOT be installed"; f=$((f+1)); }

    # Live-vuln demonstration: library handler installs when unpatched
    NVM_INSTALLED="20.0.0"; NVM_CURRENT="20.0.0"
    ( cd "$proj" && aa_node ) >/dev/null 2>&1
    if grep -q "^install" "$NVM_LOG" 2>/dev/null; then
        assert_equals "no-install" "install-invoked" "aa_node installed untrusted missing version (live vuln)"
        f=$((f+1))
    else
        assert_equals "no-install" "no-install" "aa_node gated without node_install trust"
    fi

    rm -rf "$proj"
    return "$f"
}

# =============================================================================
# 7. REGRESSION (case g): switching to an ALREADY-INSTALLED Node version
#    requires NO trust entry — the hook's core duty stays un-gated.
# =============================================================================
test_node_switch_ungated() {
    local f=0
    rm -rf "$REGISTRY_FILE"
    local proj; proj="$(_new_project)"
    printf '22.0.0\n' > "$proj/.nvmrc"
    NVM_INSTALLED="20.0.0,22.0.0"; NVM_CURRENT="20.0.0"
    NVM_LOG="$proj/nvm.log"; : > "$NVM_LOG"

    auto_activate_on_cd "$proj" >/dev/null 2>&1

    grep -q $'^use\t22.0.0' "$NVM_LOG" 2>/dev/null \
        && assert_equals "switched" "switched" "installed-version switch needs NO trust" \
        || { assert_equals "switched" "not-switched" "REGRESSION: installed-version switch must stay un-gated"; f=$((f+1)); }
    if grep -q "^install" "$NVM_LOG" 2>/dev/null; then
        assert_equals "no-install" "install-invoked" "switch must not fall through to install"
        f=$((f+1))
    else
        assert_equals "no-install" "no-install" "switch path never installs"
    fi

    rm -rf "$proj"
    return "$f"
}

# =============================================================================
# 8. REGRESSION (case g): pyenv version switching stays un-gated (PATH shim).
# =============================================================================
test_pyenv_switch_ungated() {
    local f=0
    rm -rf "$REGISTRY_FILE"
    local shimdir proj
    shimdir="$(mktemp -d "${TMPDIR:-/tmp}/vms-trust-shim.XXXXXX")"
    _make_pyenv_shim_dir "$shimdir"
    proj="$(_new_project)"
    printf '3.12.0\n' > "$proj/.python-version"

    PYENV_LOG="$proj/pyenv.log"; : > "$PYENV_LOG"; export PYENV_LOG
    ( cd "$proj" && PATH="$shimdir:$PATH" auto_activate_on_cd ) >/dev/null 2>&1

    grep -q $'^local\t3.12.0' "$PYENV_LOG" 2>/dev/null \
        && assert_equals "switched" "switched" "pyenv switch needs NO trust" \
        || { assert_equals "switched" "not-switched" "REGRESSION: pyenv switch must stay un-gated"; f=$((f+1)); }

    rm -rf "$proj" "$shimdir"
    return "$f"
}

# =============================================================================
# 9. Symlink-sync capability — TRUSTED (case d): with DEV_AUTO_SYNC_NODE_
#    SYMLINKS=true + symlink_sync trust, the sync runs ln -sf and falls back
#    to sudo -n ln -sf — both RECORDED by shims, never executed for real.
#    /usr/local/bin must be byte-identical before/after.
# =============================================================================
test_symlink_sync_trusted() {
    local f=0 rc
    rm -rf "$REGISTRY_FILE"
    local shimdir proj nvm_bin
    shimdir="$(mktemp -d "${TMPDIR:-/tmp}/vms-trust-shim.XXXXXX")"
    _make_ln_shim_dir "$shimdir"
    proj="$(_new_project)"

    # Minimal NVM_DIR layout the sync helper reads
    NVM_DIR="$proj/nvm"
    nvm_bin="$NVM_DIR/versions/node/22.0.0/bin"
    mkdir -p "$nvm_bin"
    for c in node npm npx; do printf '#!/bin/sh\n' > "$nvm_bin/$c"; chmod +x "$nvm_bin/$c"; done
    NVM_INSTALLED="22.0.0"; NVM_CURRENT="22.0.0"; export NVM_DIR
    export DEV_AUTO_SYNC_NODE_SYMLINKS=true

    LN_SHIM_LOG="$proj/ln.log"; : > "$LN_SHIM_LOG"; export LN_SHIM_LOG
    SUDO_SHIM_LOG="$proj/sudo.log"; : > "$SUDO_SHIM_LOG"; export SUDO_SHIM_LOG

    local ulb_before; ulb_before="$(_snapshot_usr_local_bin)"

    auto_trust "$proj" symlink_sync >/dev/null 2>&1
    # shellcheck disable=SC2030,SC2031  # deliberate: shim PATH confined to subshell
    (
        PATH="$shimdir:$ROOT_DIR/tests/shims:$PATH"
        auto_activate_on_cd "$proj"
    ) >/dev/null 2>&1; rc=$?
    [[ $rc -eq 0 ]] \
        && assert_equals "0" "$rc" "hook runs cleanly on trusted symlink_sync project" \
        || { assert_equals "0" "$rc" "hook must run cleanly (rc) on trusted sync project"; f=$((f+1)); }

    # The direct ln attempt was recorded (with the expected target args).
    # Note: the ln shim's argv EXCLUDES its own name (argv[0]), so the line
    # starts at "-sf"; the sudo shim's argv includes "ln" as its operand.
    local ln_needle sudo_needle
    ln_needle="$(printf '%s\t%s\t%s' "-sf" "$nvm_bin/node" "/usr/local/bin/node")"
    sudo_needle="$(printf '%s\t%s\t%s\t%s\t%s' "-n" "ln" "-sf" "$nvm_bin/node" "/usr/local/bin/node")"
    if grep -qF -- "$ln_needle" "$LN_SHIM_LOG" 2>/dev/null; then
        assert_equals "recorded" "recorded" "trusted sync: ln -sf argv recorded (target /usr/local/bin/node)"
    else
        assert_equals "recorded" "$(cat "$LN_SHIM_LOG" 2>/dev/null | tr '\n' ';')" "trusted sync must attempt ln -sf -> /usr/local/bin/node"; f=$((f+1))
    fi

    # The sudo fallback was recorded, never elevated
    if grep -qF -- "$sudo_needle" "$SUDO_SHIM_LOG" 2>/dev/null; then
        assert_equals "recorded" "recorded" "trusted sync: sudo -n ln -sf argv recorded by shim"
    else
        assert_equals "recorded" "$(cat "$SUDO_SHIM_LOG" 2>/dev/null | tr '\n' ';')" "trusted sync must reach sudo -n ln -sf fallback (recorded only)"; f=$((f+1))
    fi

    # Nothing was actually linked
    local ulb_after; ulb_after="$(_snapshot_usr_local_bin)"
    assert_equals "$ulb_before" "$ulb_after" "/usr/local/bin listing unchanged (no real mutation)"

    rm -rf "$proj" "$shimdir"
    unset NVM_DIR DEV_AUTO_SYNC_NODE_SYMLINKS LN_SHIM_LOG SUDO_SHIM_LOG
    return "$f"
}

# =============================================================================
# 10. Symlink-sync capability — UNTRUSTED (case e): nothing recorded by the
#     shims, nothing linked. Live-vuln sub-check calls the sync helper
#     directly: against the unpatched library it syncs anyway.
# =============================================================================
test_symlink_sync_untrusted() {
    local f=0
    rm -rf "$REGISTRY_FILE"
    local shimdir proj nvm_bin
    shimdir="$(mktemp -d "${TMPDIR:-/tmp}/vms-trust-shim.XXXXXX")"
    _make_ln_shim_dir "$shimdir"
    proj="$(_new_project)"

    NVM_DIR="$proj/nvm"
    nvm_bin="$NVM_DIR/versions/node/22.0.0/bin"
    mkdir -p "$nvm_bin"
    for c in node npm npx; do printf '#!/bin/sh\n' > "$nvm_bin/$c"; chmod +x "$nvm_bin/$c"; done
    NVM_INSTALLED="22.0.0"; NVM_CURRENT="22.0.0"; export NVM_DIR
    export DEV_AUTO_SYNC_NODE_SYMLINKS=true

    LN_SHIM_LOG="$proj/ln.log"; : > "$LN_SHIM_LOG"; export LN_SHIM_LOG
    SUDO_SHIM_LOG="$proj/sudo.log"; : > "$SUDO_SHIM_LOG"; export SUDO_SHIM_LOG

    local ulb_before; ulb_before="$(_snapshot_usr_local_bin)"

    # shellcheck disable=SC2030,SC2031  # deliberate: shim PATH confined to subshell
    (
        PATH="$shimdir:$ROOT_DIR/tests/shims:$PATH"
        auto_activate_on_cd "$proj"
    ) >/dev/null 2>&1
    [[ ! -s "$LN_SHIM_LOG" && ! -s "$SUDO_SHIM_LOG" ]] \
        && assert_equals "silent" "silent" "UNTRUSTED sync: shim logs empty" \
        || { assert_equals "silent" "ln=[$(cat "$LN_SHIM_LOG" 2>/dev/null | tr '\n' ';')] sudo=[$(cat "$SUDO_SHIM_LOG" 2>/dev/null | tr '\n' ';')]" "UNTRUSTED sync must record NOTHING"; f=$((f+1)); }

    # Live-vuln demonstration: unpatched helper syncs without any trust
    # shellcheck disable=SC2031  # deliberate: shim PATH confined to subshell
    ( cd "$proj" && PATH="$shimdir:$ROOT_DIR/tests/shims:$PATH" _nvm_sync_symlinks ) >/dev/null 2>&1
    if [[ -s "$SUDO_SHIM_LOG" ]]; then
        assert_equals "silent" "sudo-invoked" "_nvm_sync_symlinks ran sudo path with NO trust (live vuln)"
        f=$((f+1))
    else
        assert_equals "silent" "silent" "_nvm_sync_symlinks gated without symlink_sync trust"
    fi

    local ulb_after; ulb_after="$(_snapshot_usr_local_bin)"
    assert_equals "$ulb_before" "$ulb_after" "/usr/local/bin listing unchanged"

    rm -rf "$proj" "$shimdir"
    unset NVM_DIR DEV_AUTO_SYNC_NODE_SYMLINKS LN_SHIM_LOG SUDO_SHIM_LOG
    return "$f"
}

# =============================================================================
# 11. rc-file transactions (directive item 3): setup AND remove take a
#     transactional backup of $HOME/.zshrc before mutating it.
# =============================================================================
test_rc_transactions() {
    local f=0 rc
    local shell_rc="$HOME/.zshrc"
    printf 'export EDITOR=vi\n' > "$shell_rc"   # sentinel content

    export SHELL=/bin/zsh

    auto_activate_setup >/dev/null 2>&1; rc=$?
    [[ $rc -eq 0 ]] \
        && assert_equals "0" "$rc" "auto_activate_setup succeeds" \
        || { assert_equals "0" "$rc" "auto_activate_setup must succeed"; f=$((f+1)); }
    grep -q "$_AA_START" "$shell_rc" \
        && assert_equals "installed" "installed" "hook block present after setup" \
        || { assert_equals "installed" "missing" "hook block must be installed"; f=$((f+1)); }

    # Transaction backup for setup: pre-state (sentinel-only) preserved
    local setup_backup
    setup_backup="$(find "$HOME/.config-backups/transactions" -path '*auto_activate_setup*' -name data -type f 2>/dev/null | head -1)"
    if [[ -n "$setup_backup" ]]; then
        assert_equals "export EDITOR=vi" "$(cat "$setup_backup")" "setup transaction backed up pre-state .zshrc"
    else
        assert_equals "backup" "none" "auto_activate_setup must record a transactional backup of .zshrc"; f=$((f+1))
    fi

    # Idempotent setup
    auto_activate_setup >/dev/null 2>&1
    local nblocks; nblocks="$(grep -c "$_AA_START" "$shell_rc")"
    assert_equals "1" "$nblocks" "setup is idempotent (single hook block)"

    # The emitted hook must be self-contained: inline trust registry + check
    grep -q "trusted-projects" "$shell_rc" \
        && assert_contains "trusted-projects" "$(cat "$shell_rc")" "emitted hook inlines registry path" \
        || { assert_contains "trusted-projects" "$(cat "$shell_rc")" "emitted hook must inline registry path"; f=$((f+1)); }
    grep -q "auto_is_trusted" "$shell_rc" \
        && assert_contains "auto_is_trusted" "$(cat "$shell_rc")" "emitted hook inlines trust check" \
        || { assert_contains "auto_is_trusted" "$(cat "$shell_rc")" "emitted hook must inline trust check"; f=$((f+1)); }

    # Emitted block parses as zsh (the emitted functions must be zsh-safe)
    if command -v zsh >/dev/null 2>&1; then
        local blk; blk="$(mktemp "${TMPDIR:-/tmp}/vms-block.XXXXXX")"
        mutation_block_get "$shell_rc" "$_AA_BLOCK_NAME" > "$blk"
        [[ -s "$blk" ]] || { echo "FAIL: empty emitted hook"; return 1; }
        if zsh -n "$blk" 2>/dev/null; then
            assert_equals "parses" "parses" "emitted hook block parses under zsh -n"
        else
            assert_equals "parses" "SYNTAX-ERROR" "emitted hook block must parse under zsh -n"; f=$((f+1))
        fi
        rm -f "$blk"
    else
        echo "INFO: zsh not available — skipping zsh -n parse check"
    fi

    # Remove: transactional backup of the WITH-hook pre-state, then clean strip
    auto_activate_remove >/dev/null 2>&1; rc=$?
    [[ $rc -eq 0 ]] \
        && assert_equals "0" "$rc" "auto_activate_remove succeeds" \
        || { assert_equals "0" "$rc" "auto_activate_remove must succeed"; f=$((f+1)); }
    grep -q "$_AA_START" "$shell_rc" \
        && { assert_equals "removed" "still-present" "hook block removed"; f=$((f+1)); } \
        || assert_equals "removed" "removed" "hook block removed"
    assert_equals "export EDITOR=vi" "$(cat "$shell_rc")" "sentinel content preserved after remove"

    local remove_backup
    remove_backup="$(find "$HOME/.config-backups/transactions" -path '*auto_activate_remove*' -name data -type f 2>/dev/null | head -1)"
    if [[ -n "$remove_backup" ]]; then
        grep -q "$_AA_START" "$remove_backup" \
            && assert_equals "with-hook" "with-hook" "remove transaction backed up pre-remove .zshrc" \
            || { assert_equals "with-hook" "without-hook" "remove backup must contain the pre-remove state"; f=$((f+1)); }
    else
        assert_equals "backup" "none" "auto_activate_remove must record a transactional backup of .zshrc"; f=$((f+1))
    fi

    return "$f"
}

# =============================================================================
# 12. PWD-path equivalence: the chpwd glue shape `auto_activate_on_cd "$PWD"`
#     behaves identically when invoked after an actual cd (hook runtime shape).
# =============================================================================
test_pwd_path_equivalence() {
    local f=0
    rm -rf "$REGISTRY_FILE"
    local proj; proj="$(_new_project)"
    _make_venv_canary "$proj"

    # Untrusted: nothing sourced even in the real cd shape
    ( cd "$proj" && auto_activate_on_cd ) >/dev/null 2>&1
    [[ ! -e "$proj/venv-marker" ]] \
        && assert_equals "not-sourced" "not-sourced" "cd-shape hook: untrusted venv not sourced" \
        || { assert_equals "not-sourced" "SOURCED" "cd-shape hook must not source untrusted venv"; f=$((f+1)); }

    # Trusted: sourced in the real cd shape
    auto_trust "$proj" venv_source >/dev/null 2>&1
    ( cd "$proj" && auto_activate_on_cd ) >/dev/null 2>&1
    [[ -e "$proj/venv-marker" ]] \
        && assert_equals "sourced" "sourced" "cd-shape hook: trusted venv sourced" \
        || { assert_equals "sourced" "not-sourced" "cd-shape hook must source trusted venv"; f=$((f+1)); }

    unset VIRTUAL_ENV
    rm -rf "$proj"
    return "$f"
}

# =============================================================================
# Run — explicit failure accumulation (A5 style)
# =============================================================================
test_registry_api                || failures=$((failures + 1))
test_registry_untrust            || failures=$((failures + 1))
test_registry_canonicalization   || failures=$((failures + 1))
test_venv_untrusted              || failures=$((failures + 1))
test_venv_trusted                || failures=$((failures + 1))
test_node_install_untrusted      || failures=$((failures + 1))
test_node_switch_ungated         || failures=$((failures + 1))
test_pyenv_switch_ungated        || failures=$((failures + 1))
test_symlink_sync_trusted        || failures=$((failures + 1))
test_symlink_sync_untrusted      || failures=$((failures + 1))
test_rc_transactions             || failures=$((failures + 1))
test_pwd_path_equivalence        || failures=$((failures + 1))

teardown_test

if [[ "$failures" -gt 0 ]]; then
    echo "test_auto_activate_trust.sh: $failures case(s) failed"
    exit 1
fi
exit 0
