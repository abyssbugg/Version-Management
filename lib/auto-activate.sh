#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source paths; SC2034: env-contract vars

# Unified Runtime Auto-Activation Library
# Part of Professional Development Terminal Setup
#
# Installs a single zsh chpwd hook that auto-switches versions for ALL managed
# runtimes when you change directories:
#
#   Runtime   | Trigger file(s)                        | Tool
#   ----------|----------------------------------------|----------------
#   Python    | .venv/  venv/  .virtualenv/             | venv activate
#   Python    | .python-version                        | pyenv local
#   Node.js   | .nvmrc  .node-version                  | nvm use / fnm use
#   Node.js   | (after switch)                         | symlink sync
#   Bun       | .bun-version  bunfig.toml               | bun (path swap)
#   Go        | .go-version  go.mod (+goenv)            | goenv local
#   Ruby      | .ruby-version  Gemfile                  | rbenv local
#   Java      | .java-version                           | jenv local
#   PHP       | .php-version                            | phpenv local
#   Rust      | rust-toolchain  rust-toolchain.toml     | rustup (native)
#
# ============================================================================
# TRUST MODEL (remediation directive B1.2 — trust-boundary repair)
# ============================================================================
# A directory hook runs ARBITRARY project content on every `cd`, so the hook's
# authority is split by capability:
#
#   - UN-GATED (safe switching only): moving to an ALREADY-INSTALLED version
#     (pyenv local, nvm use, goenv local, rbenv local, jenv local, phpenv
#     local, bun path check, asdf reshim).
#
#   - TRUST-GATED, per project, persisted in a registry:
#       venv_source   — sourcing the repo-controlled .venv/bin/activate
#                       (code execution from whatever the repo ships)
#       node_install  — INSTALLING a missing Node version found in
#                       .nvmrc/.node-version (network + $HOME writes)
#       symlink_sync  — updating /usr/local/bin/{node,npm,npx} via ln -sf and
#                       the sudo -n fallback (privileged mutation on `cd`)
#
#   Registry: $HOME/.config/version-manager/trusted-projects
#             one entry per line, tab-delimited:
#               <sha256-of-canonical-project-dir><TAB><capability>
#   The project dir is canonicalized (symlinks resolved) before hashing, so a
#   bind-mounted/aliased path cannot mint a second trust identity.
#
#   When a capability is not trusted, the hook does NOTHING for it (no
#   prompt, no write, no install); a log_debug notice is all that is emitted.
#   Grant/revoke with: auto_trust <dir> <cap> / auto_untrust <dir> <cap>.
#
# The functions between here and auto_activate_setup are emitted VERBATIM
# (via typeset -f) into the user's rc by auto_activate_setup — the rc cannot
# source this library at runtime — so their bodies are written in the
# bash/zsh-portable subset (no ${var:h}, no ${=x}, no print -P, no
# shell-specific array syntax).

_VMS_AUTO_ACTIVATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_VMS_AUTO_ACTIVATE_DIR}/logger.sh"

# Transactions (M2 primitives) back every rc mutation. Sourced lazily so a
# caller that already loaded lib/backup.sh is not double-loaded.
if ! declare -f transaction_start >/dev/null 2>&1; then
    # shellcheck source=lib/backup.sh
    source "${_VMS_AUTO_ACTIVATE_DIR}/backup.sh"
fi

# Hook block delimiters — must stay in sync with auto_activate_remove()
readonly _AA_START="# >>> dev auto-activate hook <<<"
readonly _AA_END="# <<< dev auto-activate hook <<<"

# Capabilities (exact strings) granted through the trust registry.
readonly _AA_CAPABILITIES="venv_source node_install symlink_sync"

# ============================================================================
# TRUST REGISTRY  (public API — also emitted into the hook verbatim)
# ============================================================================

# Echo the registry path. XDG_CONFIG_HOME is honored when set (the test
# runner sandboxes both HOME and XDG_CONFIG_HOME consistently).
_aa_trust_registry() {
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/version-manager/trusted-projects"
}

# Canonicalize an EXISTING directory (symlinks fully resolved).
# Self-contained on purpose: the emitted hook uses the exact same routine,
# so admin-time and runtime identities can never diverge. Fails closed.
_aa_canonical_dir() {
    local p="${1:-}"
    [[ -n "$p" && -e "$p" ]] || return 1
    local r
    r="$(readlink -f "$p" 2>/dev/null)" && [[ -n "$r" ]] && { printf '%s\n' "$r"; return 0; }
    r="$(cd -P "$p" 2>/dev/null && pwd)" && [[ -n "$r" ]] && { printf '%s\n' "$r"; return 0; }
    if command -v python3 >/dev/null 2>&1; then
        r="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null)" \
            && [[ -n "$r" ]] && { printf '%s\n' "$r"; return 0; }
    fi
    return 1
}

# sha256 of a STRING (the canonical path), via whatever tool the host has.
_aa_sha256_str() {
    local s="${1:-}"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$s" | sha256sum 2>/dev/null | awk '{print $1}'
        return 0
    fi
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$s" | shasum -a 256 2>/dev/null | awk '{print $1}'
        return 0
    fi
    if command -v openssl >/dev/null 2>&1; then
        printf '%s' "$s" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
        return 0
    fi
    return 1
}

# Public: does <dir> hold <capability>? Returns 0/1. Fail closed on any
# doubt (missing registry, unresolvable dir, unknown capability, no sha256).
auto_is_trusted() {
    local dir="${1:-}" cap="${2:-}"
    case "$cap" in
        venv_source|node_install|symlink_sync) ;;
        *) return 1 ;;
    esac
    [[ -n "$dir" ]] || return 1
    local reg canon hash h c
    reg="$(_aa_trust_registry)" || return 1
    [[ -f "$reg" ]] || return 1
    canon="$(_aa_canonical_dir "$dir")" || return 1
    hash="$(_aa_sha256_str "$canon")" || return 1
    while IFS=$'\t' read -r h c || [[ -n "${h:-}" ]]; do
        [[ "$h" == "$hash" && "$c" == "$cap" ]] && return 0
    done < "$reg"
    return 1
}

# Public: grant <capability> to <dir> (must exist). Idempotent.
auto_trust() {
    local dir="${1:-}" cap="${2:-}"
    case "$cap" in
        venv_source|node_install|symlink_sync) ;;
        *) log_error "auto_trust: invalid capability '${cap}' (allowed: ${_AA_CAPABILITIES})"; return 1 ;;
    esac
    if [[ -z "$dir" || ! -d "$dir" ]]; then
        log_error "auto_trust: directory does not exist: ${dir:-<empty>}"
        return 1
    fi
    local reg canon hash reg_dir
    reg="$(_aa_trust_registry)" || return 1
    canon="$(_aa_canonical_dir "$dir")" || { log_error "auto_trust: cannot canonicalize: $dir"; return 1; }
    hash="$(_aa_sha256_str "$canon")" || { log_error "auto_trust: no sha256 tool available"; return 1; }
    reg_dir="$(dirname "$reg")"
    mkdir -p "$reg_dir" || { log_error "auto_trust: cannot create $reg_dir"; return 1; }
    [[ -f "$reg" ]] || : > "$reg" || { log_error "auto_trust: cannot create $reg"; return 1; }
    if grep -qxF "$(printf '%s\t%s' "$hash" "$cap")" "$reg" 2>/dev/null; then
        log_debug "auto_trust: already trusted ($cap): $canon"
        return 0
    fi
    printf '%s\t%s\n' "$hash" "$cap" >> "$reg" || { log_error "auto_trust: registry write failed"; return 1; }
    chmod 600 "$reg" 2>/dev/null || true
    log_info "auto_trust: granted $cap for $canon"
    return 0
}

# Public: revoke <capability> from <dir>. A missing registry is a clean no-op.
auto_untrust() {
    local dir="${1:-}" cap="${2:-}"
    case "$cap" in
        venv_source|node_install|symlink_sync) ;;
        *) log_error "auto_untrust: invalid capability '${cap}' (allowed: ${_AA_CAPABILITIES})"; return 1 ;;
    esac
    local reg canon hash needle tmp grc=0
    reg="$(_aa_trust_registry)" || return 1
    [[ -f "$reg" ]] || return 0
    canon="$(_aa_canonical_dir "$dir")" || { log_error "auto_untrust: cannot canonicalize: $dir"; return 1; }
    hash="$(_aa_sha256_str "$canon")" || return 1
    needle="$(printf '%s\t%s' "$hash" "$cap")"
    tmp="$(mktemp)" || return 1
    grep -vxF -- "$needle" "$reg" > "$tmp" 2>/dev/null || grc=$?
    # grc 0: lines kept; 1: every line matched (entry removed); 2: grep error
    if [[ "$grc" -eq 2 ]]; then
        rm -f "$tmp"
        log_error "auto_untrust: registry read failed"
        return 1
    fi
    if ! mv "$tmp" "$reg"; then
        rm -f "$tmp" 2>/dev/null
        log_error "auto_untrust: registry rewrite failed"
        return 1
    fi
    log_info "auto_untrust: revoked $cap for $canon"
    return 0
}

# ============================================================================
# RUNTIME DETECTION HELPERS  (called from the installed zsh hook)
# ============================================================================

# Walk upward from $1 for up to $2 levels looking for any of the FILE NAMES
# given as remaining arguments. Echoes the first match; returns 1 if none.
_aa_find_up() {
    local dir="${1:-$PWD}"
    local max="${2:-3}"
    shift 2
    local depth=0 f
    while [[ "$dir" != "/" && $depth -lt $max ]]; do
        for f in "$@"; do
            [[ -e "$dir/$f" ]] && { printf '%s\n' "$dir/$f"; return 0; }
        done
        dir="$(dirname "$dir")"
        depth=$((depth + 1))
    done
    return 1
}

# ============================================================================
# INDIVIDUAL RUNTIME HANDLERS  (bash-callable, also emitted into zsh hook)
# Each accepts an optional directory (default $PWD) so the hook glue can pass
# the post-cd directory explicitly — and tests can drive it without cd.
# ============================================================================

# --- Python venv (capability: venv_source — repo-controlled code execution) ---
aa_python() {
    local dir="${1:-$PWD}"
    local venv_dirs=(".venv" "venv" ".virtualenv")
    local activate_script="" venv_dir
    local p="$dir" depth=0 vname

    while [[ "$p" != "/" && $depth -lt 3 ]]; do
        for vname in "${venv_dirs[@]}"; do
            if [[ -f "$p/$vname/bin/activate" ]]; then
                activate_script="$p/$vname/bin/activate"
                break 2
            fi
        done
        p="$(dirname "$p")"
        depth=$((depth + 1))
    done

    if [[ -n "$activate_script" ]]; then
        if ! auto_is_trusted "$dir" venv_source; then
            log_debug "auto-activate: venv found ($activate_script) but project not trusted for venv_source — skipped"
            return 0
        fi
        venv_dir="$(dirname "$(dirname "$activate_script")")"
        [[ "${VIRTUAL_ENV:-}" == "$venv_dir" ]] && return 0
        [[ -n "${VIRTUAL_ENV:-}" ]] && command -v deactivate >/dev/null 2>&1 && deactivate
        # shellcheck source=/dev/null
        source "$activate_script"
        log_debug "auto-activate: Python venv → $activate_script"
    elif [[ -n "${VIRTUAL_ENV:-}" ]]; then
        command -v deactivate >/dev/null 2>&1 && deactivate
        log_debug "auto-activate: Python venv deactivated"
    fi
}

# --- Python version via pyenv (switch only — never installs) ---
aa_pyenv() {
    command -v pyenv >/dev/null 2>&1 || return 0
    local dir="${1:-$PWD}"
    local pyver_file
    pyver_file="$(_aa_find_up "$dir" 3 .python-version)" || return 0
    local wanted
    wanted="$(tr -d '[:space:]' < "$pyver_file")"
    [[ -z "$wanted" ]] && return 0
    local current
    current="$(pyenv version-name 2>/dev/null)"
    [[ "$current" == "$wanted" ]] && return 0
    if pyenv versions --bare 2>/dev/null | grep -q "^${wanted}$"; then
        pyenv local "$wanted" 2>/dev/null \
            && log_debug "auto-activate: Python → $wanted (pyenv)"
    else
        log_warn "auto-activate: Python $wanted not installed. Run: pyenv install $wanted"
    fi
}

# --- Node.js via nvm (switch ungated; MISSING-version install = node_install) ---
aa_node() {
    typeset -f nvm >/dev/null 2>&1 || return 0
    local dir="${1:-$PWD}"
    local nvmrc
    nvmrc="$(_aa_find_up "$dir" 3 .nvmrc .node-version)" || return 0
    local wanted
    wanted="$(tr -d '[:space:]' < "$nvmrc")"
    [[ -z "$wanted" ]] && return 0
    local current
    current="$(nvm current 2>/dev/null)"
    # Strip leading 'v' for comparison
    [[ "${current#v}" == "${wanted#v}" ]] && return 0
    if nvm use "$wanted" --silent 2>/dev/null; then
        log_debug "auto-activate: Node → $wanted"
        return 0
    fi
    # Version missing: installing is a separately-trusted capability (B1.2)
    if auto_is_trusted "$dir" node_install; then
        nvm install "$wanted" 2>/dev/null \
            && log_debug "auto-activate: Node installed → $wanted"
    else
        log_debug "auto-activate: Node $wanted not installed; project not trusted for node_install — skipped"
    fi
}

# --- Node.js via fnm (switch ungated; install gated like aa_node) ---
aa_fnm() {
    command -v fnm >/dev/null 2>&1 || return 0
    local dir="${1:-$PWD}"
    local node_file
    node_file="$(_aa_find_up "$dir" 3 .node-version .nvmrc)" || return 0
    local wanted
    wanted="$(tr -d '[:space:]' < "$node_file")"
    [[ -z "$wanted" ]] && return 0
    local current
    current="$(fnm current 2>/dev/null)"
    # Strip leading 'v' for comparison
    [[ "${current#v}" == "${wanted#v}" ]] && return 0
    if fnm use "$wanted" --silent-if-unchanged 2>/dev/null; then
        log_debug "auto-activate: Node → $wanted (fnm)"
        return 0
    fi
    if auto_is_trusted "$dir" node_install; then
        fnm install "$wanted" 2>/dev/null \
            && log_debug "auto-activate: Node installed → $wanted (fnm)"
    else
        log_debug "auto-activate: Node $wanted not installed; project not trusted for node_install — skipped (fnm)"
    fi
}

# --- Bun (informational warning only — never mutates anything) ---
aa_bun() {
    command -v bun >/dev/null 2>&1 || return 0
    local dir="${1:-$PWD}"
    local bun_file
    bun_file="$(_aa_find_up "$dir" 3 .bun-version)" || return 0
    local wanted
    wanted="$(tr -d '[:space:]' < "$bun_file")"
    [[ -z "$wanted" ]] && return 0
    # bun does not have a version-switch command like nvm;
    # honor .bun-version by printing a warning if the active version doesn't match.
    local current
    current="$(bun --version 2>/dev/null)"
    if [[ "$current" != "$wanted" ]]; then
        log_warn "auto-activate: .bun-version=$wanted but active bun=$current"
        log_warn "  → Run: bun upgrade --version $wanted"
    fi
}

# --- Go via goenv (switch only — never installs) ---
aa_go() {
    command -v goenv >/dev/null 2>&1 || return 0
    local dir="${1:-$PWD}"
    local go_file
    go_file="$(_aa_find_up "$dir" 3 .go-version)" || return 0
    local wanted
    wanted="$(tr -d '[:space:]' < "$go_file")"
    [[ -z "$wanted" ]] && return 0
    local current
    current="$(goenv version-name 2>/dev/null)"
    [[ "$current" == "$wanted" ]] && return 0
    if goenv versions --bare 2>/dev/null | grep -q "^${wanted}$"; then
        goenv local "$wanted" 2>/dev/null \
            && log_debug "auto-activate: Go → $wanted"
    else
        log_warn "auto-activate: Go $wanted not installed. Run: goenv install $wanted"
    fi
}

# --- Ruby via rbenv (switch only — never installs) ---
aa_ruby() {
    command -v rbenv >/dev/null 2>&1 || return 0
    local dir="${1:-$PWD}"
    local ruby_file
    ruby_file="$(_aa_find_up "$dir" 3 .ruby-version)" || return 0
    local wanted
    wanted="$(tr -d '[:space:]' < "$ruby_file")"
    [[ -z "$wanted" ]] && return 0
    local current
    current="$(rbenv version-name 2>/dev/null)"
    [[ "$current" == "$wanted" ]] && return 0
    if rbenv versions --bare 2>/dev/null | grep -q "^${wanted}$"; then
        rbenv local "$wanted" 2>/dev/null \
            && log_debug "auto-activate: Ruby → $wanted"
    else
        log_warn "auto-activate: Ruby $wanted not installed. Run: rbenv install $wanted"
    fi
}

# --- Java via jenv (switch only) ---
aa_java() {
    command -v jenv >/dev/null 2>&1 || return 0
    local dir="${1:-$PWD}"
    local java_file
    java_file="$(_aa_find_up "$dir" 3 .java-version)" || return 0
    local wanted
    wanted="$(tr -d '[:space:]' < "$java_file")"
    [[ -z "$wanted" ]] && return 0
    local current
    current="$(jenv version-name 2>/dev/null)"
    [[ "$current" == "$wanted" ]] && return 0
    jenv local "$wanted" 2>/dev/null \
        && log_debug "auto-activate: Java → $wanted"
}

# --- PHP via phpenv (switch only — never installs) ---
aa_php() {
    command -v phpenv >/dev/null 2>&1 || return 0
    local dir="${1:-$PWD}"
    local php_file
    php_file="$(_aa_find_up "$dir" 3 .php-version)" || return 0
    local wanted
    wanted="$(tr -d '[:space:]' < "$php_file")"
    [[ -z "$wanted" ]] && return 0
    local current
    current="$(phpenv version-name 2>/dev/null)"
    [[ "$current" == "$wanted" ]] && return 0
    if phpenv versions --bare 2>/dev/null | grep -q "^${wanted}$"; then
        phpenv local "$wanted" 2>/dev/null \
            && log_debug "auto-activate: PHP → $wanted"
    else
        log_warn "auto-activate: PHP $wanted not installed. Run: phpenv install $wanted"
    fi
}

# --- Node.js global symlink sync (capability: symlink_sync — PRIVILEGED) ---
# After an nvm (or fnm) version switch, optionally update
# /usr/local/bin/{node,npm,npx} symlinks so desktop apps (Electron, VS Code
# extensions, etc.) see the new version. Two independent gates (B1.2):
#   1. DEV_AUTO_SYNC_NODE_SYMLINKS=true (user opt-in), AND
#   2. the CURRENT project is trusted for symlink_sync.
# Never prompts for a password; the sudo -n fallback is attempted only when
# both gates pass.
_nvm_sync_symlinks() {
    local dir="${1:-$PWD}"
    [[ "${DEV_AUTO_SYNC_NODE_SYMLINKS:-false}" == "true" ]] || return 0
    if ! auto_is_trusted "$dir" symlink_sync; then
        log_debug "auto-activate: symlink sync skipped (project not trusted for symlink_sync)"
        return 0
    fi

    local nvm_bin=""

    # Determine the active Node bin directory
    if [[ -n "${NVM_DIR:-}" ]]; then
        local cur
        cur="$(nvm current 2>/dev/null)" || return 0
        [[ "$cur" == "system" || "$cur" == "none" || -z "$cur" ]] && return 0
        nvm_bin="$NVM_DIR/versions/node/${cur}/bin"
    elif command -v fnm >/dev/null 2>&1; then
        local fnm_cur
        fnm_cur="$(fnm current 2>/dev/null)" || return 0
        [[ "$fnm_cur" == "none" || -z "$fnm_cur" ]] && return 0
        # fnm stores versions under its own directory
        local fnm_dir="${FNM_DIR:-$HOME/.local/share/fnm}"
        nvm_bin="$fnm_dir/node-versions/v${fnm_cur#v}/installation/bin"
    fi

    [[ -d "$nvm_bin" ]] || return 0

    # If /usr/local/bin/node already points to the right place, skip
    local current_target
    current_target="$(readlink /usr/local/bin/node 2>/dev/null)" || true
    [[ "$current_target" == "$nvm_bin/node" ]] && return 0

    # Attempt update — never prompt for password
    local cmd
    for cmd in node npm npx; do
        [[ -f "$nvm_bin/$cmd" ]] || continue
        ln -sf "$nvm_bin/$cmd" /usr/local/bin/"$cmd" 2>/dev/null \
            || sudo -n ln -sf "$nvm_bin/$cmd" /usr/local/bin/"$cmd" 2>/dev/null \
            || true
    done
}

# --- Rust (informational only — rustup auto-handles rust-toolchain natively) ---
aa_rust() {
    # rustup reads rust-toolchain / rust-toolchain.toml automatically.
    # Nothing to inject — listed here for documentation completeness.
    return 0
}

# --- asdf universal version manager ---
# asdf works via shims — versions are resolved at execution time, not on cd.
# The hook here: if .tool-versions is present and asdf is installed, run
# `asdf reshim` to ensure shims are current (e.g. after `asdf install`).
aa_asdf() {
    command -v asdf >/dev/null 2>&1 || return 0
    local dir="${1:-$PWD}"
    local tool_versions
    tool_versions="$(_aa_find_up "$dir" 3 .tool-versions)" || return 0
    # asdf auto-resolves versions through shims — just ensure they are fresh
    asdf reshim 2>/dev/null || true
    log_debug "auto-activate: asdf reshim (found $tool_versions)"
}

# Master caller — runs all handlers in order (bash side; defaults to $PWD)
auto_activate_all() {
    local dir="${1:-$PWD}"
    aa_python "$dir"
    aa_pyenv "$dir"
    aa_node "$dir"
    aa_fnm "$dir"
    aa_bun "$dir"
    aa_go "$dir"
    aa_ruby "$dir"
    aa_java "$dir"
    aa_php "$dir"
    aa_rust
    aa_asdf "$dir"
    _nvm_sync_symlinks "$dir"
}

# ============================================================================
# HOOK BODY — single source of truth (B1.2)
# ============================================================================
# The chpwd glue emitted into .zshrc is exactly `_dev_chpwd_hook() {
# auto_activate_on_cd "$PWD"; }`; the body below is what auto_activate_setup
# dumps verbatim into the rc (typeset -f), so tests exercise the same code
# users run. Capability gates live here and in the handlers above.

auto_activate_on_cd() {
    local dir="${1:-$PWD}"
    aa_python "$dir"          # gated: venv_source
    aa_pyenv "$dir"           # switch only
    aa_node "$dir"            # switch ungated; install gated: node_install
    aa_fnm "$dir"             # switch ungated; install gated: node_install
    aa_bun "$dir"             # informational only
    aa_go "$dir"              # switch only
    aa_ruby "$dir"            # switch only
    aa_java "$dir"            # switch only
    aa_php "$dir"             # switch only
    aa_rust                   # no-op (rustup native)
    aa_asdf "$dir"            # reshim only
    _nvm_sync_symlinks "$dir" # gated: symlink_sync (+ DEV_AUTO_SYNC_NODE_SYMLINKS)
    return 0
}

# ============================================================================
# ZSH HOOK INSTALLATION
# ============================================================================

# Install a unified chpwd hook into ~/.zshrc (or $ZDOTDIR/.zshrc).
# Safe to call multiple times — idempotent.
# The rc mutation is transactional (M2): pre-state backed up, rollback on
# any emission failure (B1.2).
auto_activate_setup() {
    local shell_rc="${ZDOTDIR:-$HOME}/.zshrc"

    if [[ "${SHELL##*/}" != "zsh" ]]; then
        log_error "auto_activate_setup requires zsh (current shell: ${SHELL##*/})"
        return 1
    fi

    if grep -q "$_AA_START" "$shell_rc" 2>/dev/null; then
        log_info "dev auto-activate hook already installed in $shell_rc"
        return 0
    fi

    transaction_start "auto_activate_setup" || return 1
    if ! transaction_add_file "$shell_rc"; then
        transaction_rollback >/dev/null 2>&1
        return 1
    fi

    {
        printf '\n%s\n' "$_AA_START"
        cat <<'ZSHOOK'
# Unified runtime auto-activation — capability-gated (B1.2).
# The hook only SWITCHES between already-installed versions. Three
# capabilities require explicit per-project trust (auto_trust <dir> <cap>):
#   venv_source   — source the project's .venv/bin/activate (repo code)
#   node_install  — install a MISSING Node version from .nvmrc/.node-version
#   symlink_sync  — update /usr/local/bin/{node,npm,npx} (incl. sudo -n)
# Registry: $HOME/.config/version-manager/trusted-projects
#           <sha256-of-canonical-project-dir><TAB><capability>
# Optional symlink sync env: DEV_AUTO_SYNC_NODE_SYMLINKS=true (plus trust).
# Managed by version-management-setup — edit lib/auto-activate.sh to change.
ZSHOOK
        cat <<'ZSHOOK'
# Logger fallbacks — per-function guards (the rc may load its own logger).
typeset -f log_info >/dev/null 2>&1 || log_info() { printf '[INFO] %s\n' "$*"; }
typeset -f log_warn >/dev/null 2>&1 || log_warn() { printf '[WARN] %s\n' "$*" >&2; }
typeset -f log_error >/dev/null 2>&1 || log_error() { printf '[ERROR] %s\n' "$*" >&2; }
typeset -f log_success >/dev/null 2>&1 || log_success() { printf '[OK] %s\n' "$*"; }
typeset -f log_debug >/dev/null 2>&1 || log_debug() { :; }
ZSHOOK
        # Self-contained runtime: trust registry + handlers, emitted verbatim
        # from this library (single source of truth — see TRUST MODEL above).
        typeset -f _aa_trust_registry _aa_canonical_dir _aa_sha256_str auto_is_trusted \
            _aa_find_up aa_python aa_pyenv aa_node aa_fnm aa_bun aa_go aa_ruby aa_java \
            aa_php aa_rust aa_asdf _nvm_sync_symlinks auto_activate_on_cd
        cat <<'ZSHOOK'

# chpwd glue — the hook body lives in auto_activate_on_cd (emitted above).
_dev_chpwd_hook() { auto_activate_on_cd "$PWD"; }
autoload -Uz add-zsh-hook 2>/dev/null
add-zsh-hook chpwd _dev_chpwd_hook
_dev_chpwd_hook   # run for current directory on shell start-up

# ---------- nvm wrapper: auto-sync symlinks on manual switches ----------
# Wraps the nvm function so that `nvm use`, `nvm install`, and `nvm alias`
# attempt the /usr/local/bin sync — which is itself gated on the CURRENT
# project's symlink_sync trust (see _nvm_sync_symlinks).
if typeset -f nvm >/dev/null 2>&1; then
    _nvm_real=$(functions nvm)
    eval "_nvm_original() { ${_nvm_real#nvm*\{}"
    nvm() {
        local _nvm_prev_ver
        _nvm_prev_ver="$(_nvm_original current 2>/dev/null || echo "none")"
        _nvm_original "$@"
        local _nvm_ret=$?
        case "${1:-}" in
            use|install|alias)
                _nvm_sync_symlinks 2>/dev/null
                # Auto-sync global packages after install (skip if user specified --reinstall-packages-from)
                if [[ "${1:-}" == "install" && "$*" != *"--reinstall-packages-from"* ]]; then
                    local _nvm_new_ver
                    _nvm_new_ver="$(_nvm_original current 2>/dev/null || echo "none")"
                    if [[ "$_nvm_prev_ver" != "none" && "$_nvm_prev_ver" != "system" && "$_nvm_prev_ver" != "$_nvm_new_ver" ]]; then
                        _nvm_original reinstall-packages "$_nvm_prev_ver" >/dev/null 2>&1 \
                            || print -P "%F{yellow}[auto-activate] Could not sync packages from $_nvm_prev_ver%f"
                    fi
                fi
                ;;
        esac
        return $_nvm_ret
    }
fi
# <<< dev auto-activate hook <<<
ZSHOOK
    } >> "$shell_rc" || {
        transaction_rollback >/dev/null 2>&1
        return 1
    }

    # Fail closed: every emitted function must actually be present (typeset -f
    # silently skips undefined names).
    local fn missing=""
    for fn in _aa_trust_registry _aa_canonical_dir _aa_sha256_str auto_is_trusted \
              _aa_find_up aa_python aa_pyenv aa_node aa_fnm aa_bun aa_go aa_ruby \
              aa_java aa_php aa_rust aa_asdf _nvm_sync_symlinks auto_activate_on_cd; do
        grep -q "^${fn} ()" "$shell_rc" || missing="$missing $fn"
    done
    if [[ -n "$missing" ]]; then
        log_error "auto_activate_setup: emission incomplete — missing:$missing"
        transaction_rollback >/dev/null 2>&1
        return 1
    fi

    transaction_commit
    log_success "dev auto-activate hook installed in $shell_rc"
    log_info "Applies to: Python venv/pyenv, Node (nvm/fnm), Bun, Go (goenv), Ruby (rbenv), Java (jenv), PHP (phpenv)"
    log_info "Trust-gated capabilities: venv_source, node_install, symlink_sync (see auto_trust)"
    log_info "Optional symlink sync env: set DEV_AUTO_SYNC_NODE_SYMLINKS=true AND trust the project for symlink_sync"
    log_info "Restart your terminal or run: source $shell_rc"
    return 0
}

# Remove the hook from ~/.zshrc (transactional — pre-state backed up, B1.2)
auto_activate_remove() {
    local shell_rc="${ZDOTDIR:-$HOME}/.zshrc"

    if ! grep -q "$_AA_START" "$shell_rc" 2>/dev/null; then
        log_info "dev auto-activate hook not found in $shell_rc"
        return 0
    fi

    transaction_start "auto_activate_remove" || return 1
    if ! transaction_add_file "$shell_rc"; then
        transaction_rollback >/dev/null 2>&1
        return 1
    fi

    local tmp
    tmp="$(mktemp)" || { transaction_rollback >/dev/null 2>&1; return 1; }
    if ! awk "/^# >>> dev auto-activate hook <<<\$/,/^# <<< dev auto-activate hook <<<\$/{next} 1" \
            "$shell_rc" > "$tmp"; then
        rm -f "$tmp" 2>/dev/null
        transaction_rollback >/dev/null 2>&1
        return 1
    fi
    if ! mv "$tmp" "$shell_rc"; then
        rm -f "$tmp" 2>/dev/null
        transaction_rollback >/dev/null 2>&1
        return 1
    fi
    transaction_commit
    log_success "dev auto-activate hook removed from $shell_rc"
    return 0
}

# Export public API
export -f auto_activate_all auto_activate_on_cd auto_activate_setup auto_activate_remove
export -f auto_trust auto_untrust auto_is_trusted
export -f aa_python aa_pyenv aa_node aa_fnm aa_bun aa_go aa_ruby aa_java aa_php aa_rust aa_asdf
export -f _aa_find_up _nvm_sync_symlinks
export -f _aa_trust_registry _aa_canonical_dir _aa_sha256_str
