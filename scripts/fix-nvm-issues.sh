#!/usr/bin/env bash
# Consolidated NVM Issue Fix Script — M4 managed-block adopter (canary)
# Combines: fix-nvm-silent.sh, fix-nvm-verbose.sh, silence-nvm-permanently.sh
#
# Directive M4 / findings B2.1 + P1-3: every rc mutation goes through the
# managed-block editor (lib/mutation.sh) under a transaction, converging on
# ONE canonical NVM block (NVM_SILENT=true — the '=1' vs '=true' drift was
# P1-3). Idempotent: reruns are byte-identical. --dry-run plans with zero
# writes. Legacy drift lines from pre-adoption runs are stripped.

# Only set strict mode when executing directly (not when sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
fi

# Resolve lib paths from THIS file's location (not an inherited SCRIPT_DIR,
# which points elsewhere when this script is sourced by a test harness).
_NVM_FIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_NVM_FIX_ROOT="$(cd "${_NVM_FIX_DIR}/.." && pwd)"

# Source logger UNCONDITIONALLY, and from a CLEAN function slate: inherited
# (export -f) logger functions reference color variables that do not travel
# with them — under this script's direct-execution `set -u` that combination
# aborts every log call (reproduced via the M4 test matrix).
unset -f log_info log_warn log_error log_success log_debug init_logger _log _write_to_file _get_timestamp _supports_color 2>/dev/null || true
if [[ -f "${_NVM_FIX_ROOT}/lib/logger.sh" ]]; then
    source "${_NVM_FIX_ROOT}/lib/logger.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# Unconditional (see lib/mutation.sh — inherited exported functions defeat
# declare -f guards across process boundaries).
source "${_NVM_FIX_ROOT}/lib/mutation.sh" || {
    log_error "Cannot load lib/mutation.sh (managed-block editor)"
    exit 1
}

show_usage() {
    echo "Usage: $0 [OPTION]"
    echo "Fix various NVM-related issues"
    echo
    echo "Options:"
    echo "  --silent     Enable silent mode (reduce verbose output)"
    echo "  --verbose    Fix verbose output issues"
    echo "  --permanent  Permanently silence NVM directory messages"
    echo "  --all        Apply all fixes"
    echo "  --dry-run    Plan only — zero writes"
    echo "  --help       Show this help message"
}

# Strip legacy pre-adoption drift lines (exact matches only — our own past
# output, never user content). Runs inside the caller's transaction; the
# file is already transaction-registered by the managed-block editor.
_fix_nvm_strip_legacy() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local tmp
    tmp=$(mktemp "$(dirname "$file")/.vms-legacy.XXXXXX") || return 1
    grep -vFx -e 'export NVM_SILENT=1' \
              -e '# Silence NVM verbose messages' \
              -e '# NVM Permanent Silence Configuration' \
        "$file" > "$tmp" || true
    if ! cmp -s "$tmp" "$file"; then
        local mode
        mode=$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file" 2>/dev/null || echo 644)
        chmod "$mode" "$tmp"
        mv "$tmp" "$file"
        log_info "Legacy drift lines removed"
    else
        rm -f "$tmp"
    fi
    return 0
}

# Converge $HOME/.zshrc onto the canonical managed NVM block (and, for
# --permanent, the auto-switch block). Caller owns the transaction.
_fix_nvm_converge() {
    local zshrc="$HOME/.zshrc" with_autoswitch="$1"

    if [[ ! -f "$zshrc" ]]; then
        log_warn "$HOME/.zshrc not found"
        return 1
    fi

    local content
    content=$(mktemp "${TMPDIR:-/tmp}/vms-nvm-block.XXXXXX") || return 1
    mutation_nvm_block > "$content"
    mutation_block_write "$zshrc" "nvm" "$content" || { rm -f "$content"; return 1; }

    if [[ "$with_autoswitch" == "true" ]]; then
        cat << 'AUTOSWITCH' > "$content"
# Auto-switch node version silently when entering directories
autoload -U add-zsh-hook 2>/dev/null
load-nvmrc() {
    local node_version="$(nvm version 2>/dev/null)"
    local nvmrc_path="$(nvm_find_nvmrc 2>/dev/null)"
    if [ -n "$nvmrc_path" ]; then
        local nvmrc_node_version=$(nvm version "$(cat "${nvmrc_path}")" 2>/dev/null)
        if [ "$nvmrc_node_version" = "N/A" ]; then
            nvm install >/dev/null 2>&1
        elif [ "$nvmrc_node_version" != "$node_version" ]; then
            nvm use >/dev/null 2>&1
        fi
    fi
}
add-zsh-hook chpwd load-nvmrc 2>/dev/null
load-nvmrc
AUTOSWITCH
        mutation_block_write "$zshrc" "nvm_autoswitch" "$content" || { rm -f "$content"; return 1; }
    fi
    rm -f "$content"

    _fix_nvm_strip_legacy "$zshrc"
    return 0
}

fix_silent_mode() {
    log_info "🔇 Configuring NVM silent mode..."
    transaction_start "fix_nvm_silent" || return 1
    if _fix_nvm_converge false; then
        transaction_commit
        log_success "NVM silent mode enabled (canonical block)"
        return 0
    fi
    transaction_rollback
    log_error "NVM silent mode configuration FAILED — rolled back"
    return 1
}

fix_verbose_issues() {
    log_info " Fixing NVM verbose output issues..."
    transaction_start "fix_nvm_verbose" || return 1
    if _fix_nvm_converge false; then
        transaction_commit
        log_success "Verbose issues fixed (canonical block)"
        return 0
    fi
    transaction_rollback
    log_error "Verbose fix FAILED — rolled back"
    return 1
}

permanent_silence() {
    log_info "🔕 Permanently silencing NVM directory messages..."
    transaction_start "fix_nvm_permanent" || return 1
    if _fix_nvm_converge true; then
        transaction_commit
        log_success "NVM permanently silenced (canonical blocks)"
        return 0
    fi
    transaction_rollback
    log_error "Permanent silence FAILED — rolled back"
    return 1
}

# Main function that applies all fixes (for testing and programmatic use)
fix_nvm_issues() {
    log_info " Running all NVM fixes..."
    local success=true

    fix_silent_mode || success=false
    fix_verbose_issues || success=false
    permanent_silence || success=false

    if [[ "$success" == "true" ]]; then
        log_success "All NVM fixes applied successfully"
        return 0
    else
        log_warn "Some NVM fixes may not have been applied"
        return 1
    fi
}

# Main execution - only run when script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --dry-run)
            export TRANSACTION_DRY_RUN=1
            shift
            case "${1:-}" in
                --silent)    fix_silent_mode ;;
                --verbose)   fix_verbose_issues ;;
                --permanent) permanent_silence ;;
                --all|*)     fix_nvm_issues ;;
            esac
            ;;
        --silent)    fix_silent_mode ;;
        --verbose)   fix_verbose_issues ;;
        --permanent) permanent_silence ;;
        --all)       fix_nvm_issues ;;
        --help)      show_usage ;;
        *)           show_usage; exit 1 ;;
    esac
fi
