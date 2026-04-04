#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source paths; SC2034: intentionally exported vars

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/logger.sh"

# Hook block delimiters — must stay in sync with _auto_activate_remove()
readonly _AA_START="# >>> dev auto-activate hook <<<"
readonly _AA_END="# <<< dev auto-activate hook <<<"

# ============================================================================
# RUNTIME DETECTION HELPERS  (called from the installed zsh hook)
# ============================================================================

# Walk upward from $1 (default: $PWD) for up to $2 (default: 3) levels
# looking for any file in $3 (space-separated list of names).
# Echoes the first match found; returns 1 if nothing found.
_aa_find_up() {
    local dir="${1:-$PWD}"
    local max="${2:-3}"
    local depth=0
    local file
    while [[ "$dir" != "/" && $depth -lt $max ]]; do
        for file in $3; do
            [[ -e "$dir/$file" ]] && { echo "$dir/$file"; return 0; }
        done
        dir="$(dirname "$dir")"
        depth=$((depth + 1))
    done
    return 1
}

# ============================================================================
# INDIVIDUAL RUNTIME HANDLERS  (bash-callable, also embedded into zsh hook)
# ============================================================================

# --- Python venv ---
aa_python() {
    local venv_dirs=(".venv" "venv" ".virtualenv")
    local activate_script="" venv_dir
    local dir="$PWD" depth=0 vname

    while [[ "$dir" != "/" && $depth -lt 3 ]]; do
        for vname in "${venv_dirs[@]}"; do
            if [[ -f "$dir/$vname/bin/activate" ]]; then
                activate_script="$dir/$vname/bin/activate"
                break 2
            fi
        done
        dir="$(dirname "$dir")"
        depth=$((depth + 1))
    done

    if [[ -n "$activate_script" ]]; then
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

# --- Python version via pyenv ---
aa_pyenv() {
    command -v pyenv >/dev/null 2>&1 || return 0
    local pyver_file
    pyver_file="$(_aa_find_up "$PWD" 3 ".python-version")" || return 0
    local wanted
    wanted="$(cat "$pyver_file" 2>/dev/null | tr -d '[:space:]')"
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

# --- Node.js via nvm ---
aa_node() {
    command -v nvm >/dev/null 2>&1 || return 0
    local nvmrc
    nvmrc="$(_aa_find_up "$PWD" 3 ".nvmrc .node-version")" || return 0
    local wanted
    wanted="$(cat "$nvmrc" 2>/dev/null | tr -d '[:space:]')"
    [[ -z "$wanted" ]] && return 0
    local current
    current="$(nvm current 2>/dev/null)"
    # Strip leading 'v' for comparison
    [[ "${current#v}" == "${wanted#v}" ]] && return 0
    nvm use "$wanted" --silent 2>/dev/null \
        || nvm install "$wanted" 2>/dev/null \
        && log_debug "auto-activate: Node → $wanted"
}

# --- Node.js via fnm ---
aa_fnm() {
    command -v fnm >/dev/null 2>&1 || return 0
    local node_file
    node_file="$(_aa_find_up "$PWD" 3 ".node-version .nvmrc")" || return 0
    local wanted
    wanted="$(cat "$node_file" 2>/dev/null | tr -d '[:space:]')"
    [[ -z "$wanted" ]] && return 0
    local current
    current="$(fnm current 2>/dev/null)"
    # Strip leading 'v' for comparison
    [[ "${current#v}" == "${wanted#v}" ]] && return 0
    fnm use "$wanted" --silent-if-unchanged 2>/dev/null \
        || fnm install "$wanted" 2>/dev/null \
        && log_debug "auto-activate: Node → $wanted (fnm)"
}

# --- Bun ---
aa_bun() {
    command -v bun >/dev/null 2>&1 || return 0
    local bun_file
    bun_file="$(_aa_find_up "$PWD" 3 ".bun-version")" || return 0
    local wanted
    wanted="$(cat "$bun_file" 2>/dev/null | tr -d '[:space:]')"
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

# --- Go via goenv ---
aa_go() {
    command -v goenv >/dev/null 2>&1 || return 0
    local go_file
    go_file="$(_aa_find_up "$PWD" 3 ".go-version")" || return 0
    local wanted
    wanted="$(cat "$go_file" 2>/dev/null | tr -d '[:space:]')"
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

# --- Ruby via rbenv ---
aa_ruby() {
    command -v rbenv >/dev/null 2>&1 || return 0
    local ruby_file
    ruby_file="$(_aa_find_up "$PWD" 3 ".ruby-version")" || return 0
    local wanted
    wanted="$(cat "$ruby_file" 2>/dev/null | tr -d '[:space:]')"
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

# --- Java via jenv ---
aa_java() {
    command -v jenv >/dev/null 2>&1 || return 0
    local java_file
    java_file="$(_aa_find_up "$PWD" 3 ".java-version")" || return 0
    local wanted
    wanted="$(cat "$java_file" 2>/dev/null | tr -d '[:space:]')"
    [[ -z "$wanted" ]] && return 0
    local current
    current="$(jenv version-name 2>/dev/null)"
    [[ "$current" == "$wanted" ]] && return 0
    jenv local "$wanted" 2>/dev/null \
        && log_debug "auto-activate: Java → $wanted"
}

# --- PHP via phpenv ---
aa_php() {
    command -v phpenv >/dev/null 2>&1 || return 0
    local php_file
    php_file="$(_aa_find_up "$PWD" 3 ".php-version")" || return 0
    local wanted
    wanted="$(cat "$php_file" 2>/dev/null | tr -d '[:space:]')"
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

# --- Node.js global symlink sync ---
# After an nvm (or fnm) version switch, optionally update
# /usr/local/bin/{node,npm,npx} symlinks so desktop apps (Electron, VS Code
# extensions, etc.) see the new version.
# Disabled by default. Set DEV_AUTO_SYNC_NODE_SYMLINKS=true to enable.
_nvm_sync_symlinks() {
    [[ "${DEV_AUTO_SYNC_NODE_SYMLINKS:-false}" == "true" ]] || return 0

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
    local tool_versions
    tool_versions="$(_aa_find_up "$PWD" 3 ".tool-versions")" || return 0
    # asdf auto-resolves versions through shims — just ensure they are fresh
    asdf reshim 2>/dev/null || true
    log_debug "auto-activate: asdf reshim (found $tool_versions)"
}

# Master caller — runs all handlers in order
auto_activate_all() {
    aa_python
    aa_pyenv
    aa_node
    aa_fnm
    aa_bun
    aa_go
    aa_ruby
    aa_java
    aa_php
    aa_rust
    aa_asdf
}

# ============================================================================
# ZSH HOOK INSTALLATION
# ============================================================================

# Install a unified chpwd hook into ~/.zshrc (or $ZDOTDIR/.zshrc).
# Safe to call multiple times — idempotent.
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

    cat >> "$shell_rc" <<'ZSHOOK'

# >>> dev auto-activate hook <<<
# Unified runtime auto-activation for Python, Node, Bun, Go, Ruby, Java, PHP, FNM, pyenv.
# Optional: set DEV_AUTO_SYNC_NODE_SYMLINKS=true to auto-sync /usr/local/bin/node symlinks.
# Managed by version-management-setup — edit lib/auto-activate.sh to change.
_dev_chpwd_hook() {
    # ---------- helpers ----------
    _aa_h_find_up() {
        local dir="${1:-$PWD}" max="${2:-3}" depth=0 f
        while [[ "$dir" != "/" && $depth -lt $max ]]; do
            for f in ${=3}; do
                [[ -e "$dir/$f" ]] && { echo "$dir/$f"; return 0; }
            done
            dir="${dir:h}"
            depth=$(( depth + 1 ))
        done
        return 1
    }

    # Sync /usr/local/bin/node symlinks to the active NVM/FNM version.
    # Disabled unless DEV_AUTO_SYNC_NODE_SYMLINKS=true.
    _aa_h_sync_node_symlinks() {
        [[ "${DEV_AUTO_SYNC_NODE_SYMLINKS:-false}" == "true" ]] || return 0

        local _sn_bin=""
        if [[ -n "${NVM_DIR:-}" ]] && typeset -f nvm >/dev/null 2>&1; then
            local _sn_cur
            _sn_cur="$(nvm current 2>/dev/null)" || return 0
            [[ "$_sn_cur" == "system" || "$_sn_cur" == "none" || -z "$_sn_cur" ]] && return 0
            _sn_bin="$NVM_DIR/versions/node/${_sn_cur}/bin"
        elif command -v fnm >/dev/null 2>&1; then
            local _sn_fcur
            _sn_fcur="$(fnm current 2>/dev/null)" || return 0
            [[ "$_sn_fcur" == "none" || -z "$_sn_fcur" ]] && return 0
            local _sn_fdir="${FNM_DIR:-$HOME/.local/share/fnm}"
            _sn_bin="$_sn_fdir/node-versions/v${_sn_fcur#v}/installation/bin"
        fi
        [[ -d "$_sn_bin" ]] || return 0
        # Skip if already correct
        [[ "$(readlink /usr/local/bin/node 2>/dev/null)" == "$_sn_bin/node" ]] && return 0
        local _sn_c
        for _sn_c in node npm npx; do
            [[ -f "$_sn_bin/$_sn_c" ]] || continue
            ln -sf "$_sn_bin/$_sn_c" /usr/local/bin/"$_sn_c" 2>/dev/null \
                || sudo -n ln -sf "$_sn_bin/$_sn_c" /usr/local/bin/"$_sn_c" 2>/dev/null \
                || true
        done
    }

    # ---------- Python venv ----------
    local _py_venv_dirs=(.venv venv .virtualenv)
    local _py_act="" _py_vdir="" _py_d="$PWD" _py_depth=0 _py_vn
    while [[ "$_py_d" != "/" && $_py_depth -lt 3 ]]; do
        for _py_vn in "${_py_venv_dirs[@]}"; do
            if [[ -f "$_py_d/$_py_vn/bin/activate" ]]; then
                _py_act="$_py_d/$_py_vn/bin/activate"
                break 2
            fi
        done
        _py_d="${_py_d:h}"
        _py_depth=$(( _py_depth + 1 ))
    done
    if [[ -n "$_py_act" ]]; then
        _py_vdir="${_py_act:h:h}"
        if [[ "${VIRTUAL_ENV:-}" != "$_py_vdir" ]]; then
            [[ -n "${VIRTUAL_ENV:-}" ]] && typeset -f deactivate >/dev/null 2>&1 && deactivate
            source "$_py_act"
        fi
    elif [[ -n "${VIRTUAL_ENV:-}" ]]; then
        typeset -f deactivate >/dev/null 2>&1 && deactivate
    fi

    # ---------- Python version via pyenv ----------
    if command -v pyenv >/dev/null 2>&1; then
        local _pyv_f
        _pyv_f="$(_aa_h_find_up "$PWD" 3 ".python-version")" 2>/dev/null
        if [[ -n "$_pyv_f" ]]; then
            local _pyv_want
            _pyv_want="$(< "$_pyv_f" tr -d '[:space:]')"
            if [[ -n "$_pyv_want" && "$(pyenv version-name 2>/dev/null)" != "$_pyv_want" ]]; then
                if pyenv versions --bare 2>/dev/null | grep -q "^${_pyv_want}$"; then
                    pyenv local "$_pyv_want" 2>/dev/null
                else
                    print -P "%F{yellow}[auto-activate] Python ${_pyv_want} not installed. Run: pyenv install ${_pyv_want}%f"
                fi
            fi
        fi
    fi

    # ---------- Node.js via nvm ----------
    if typeset -f nvm >/dev/null 2>&1; then
        local _nvm_f
        _nvm_f="$(_aa_h_find_up "$PWD" 3 ".nvmrc .node-version")" 2>/dev/null
        if [[ -n "$_nvm_f" ]]; then
            local _nvm_want
            _nvm_want="$(< "$_nvm_f" tr -d '[:space:]')"
            if [[ -n "$_nvm_want" && "${$(nvm current)#v}" != "${_nvm_want#v}" ]]; then
                if ! nvm use "$_nvm_want" --silent 2>/dev/null; then
                    local _nvm_sync_src
                    _nvm_sync_src="$(nvm current 2>/dev/null)"
                    if [[ -n "$_nvm_sync_src" && "$_nvm_sync_src" != "none" && "$_nvm_sync_src" != "system" ]]; then
                        nvm install "$_nvm_want" --reinstall-packages-from="$_nvm_sync_src" --silent 2>/dev/null
                    else
                        nvm install "$_nvm_want" --silent 2>/dev/null
                    fi
                fi
            fi
        fi
    fi

    # ---------- Node.js via fnm (used when nvm is not loaded) ----------
    if ! typeset -f nvm >/dev/null 2>&1 && command -v fnm >/dev/null 2>&1; then
        local _fnm_f
        _fnm_f="$(_aa_h_find_up "$PWD" 3 ".node-version .nvmrc")" 2>/dev/null
        if [[ -n "$_fnm_f" ]]; then
            local _fnm_want
            _fnm_want="$(< "$_fnm_f" tr -d '[:space:]')"
            if [[ -n "$_fnm_want" && "${$(fnm current 2>/dev/null)#v}" != "${_fnm_want#v}" ]]; then
                fnm use "$_fnm_want" --silent-if-unchanged 2>/dev/null \
                    || fnm install "$_fnm_want" 2>/dev/null
            fi
        fi
    fi

    # ---------- Sync /usr/local/bin symlinks after Node switch ----------
    _aa_h_sync_node_symlinks

    # ---------- Bun ----------
    if command -v bun >/dev/null 2>&1; then
        local _bun_f
        _bun_f="$(_aa_h_find_up "$PWD" 3 ".bun-version")" 2>/dev/null
        if [[ -n "$_bun_f" ]]; then
            local _bun_want _bun_cur
            _bun_want="$(< "$_bun_f" tr -d '[:space:]')"
            _bun_cur="$(bun --version 2>/dev/null)"
            if [[ -n "$_bun_want" && "$_bun_cur" != "$_bun_want" ]]; then
                print -P "%F{yellow}[auto-activate] .bun-version=${_bun_want} but active=${_bun_cur}%f"
                print -P "%F{yellow}  → Run: bun upgrade --version ${_bun_want}%f"
            fi
        fi
    fi

    # ---------- Go via goenv ----------
    if command -v goenv >/dev/null 2>&1; then
        local _go_f
        _go_f="$(_aa_h_find_up "$PWD" 3 ".go-version")" 2>/dev/null
        if [[ -n "$_go_f" ]]; then
            local _go_want
            _go_want="$(< "$_go_f" tr -d '[:space:]')"
            if [[ -n "$_go_want" && "$(goenv version-name 2>/dev/null)" != "$_go_want" ]]; then
                goenv local "$_go_want" 2>/dev/null \
                    || print -P "%F{yellow}[auto-activate] Go ${_go_want} not installed. Run: goenv install ${_go_want}%f"
            fi
        fi
    fi

    # ---------- Ruby via rbenv ----------
    if command -v rbenv >/dev/null 2>&1; then
        local _rb_f
        _rb_f="$(_aa_h_find_up "$PWD" 3 ".ruby-version")" 2>/dev/null
        if [[ -n "$_rb_f" ]]; then
            local _rb_want
            _rb_want="$(< "$_rb_f" tr -d '[:space:]')"
            if [[ -n "$_rb_want" && "$(rbenv version-name 2>/dev/null)" != "$_rb_want" ]]; then
                rbenv local "$_rb_want" 2>/dev/null \
                    || print -P "%F{yellow}[auto-activate] Ruby ${_rb_want} not installed. Run: rbenv install ${_rb_want}%f"
            fi
        fi
    fi

    # ---------- Java via jenv ----------
    if command -v jenv >/dev/null 2>&1; then
        local _jv_f
        _jv_f="$(_aa_h_find_up "$PWD" 3 ".java-version")" 2>/dev/null
        if [[ -n "$_jv_f" ]]; then
            local _jv_want
            _jv_want="$(< "$_jv_f" tr -d '[:space:]')"
            if [[ -n "$_jv_want" && "$(jenv version-name 2>/dev/null)" != "$_jv_want" ]]; then
                jenv local "$_jv_want" 2>/dev/null
            fi
        fi
    fi

    # ---------- PHP via phpenv ----------
    if command -v phpenv >/dev/null 2>&1; then
        local _php_f
        _php_f="$(_aa_h_find_up "$PWD" 3 ".php-version")" 2>/dev/null
        if [[ -n "$_php_f" ]]; then
            local _php_want
            _php_want="$(< "$_php_f" tr -d '[:space:]')"
            if [[ -n "$_php_want" && "$(phpenv version-name 2>/dev/null)" != "$_php_want" ]]; then
                phpenv local "$_php_want" 2>/dev/null \
                    || print -P "%F{yellow}[auto-activate] PHP ${_php_want} not installed. Run: phpenv install ${_php_want}%f"
            fi
        fi
    fi

    # Rust: rustup reads rust-toolchain / rust-toolchain.toml natively — no hook needed.
}

autoload -Uz add-zsh-hook 2>/dev/null
add-zsh-hook chpwd _dev_chpwd_hook
_dev_chpwd_hook   # run for current directory on shell start-up

# ---------- nvm wrapper: auto-sync symlinks on manual switches ----------
# Wraps the nvm function so that `nvm use`, `nvm install`, and `nvm alias`
# automatically update /usr/local/bin symlinks.
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
                _aa_h_sync_node_symlinks 2>/dev/null
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

    log_success "dev auto-activate hook installed in $shell_rc"
    log_info "Applies to: Python venv/pyenv, Node (nvm/fnm), Bun, Go (goenv), Ruby (rbenv), Java (jenv), PHP (phpenv)"
    log_info "Optional symlink sync: set DEV_AUTO_SYNC_NODE_SYMLINKS=true to update /usr/local/bin/{node,npm,npx}"
    log_info "Restart your terminal or run: source $shell_rc"
    return 0
}

# Remove the hook from ~/.zshrc
auto_activate_remove() {
    local shell_rc="${ZDOTDIR:-$HOME}/.zshrc"

    if ! grep -q "$_AA_START" "$shell_rc" 2>/dev/null; then
        log_info "dev auto-activate hook not found in $shell_rc"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"
    awk "/^# >>> dev auto-activate hook <<<\$/,/^# <<< dev auto-activate hook <<<\$/{next} 1" \
        "$shell_rc" > "$tmp" && mv "$tmp" "$shell_rc"
    log_success "dev auto-activate hook removed from $shell_rc"
    return 0
}

# Export public API
export -f auto_activate_all auto_activate_setup auto_activate_remove
export -f aa_python aa_pyenv aa_node aa_fnm aa_bun aa_go aa_ruby aa_java aa_php aa_rust aa_asdf
export -f _aa_find_up _nvm_sync_symlinks
