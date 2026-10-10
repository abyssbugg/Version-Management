# shellcheck shell=bash
# shellcheck disable=SC1091,SC2034,SC2155
# =============================================================================
# Shell-Experience Provisioning + Managed plugins=() Editor (M5 layer)
# =============================================================================
# Fills the review finding: the suite manages version managers but had NO
# mechanism for (a) provisioning the modern CLI/shell-experience tools and
# (b) managing the `plugins=( ... )` array in the user's .zshrc. Both are
# implemented here as a transaction-routed installer class — deliberately NOT
# through the version-manager plugin contract (semantics do not fit).
#
# Tool registry (case tables — no associative arrays, bash-3.2 safe):
#   clone-based: zsh-autosuggestions, zsh-syntax-highlighting
#       git clone into ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/<tool>
#       (omz convention: ZSH_CUSTOM points at .../custom, plugins live in
#       its plugins/ subdirectory). NO curl|bash anywhere.
#   package-based: fzf, zoxide, eza, bat, fd, ripgrep, direnv
#       macOS -> brew; Linux/WSL -> apt (sudo, confirm-gated exactly like
#       fix-terminal-issues' /etc/shells pattern).
#
# Contract (mirrors lib/mutation.sh):
#   - Plan-by-default (P0-6): shellxp_install prints a plan and writes
#     nothing until --confirm is passed (apt additionally honors the
#     VMS_CONFIRM=1 gate). --dry-run prints the same plan tagged [dry-run].
#   - Every mutation runs under a backup transaction (lib/backup.sh): every
#     created/modified path is registered BEFORE the mutation, writes are
#     atomic (same-directory temp + rename, symlink targets resolved), and
#     reruns against an unchanged state are byte-identical no-ops.
#   - Clone installs register the plugin directory as a NEW transaction
#     entry. The file-level primitive's rollback cannot rm -rf a directory,
#     so on post-clone verification failure the rollback runs first (loud,
#     journaled) and shell-experience then removes the directory it created
#     as an explicit, journaled compensation step.
#   - Clone-based plugin installs clone the upstream DEFAULT BRANCH. Pinning
#     to a reviewed commit SHA is a coordinator TODO (B1.8 discipline): until
#     pinned, treat every clone as upstream-unreviewed content. Tests never
#     touch the network — the clone URL may be overridden per tool via
#     SHELLXP_CLONE_URL_<TOOL_UPPER> (file:// or https:// only) for local
#     fixtures/mirrors.
#   - zsh-autosuggestions/zsh-syntax-highlighting are NEVER added to
#     plugins=() by the installer; activation is the separate, explicit
#     shellxp_plugins_add step below. zsh-syntax-highlighting must be LAST
#     in the array (upstream requirement) — ordering is enforced on add.
#
# This file SOURCES logger.sh, env.sh and mutation.sh (transactions,
# identifier/path validation, symlink resolution, byte-compare). Per the M1
# library contract it sets no global shell options and is re-source-safe.
# =============================================================================

_SHELLXP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SHELLXP_SYNTAX_HL="zsh-syntax-highlighting"

if ! declare -f log_error >/dev/null 2>&1; then
    source "$_SHELLXP_DIR/logger.sh"
fi
if ! declare -f get_os >/dev/null 2>&1; then
    source "$_SHELLXP_DIR/env.sh"
fi
if ! declare -f transaction_start >/dev/null 2>&1; then
    source "$_SHELLXP_DIR/mutation.sh"   # brings backup.sh + validation.sh
fi

# =============================================================================
# Registry (case tables: tool -> install method per platform)
# =============================================================================

shellxp_list_tools() {
    printf '%s\n' \
        zsh-autosuggestions \
        zsh-syntax-highlighting \
        fzf \
        zoxide \
        eza \
        bat \
        fd \
        ripgrep \
        direnv
    return 0
}

# Print "<method>:<spec>" for a tool, or fail closed for unknown tools /
# unsupported platforms. Methods: clone:<url> | brew:<pkg> | apt:<pkg>.
shellxp_registry_lookup() {
    local tool="$1"
    case "$tool" in
        zsh-autosuggestions)     echo "clone:https://github.com/zsh-users/zsh-autosuggestions.git" ;;
        zsh-syntax-highlighting) echo "clone:https://github.com/zsh-users/zsh-syntax-highlighting.git" ;;
        fzf)      _shellxp_pkg_spec "fzf" ;;
        zoxide)   _shellxp_pkg_spec "zoxide" ;;
        eza)      _shellxp_pkg_spec "eza" ;;
        bat)      _shellxp_pkg_spec "bat" ;;
        fd)       _shellxp_pkg_spec "fd" ;;
        ripgrep)  _shellxp_pkg_spec "ripgrep" ;;
        direnv)   _shellxp_pkg_spec "direnv" ;;
        *)
            log_error "shellxp: unknown tool '$tool' (registered: $(shellxp_list_tools | tr '\n' ' '))"
            return 1
            ;;
    esac
}

_shellxp_pkg_spec() {
    local pkg="$1" os
    os=$(get_os)
    case "$os" in
        macos)     echo "brew:$pkg" ;;
        linux|wsl) echo "apt:$pkg" ;;
        *)
            log_error "shellxp: no package method registered for '$pkg' on platform '$os'"
            return 1
            ;;
    esac
}

# Candidate binaries used for presence detection (Debian ships fd as fdfind
# and bat as batcat; ripgrep's binary is rg).
shellxp_tool_binaries() {
    case "$1" in
        fzf)        echo "fzf" ;;
        zoxide)     echo "zoxide" ;;
        eza)        echo "eza" ;;
        bat)        echo "bat batcat" ;;
        fd)         echo "fd fdfind" ;;
        ripgrep)    echo "rg" ;;
        direnv)     echo "direnv" ;;
        zsh-autosuggestions|zsh-syntax-highlighting) return 0 ;;
        *) return 1 ;;
    esac
}

shellxp_tool_marker() {
    case "$1" in
        zsh-autosuggestions)     echo "zsh-autosuggestions.zsh" ;;
        zsh-syntax-highlighting) echo "zsh-syntax-highlighting.zsh" ;;
        *) return 1 ;;
    esac
}

# Effective clone URL: SHELLXP_CLONE_URL_<TOOL_UPPER> override (local
# fixtures/mirrors; file:// or https:// only — fail closed otherwise), else
# the registry default.
shellxp_clone_url() {
    local tool="$1" url
    local env_key="SHELLXP_CLONE_URL_$(printf '%s' "$tool" | tr 'a-z-' 'A-Z_')"
    url="${!env_key:-}"
    if [[ -n "$url" ]]; then
        case "$url" in
            file://*|https://*) printf '%s\n' "$url"; return 0 ;;
            *)
                log_error "shellxp: clone URL override for '$tool' must be file:// or https://: $url"
                return 1
                ;;
        esac
    fi
    local spec
    spec=$(shellxp_registry_lookup "$tool") || return 1
    case "$spec" in
        clone:*) printf '%s\n' "${spec#clone:}" ;;
        *) log_error "shellxp: '$tool' is not a clone-based tool"; return 1 ;;
    esac
}

shellxp_plugins_root() {
    printf '%s\n' "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins"
}

_shellxp_zshrc_path() {
    printf '%s\n' "${SHELLXP_ZSHRC:-$HOME/.zshrc}"
}

# =============================================================================
# Presence detection and status
# =============================================================================

shellxp_tool_present() {
    local tool="$1" spec marker dir bin
    spec=$(shellxp_registry_lookup "$tool") || return 1
    case "$spec" in
        clone:*)
            marker=$(shellxp_tool_marker "$tool") || return 1
            dir="$(shellxp_plugins_root)/$tool"
            [[ -f "$dir/$marker" ]]
            ;;
        *)
            local bins
            bins=$(shellxp_tool_binaries "$tool") || return 1
            for bin in $bins; do # intentional word split over candidate names
                if command -v "$bin" >/dev/null 2>&1; then
                    return 0
                fi
            done
            return 1
            ;;
    esac
}

shellxp_status() {
    local tool spec state
    local tools
    tools=$(shellxp_list_tools)
    for tool in $tools; do # intentional word split over the fixed registry
        if shellxp_tool_present "$tool"; then
            state="present"
        else
            state="missing"
        fi
        spec=$(shellxp_registry_lookup "$tool") || continue
        if [[ "$spec" == clone:* ]]; then
            if shellxp_plugins_list 2>/dev/null | grep -qxF "$tool"; then
                state="$state (activated in plugins=())"
            else
                state="$state (not in plugins=())"
            fi
        fi
        printf '%s: %s\n' "$tool" "$state"
    done
    return 0
}

# =============================================================================
# Confirm gate (exact fix-terminal-issues /etc/shells pattern)
# =============================================================================
# Thin delegate (AX-6e): the canonical gate is lib/env.sh
# vms_confirm_privileged; the "shellxp" tag keeps the interactive-decline
# message ("shellxp: skipped <subject>") byte-identical.

_shellxp_confirm_system_change() {
    vms_confirm_privileged "$1" shellxp
}

# =============================================================================
# Install: plan -> --confirm -> transaction -> apply -> verify -> commit/rollback
# =============================================================================

_shellxp_print_install_plan() {
    local tool="$1" spec="$2" dry="$3"
    local method="${spec%%:*}" arg="${spec#*:}"
    local os tag
    os=$(get_os)
    tag="[plan]"
    if [[ "$dry" == "1" ]]; then
        tag="[dry-run]"
    fi
    printf '%s shellxp_install: %s\n' "$tag" "$tool"
    printf '  platform: %s\n' "$os"
    case "$method" in
        clone)
            printf '  method: git clone (never curl|bash)\n'
            printf '  url: %s\n' "$(shellxp_clone_url "$tool")"
            printf '  target: %s/%s\n' "$(shellxp_plugins_root)" "$tool"
            printf '  activation: NOT auto-added to plugins=(); run shellxp_plugins_add %s\n' "$tool"
            ;;
        brew)
            printf '  method: brew\n'
            printf '  package: %s\n' "$arg"
            ;;
        apt)
            printf '  method: apt (sudo, confirm-gated)\n'
            printf '  package: %s\n' "$arg"
            ;;
    esac
    return 0
}

shellxp_install() {
    local tool="" dry=0 confirm=0
    while (($#)); do
        case "$1" in
            --dry-run) dry=1 ;;
            --confirm) confirm=1 ;;
            -h|--help)
                printf 'usage: shellxp_install <tool> [--dry-run] [--confirm]\n'
                printf 'tools: %s\n' "$(shellxp_list_tools | tr '\n' ' ')"
                return 0
                ;;
            *)
                if [[ -z "$tool" ]]; then
                    tool="$1"
                else
                    log_error "shellxp_install: unexpected argument '$1'"
                    return 2
                fi
                ;;
        esac
        shift
    done
    if [[ -z "$tool" ]]; then
        log_error "usage: shellxp_install <tool> [--dry-run] [--confirm]"
        return 2
    fi

    local spec
    spec=$(shellxp_registry_lookup "$tool") || return 1

    _shellxp_print_install_plan "$tool" "$spec" "$dry"
    if [[ "$dry" == "1" ]]; then
        return 0
    fi
    if [[ "$confirm" != "1" ]]; then
        log_info "shellxp: plan-only (P0-6); re-run with --confirm (and VMS_CONFIRM=1 for apt) to apply"
        return 0
    fi

    # Fail-open: an already-present tool is never re-installed.
    if shellxp_tool_present "$tool"; then
        log_info "shellxp: '$tool' already present — nothing to do (fail-open)"
        return 0
    fi

    local owned=0
    if ! transaction_is_active; then
        transaction_start "shellxp_install_$tool" || return 1
        owned=1
    fi

    local method="${spec%%:*}" arg="${spec#*:}"
    local rc=0
    case "$method" in
        clone) _shellxp_apply_clone "$tool" || rc=1 ;;
        brew)  _shellxp_apply_brew "$tool" "$arg" || rc=1 ;;
        apt)   _shellxp_apply_apt "$tool" "$arg" || rc=1 ;;
        *)     log_error "shellxp: unsupported method '$method'"; rc=1 ;;
    esac

    # Transaction-level dry-run (TRANSACTION_DRY_RUN=1): the apply functions
    # planned only — skip verification, close the dry-run transaction.
    if [[ "$rc" == "0" && "${_TRANSACTION_ACTIVE:-}" == "dryrun" ]]; then
        if [[ "$owned" == "1" ]]; then transaction_commit; fi
        return 0
    fi

    if [[ "$rc" == "0" ]] && shellxp_tool_present "$tool"; then
        if [[ "$owned" == "1" ]]; then
            transaction_commit || return 1
        fi
        return 0
    fi
    if [[ "$rc" == "0" ]]; then
        log_error "shellxp: post-install verification FAILED: '$tool' still not present"
        rc=1
    fi
    if [[ "$owned" == "1" ]]; then
        transaction_rollback || true
    fi
    return 1
}

_shellxp_apply_brew() {
    local tool="$1" pkg="$2"
    if [[ "${_TRANSACTION_ACTIVE:-}" == "dryrun" ]]; then
        log_info "[dry-run] shellxp: would run: brew install $pkg"
        return 0
    fi
    if ! command -v brew >/dev/null 2>&1; then
        log_error "shellxp: brew not found — install Homebrew first (no curl|bash from this suite)"
        return 1
    fi
    brew install "$pkg"
}

_shellxp_apply_apt() {
    local tool="$1" pkg="$2"
    if [[ "${_TRANSACTION_ACTIVE:-}" == "dryrun" ]]; then
        log_info "[dry-run] shellxp: would run: sudo apt-get install -y $pkg (confirm-gated)"
        return 0
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        log_error "shellxp: apt-get not found — the apt method requires a Debian/Ubuntu host"
        return 1
    fi
    if ! _shellxp_confirm_system_change "$tool via apt"; then
        return 1
    fi
    sudo apt-get install -y "$pkg"
}

# git-clone install (zsh-autosuggestions / zsh-syntax-highlighting).
# Requires an ACTIVE TRANSACTION. Clones to a staging dir on the same
# filesystem, verifies the staged clone, registers the target as NEW with
# the transaction, then atomically renames it into place.
_shellxp_apply_clone() {
    local tool="$1"
    local url marker root target
    url=$(shellxp_clone_url "$tool") || return 1
    marker=$(shellxp_tool_marker "$tool") || return 1
    root=$(shellxp_plugins_root)
    target="$root/$tool"

    if [[ "${_TRANSACTION_ACTIVE:-}" == "dryrun" ]]; then
        log_info "[dry-run] shellxp: would git clone $url -> $target (no plugins=() edit)"
        return 0
    fi

    if [[ -e "$target" ]]; then
        if [[ -f "$target/$marker" && -d "$target/.git" ]]; then
            log_info "shellxp: clone already present, fail-open (no action): $target"
            _txn_journal "shellxp_clone_skip" "tool=$tool target=$target"
            return 0
        fi
        log_error "shellxp: refusing to clobber a non-managed directory: $target"
        return 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        log_error "shellxp: git not found — required for clone-based plugin installs"
        return 1
    fi

    local created_root=0
    if [[ ! -d "$root" ]]; then
        mkdir -p "$root" || { log_error "shellxp: cannot create $root"; return 1; }
        created_root=1
    fi

    local stage
    stage=$(mktemp -d "$root/.vms-clone.XXXXXX") || {
        log_error "shellxp: cannot stage clone in $root"
        return 1
    }

    if ! git clone "$url" "$stage/$tool"; then
        rm -rf "$stage"
        if [[ "$created_root" == "1" ]]; then rmdir "$root" 2>/dev/null || true; fi
        log_error "shellxp: git clone failed: $url"
        return 1
    fi

    if [[ ! -f "$stage/$tool/$marker" ]] || ! git -C "$stage/$tool" rev-parse HEAD >/dev/null 2>&1; then
        rm -rf "$stage"
        if [[ "$created_root" == "1" ]]; then rmdir "$root" 2>/dev/null || true; fi
        log_error "shellxp: staged clone verification failed (marker/HEAD): $tool"
        return 1
    fi
    local staged_head
    staged_head=$(git -C "$stage/$tool" rev-parse HEAD)

    # Register the target BEFORE mutation (new-file semantics: rollback removes it).
    if ! transaction_add_file "$target"; then
        rm -rf "$stage"
        log_error "shellxp: cannot register clone target with the transaction"
        return 1
    fi

    if ! mv "$stage/$tool" "$target"; then
        rm -rf "$stage"
        transaction_rollback || true
        log_error "shellxp: atomic rename failed: $target"
        return 1
    fi
    rmdir "$stage" 2>/dev/null || true

    if [[ ! -f "$target/$marker" ]] || [[ "$(git -C "$target" rev-parse HEAD 2>/dev/null)" != "$staged_head" ]]; then
        log_error "shellxp: post-clone verification FAILED: $target"
        transaction_rollback || true
        if [[ -d "$target" ]]; then
            # The file-level primitive cannot rm -rf directories; complete the
            # compensation explicitly and journal it (pre-state: target absent).
            rm -rf "$target"
            _txn_journal "shellxp_clone_compensate" "dir=$target"
        fi
        return 1
    fi

    _txn_journal "shellxp_clone" "tool=$tool url=$url target=$target head=${staged_head:0:12}"
    log_info "shellxp: cloned $tool -> $target (head ${staged_head:0:12}); NOT added to plugins=() — run shellxp_plugins_add $tool to activate"
    return 0
}

# =============================================================================
# Managed plugins=() array editor
# =============================================================================
# Edits the zsh `plugins=( ... )` assignment in .zshrc, in place, inside a
# managed block:
#
#   # BEGIN version-management-setup:plugins-array
#   plugins=(
#     git
#     zsh-syntax-highlighting   <- always LAST (upstream requirement)
#   )
#   # END version-management-setup:plugins-array
#
# Semantics:
#   - The editor targets the array zsh would actually bind (the LAST
#     assignment in the file). If it lies inside our managed block, the block
#     region is rewritten; a free-form array is adopted and wrapped in the
#     managed markers, preserving its position.
#   - User entries are preserved verbatim (order preserved on remove;
#     canonicalized with zsh-syntax-highlighting last on add). Entries that
#     fail the identifier grammar (quotes, expansions, punctuation) fail
#     closed — an array the editor cannot safely re-render is not edited.
#   - Writes are atomic (same-directory temp + rename), registered with the
#     transaction BEFORE mutation, byte-compare-skipped, mode-preserved,
#     and syntax-validated (zsh -n when zsh is available, else a structural
#     paren-balance check) BEFORE the swap.
#   - Dry-run aware: --dry-run or TRANSACTION_DRY_RUN=1 plans with zero
#     writes. When called inside an adopter's active transaction, the
#     existing transaction is reused and NOT committed (the adopter owns it).
# =============================================================================

_shellxp_strip_comment() {
    printf '%s' "$1" | sed 's/#.*$//'
}

# Parse .zshrc's effective plugins array.
# Sets: _SHELLXP_ARRAY_FOUND (0/1), _SHELLXP_REGION_START/_END (lines to
# replace; 0/0 = none), _SHELLXP_ENTRIES (newline-separated, may be empty).
# Returns: 0 parsed; 1 file missing; 2 malformed (unterminated array).
_shellxp_parse_plugins() {
    local file="$1"
    _SHELLXP_ARRAY_FOUND=0
    _SHELLXP_REGION_START=0
    _SHELLXP_REGION_END=0
    _SHELLXP_ENTRIES=""
    [[ -f "$file" ]] || return 1

    local begin_marker end_marker
    begin_marker=$(mutation_begin_marker "plugins-array")
    end_marker=$(mutation_end_marker "plugins-array")

    local -a lines=()
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        lines+=("$line")
    done < "$file"

    local n=${#lines[@]}
    local i opener_line=0 rest=""
    local opener_regex='^[[:space:]]*plugins=[[:space:]]*\((.*)$'
    for ((i = n; i >= 1; i--)); do
        if [[ "${lines[i - 1]}" =~ $opener_regex ]]; then
            opener_line=$i
            rest="${BASH_REMATCH[1]}"
            break
        fi
    done

    if [[ "$opener_line" == "0" ]]; then
        # No array anywhere: if a managed block exists (corrupt/empty), its
        # region is still the edit target so a re-add repairs in place.
        local bidx=0 eidx=0
        for ((i = 1; i <= n; i++)); do
            if [[ "${lines[i - 1]}" == "$begin_marker" ]]; then bidx=$i; fi
            if [[ "${lines[i - 1]}" == "$end_marker" ]]; then eidx=$i; fi
        done
        if [[ "$bidx" -gt 0 && "$eidx" -gt "$bidx" ]]; then
            _SHELLXP_ARRAY_FOUND=1
            _SHELLXP_REGION_START=$bidx
            _SHELLXP_REGION_END=$eidx
        fi
        return 0
    fi

    # Is the found array inside a managed block?
    local in_block=0 bidx=0 eidx=0
    for ((i = opener_line - 1; i >= 1; i--)); do
        if [[ "${lines[i - 1]}" == "$begin_marker" ]]; then bidx=$i; break; fi
        if [[ "${lines[i - 1]}" == "$end_marker" ]]; then break; fi
    done
    if [[ "$bidx" -gt 0 ]]; then
        for ((i = opener_line + 1; i <= n; i++)); do
            if [[ "${lines[i - 1]}" == "$end_marker" ]]; then eidx=$i; break; fi
        done
        if [[ "$eidx" -gt "$opener_line" ]]; then in_block=1; fi
    fi

    # Walk the array extent from the opener to the closing ')'.
    local chunk array_end=0 array_text=""
    chunk=$(_shellxp_strip_comment "$rest")
    if [[ "$chunk" =~ \)[[:space:]]*$ ]]; then
        array_end=$opener_line
        array_text="${chunk%)}"
    else
        array_text="$chunk"
        for ((i = opener_line + 1; i <= n; i++)); do
            chunk=$(_shellxp_strip_comment "${lines[i - 1]}")
            if [[ "$chunk" =~ \)[[:space:]]*$ ]]; then
                array_end=$i
                array_text+=$'\n'"${chunk%)}"
                break
            fi
            array_text+=$'\n'"$chunk"
        done
        if [[ "$array_end" == "0" ]]; then
            log_error "shellxp: unterminated plugins=( array in $file — refusing to edit"
            return 2
        fi
    fi

    # Tokenize: whitespace split, strip one layer of surrounding quotes.
    local -a entries=()
    local -a toks=()
    local tok
    while IFS= read -r chunk; do
        [[ -z "$chunk" ]] && continue
        toks=()
        read -r -a toks <<< "$chunk" || true
        if [[ ${#toks[@]} -gt 0 ]]; then
            for tok in "${toks[@]}"; do
                tok="${tok%\"}"; tok="${tok#\"}"
                tok="${tok%\'}"; tok="${tok#\'}"
                [[ -z "$tok" ]] && continue
                entries+=("$tok")
            done
        fi
    done <<< "$array_text"

    if [[ "$in_block" == "1" ]]; then
        _SHELLXP_REGION_START=$bidx
        _SHELLXP_REGION_END=$eidx
    else
        _SHELLXP_REGION_START=$opener_line
        _SHELLXP_REGION_END=$array_end
    fi
    _SHELLXP_ARRAY_FOUND=1
    if [[ ${#entries[@]} -gt 0 ]]; then
        local joined=""
        local e
        for e in "${entries[@]}"; do
            if [[ -z "$joined" ]]; then joined="$e"; else joined+=$'\n'"$e"; fi
        done
        _SHELLXP_ENTRIES="$joined"
    fi
    return 0
}

# Canonical entry order: user order preserved, de-duplicated, and
# zsh-syntax-highlighting forced LAST (upstream requirement). Prints the
# canonical list newline-separated.
_shellxp_canonical_entries() {
    local -a out=()
    local e o dup
    for e in "$@"; do
        [[ -z "$e" || "$e" == "${_SHELLXP_SYNTAX_HL}" ]] && continue
        dup=0
        if [[ ${#out[@]} -gt 0 ]]; then
            for o in "${out[@]}"; do
                if [[ "$o" == "$e" ]]; then dup=1; break; fi
            done
        fi
        if [[ "$dup" == "0" ]]; then out+=("$e"); fi
    done
    for e in "$@"; do
        if [[ "$e" == "${_SHELLXP_SYNTAX_HL}" ]]; then out+=("$e"); break; fi
    done
    if [[ ${#out[@]} -gt 0 ]]; then
        printf '%s\n' "${out[@]}"
    fi
    return 0
}

# Render the managed block for the given entries (grammar-validated,
# zsh-syntax-highlighting last) to stdout.
_shellxp_render_plugins_block() {
    local e
    for e in "$@"; do
        [[ -z "$e" ]] && continue
        if ! validate_identifier "$e" 64; then
            log_error "shellxp: refusing to render unsafe plugins entry: '$e'"
            return 1
        fi
    done
    mutation_begin_marker "plugins-array"
    if (($# == 0)); then
        printf 'plugins=()\n'
    else
        printf 'plugins=(\n'
        for e in "$@"; do
            [[ -z "$e" ]] && continue
            printf '  %s\n' "$e"
        done
        printf ')\n'
    fi
    mutation_end_marker "plugins-array"
    return 0
}

# Structural fallback validation (used when zsh is unavailable): the managed
# block must exist and its parentheses must balance.
_shellxp_structural_check() {
    local file="$1"
    local region
    region=$(mutation_block_get "$file" "plugins-array") || return 1
    [[ "$region" == *'plugins='* ]] || return 1
    local open close
    open=$(printf '%s' "$region" | grep -o '(' | wc -l | tr -d ' ')
    close=$(printf '%s' "$region" | grep -o ')' | wc -l | tr -d ' ')
    [[ "$open" == "$close" ]]
}

# Validate a zsh file. Prefers `zsh -n`; falls back to a structural check
# (with a loud warning) when zsh is not installed.
_shellxp_validate_zshrc() {
    local file="$1"
    if command -v zsh >/dev/null 2>&1; then
        zsh -n "$file"
        return $?
    fi
    log_warn "shellxp: zsh not found — using structural fallback validation for $file"
    if _shellxp_structural_check "$file"; then
        return 0
    fi
    log_error "shellxp: structural validation FAILED: $file"
    return 1
}

# Atomic swap of the full new .zshrc content (temp+rename), mirroring
# mutation_block_write's discipline. Requires an active transaction.
# Consumes $1 (the temp file): removes it on every path.
_shellxp_write_zshrc() {
    local new_file="$1"
    local file
    file=$(_shellxp_zshrc_path)

    [[ -n "$file" && -n "$new_file" && -f "$new_file" ]] || {
        log_error "shellxp: write called without composed content"
        rm -f "$new_file"
        return 1
    }
    [[ -n "${_TRANSACTION_ACTIVE:-}" ]] || {
        log_error "shellxp: plugins edit requires an active transaction (call transaction_start first)"
        rm -f "$new_file"
        return 1
    }
    validate_safe_path "$file" >/dev/null 2>&1 || {
        log_error "shellxp: .zshrc path failed lexical validation: $file"
        rm -f "$new_file"
        return 1
    }

    local dir write_target
    dir=$(dirname "$file")
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" || { rm -f "$new_file"; log_error "shellxp: cannot create $dir"; return 1; }
    fi

    write_target="$file"
    if [[ -L "$file" ]]; then
        mutation_resolve_content_target "$file" || { rm -f "$new_file"; return 1; }
        write_target="$_MUTATION_RESOLVED_TARGET"
        if [[ -e "$write_target" && ! -f "$write_target" ]]; then
            log_error "shellxp: .zshrc symlink resolves to a non-regular file, refusing: $write_target"
            rm -f "$new_file"
            return 1
        fi
        dir=$(dirname "$write_target")
    fi

    if [[ "${_TRANSACTION_ACTIVE:-}" != "dryrun" ]]; then
        transaction_add_file "$file" || { rm -f "$new_file"; return 1; }
        if [[ "$write_target" != "$file" ]]; then
            transaction_add_file "$write_target" || { rm -f "$new_file"; return 1; }
        fi
    fi

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        rm -f "$new_file"
        log_info "[dry-run] shellxp: would update the plugins array in: $file"
        _txn_journal "shellxp_plugins" "mode=dry_run file=$file"
        return 0
    fi

    # AX-21: canonical GNU-first mode probe (on Linux a BSD-first
    # `stat -f '%Lp'` prints file-system data: GNU -f means --file-system).
    if [[ -f "$file" ]]; then
        if ! _mutation_preserve_mode "$file" "$new_file"; then
            rm -f "$new_file"
            log_error "shellxp: cannot preserve the mode of $file — unchanged"
            return 1
        fi
    else
        chmod 644 "$new_file"
    fi

    if [[ -f "$file" ]] && mutation_files_identical "$new_file" "$file"; then
        rm -f "$new_file"
        log_debug "shellxp: .zshrc already identical, no change: $file"
        return 0
    fi

    if ! mv "$new_file" "$write_target"; then
        rm -f "$new_file"
        log_error "shellxp: atomic rename failed: $write_target"
        return 1
    fi

    _txn_journal "shellxp_plugins" "file=$file"
    log_info "shellxp: plugins array updated: $file"
    return 0
}

shellxp_plugins_list() {
    local file
    file=$(_shellxp_zshrc_path)
    if ! _shellxp_parse_plugins "$file"; then
        return 1
    fi
    if [[ "${_SHELLXP_ARRAY_FOUND:-0}" != "1" ]]; then
        return 1
    fi
    if [[ -n "${_SHELLXP_ENTRIES:-}" ]]; then
        printf '%s\n' "${_SHELLXP_ENTRIES}"
    fi
    return 0
}

_shellxp_plugins_edit() {
    local op="$1"
    shift
    local dry=0 name=""
    while (($#)); do
        case "$1" in
            --dry-run) dry=1 ;;
            -h|--help)
                printf 'usage: shellxp_plugins_%s <plugin-name> [--dry-run]\n' "$op"
                return 0
                ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                else
                    log_error "shellxp_plugins_$op: unexpected argument '$1'"
                    return 2
                fi
                ;;
        esac
        shift
    done
    if [[ -z "$name" ]]; then
        log_error "usage: shellxp_plugins_$op <plugin-name> [--dry-run]"
        return 2
    fi
    validate_identifier "$name" 64 || return 1

    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then dry=1; fi

    local file
    file=$(_shellxp_zshrc_path)

    local parse_rc=0
    _shellxp_parse_plugins "$file"
    parse_rc=$?
    if [[ "$parse_rc" == "2" ]]; then
        log_error "shellxp: .zshrc malformed — plugins edit refused: $file"
        return 1
    fi

    local -a entries=()
    local t
    if [[ -n "${_SHELLXP_ENTRIES:-}" ]]; then
        while IFS= read -r t; do
            [[ -n "$t" ]] && entries+=("$t")
        done <<< "${_SHELLXP_ENTRIES}"
    fi

    local -a new_entries=()
    case "$op" in
        add)
            local found=0
            if [[ ${#entries[@]} -gt 0 ]]; then
                for t in "${entries[@]}"; do
                    if [[ "$t" == "$name" ]]; then found=1; break; fi
                done
            fi
            if [[ "$found" == "1" ]]; then
                # Idempotent add — still enforce zsh-syntax-highlighting-last.
                if [[ ${#entries[@]} -gt 0 ]]; then
                    while IFS= read -r t; do
                        [[ -n "$t" ]] && new_entries+=("$t")
                    done < <(_shellxp_canonical_entries "${entries[@]}")
                fi
            elif [[ ${#entries[@]} -gt 0 ]]; then
                new_entries=("${entries[@]}" "$name")
                while IFS= read -r t; do
                    [[ -n "$t" ]] && new_entries+=("$t")
                done < <(_shellxp_canonical_entries "${new_entries[@]}")
            else
                new_entries=("$name")
            fi
            ;;
        remove)
            if [[ "$parse_rc" == "1" || "${_SHELLXP_ARRAY_FOUND:-0}" != "1" ]]; then
                # No plugins array (or no .zshrc): the entry is definitionally
                # absent — removal is a tolerant no-op, never a rewrite.
                log_debug "shellxp: no plugins array — plugins remove is idempotent: $name"
                return 0
            fi
            if [[ ${#entries[@]} -gt 0 ]]; then
                for t in "${entries[@]}"; do
                    if [[ "$t" != "$name" ]]; then new_entries+=("$t"); fi
                done
            fi
            ;;
        *)
            log_error "shellxp: internal error — unknown op '$op'"
            return 2
            ;;
    esac

    # Render up-front (grammar-validates every entry, fail-closed). Remove
    # preserves the user's remaining order; add canonicalizes with
    # zsh-syntax-highlighting last.
    local -a ordered=()
    if [[ "$op" == "remove" ]]; then
        if [[ ${#new_entries[@]} -gt 0 ]]; then
            ordered=("${new_entries[@]}")
        fi
    elif [[ ${#new_entries[@]} -gt 0 ]]; then
        while IFS= read -r t; do
            [[ -n "$t" ]] && ordered+=("$t")
        done < <(_shellxp_canonical_entries "${new_entries[@]}")
    fi

    local joined_new="" joined_old="${_SHELLXP_ENTRIES:-}"
    if [[ ${#ordered[@]} -gt 0 ]]; then
        for t in "${ordered[@]}"; do
            if [[ -z "$joined_new" ]]; then joined_new="$t"; else joined_new+=$'\n'"$t"; fi
        done
    fi
    if [[ "$joined_new" == "$joined_old" && "${_SHELLXP_ARRAY_FOUND:-0}" == "1" ]]; then
        log_info "shellxp: plugins array already up to date (idempotent no-op): $name"
        return 0
    fi

    # Plan output.
    local tag="[plan]"
    if [[ "$dry" == "1" ]]; then tag="[dry-run]"; fi
    printf '%s shellxp_plugins_%s: %s\n' "$tag" "$op" "$name"
    printf '  file: %s\n' "$file"
    printf '  entries before: %s\n' "$(printf '%s' "${joined_old:-<none>}" | tr '\n' ' ')"
    printf '  entries after:  %s\n' "$(printf '%s' "${joined_new:-<none>}" | tr '\n' ' ')"

    if [[ "$dry" == "1" ]]; then
        return 0
    fi

    # Compose the full new .zshrc into a temp file.
    local dir
    dir=$(dirname "$file")
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" || { log_error "shellxp: cannot create $dir"; return 1; }
    fi
    local composed block
    composed=$(mktemp "$dir/.vms-shellxp.XXXXXX") || { log_error "shellxp: mktemp failed in $dir"; return 1; }
    block=$(mktemp "$dir/.vms-shellxp.XXXXXX") || {
        rm -f "$composed"
        log_error "shellxp: mktemp failed in $dir"
        return 1
    }

    if [[ ${#ordered[@]} -gt 0 ]]; then
        _shellxp_render_plugins_block "${ordered[@]}" > "$block"
    else
        _shellxp_render_plugins_block > "$block"
    fi
    local render_rc=$?
    if [[ "$render_rc" != "0" ]]; then
        rm -f "$composed" "$block"
        return 1
    fi

    if [[ "${_SHELLXP_REGION_START:-0}" -gt 0 ]]; then
        local idx=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            idx=$((idx + 1))
            if [[ "$idx" -lt "${_SHELLXP_REGION_START}" ]]; then
                printf '%s\n' "$line" >> "$composed"
            elif [[ "$idx" == "${_SHELLXP_REGION_START}" ]]; then
                cat "$block" >> "$composed"
            elif [[ "$idx" -gt "${_SHELLXP_REGION_END}" ]]; then
                printf '%s\n' "$line" >> "$composed"
            fi
        done < "$file"
    elif [[ -f "$file" ]]; then
        cat "$file" >> "$composed"
        [[ -s "$composed" ]] && printf '\n' >> "$composed"
        cat "$block" >> "$composed"
    else
        cat "$block" >> "$composed"
    fi
    rm -f "$block"

    # Validate BEFORE the swap.
    if ! _shellxp_validate_zshrc "$composed"; then
        rm -f "$composed"
        log_error "shellxp: composed .zshrc failed validation — nothing written"
        return 1
    fi

    # Transaction: reuse an adopter's, or own one.
    local owned=0
    if ! transaction_is_active; then
        transaction_start "shellxp_plugins" || { rm -f "$composed"; return 1; }
        owned=1
    fi

    if ! _shellxp_write_zshrc "$composed"; then
        if [[ "$owned" == "1" ]]; then transaction_rollback || true; fi
        return 1
    fi

    # Post-write verification: the file must re-parse to the intended list.
    if [[ "${_TRANSACTION_ACTIVE:-}" != "dryrun" ]]; then
        _shellxp_parse_plugins "$file"
        if [[ "${_SHELLXP_ENTRIES:-}" != "$joined_new" ]]; then
            log_error "shellxp: post-write verification FAILED for $file"
            if [[ "$owned" == "1" ]]; then transaction_rollback || true; fi
            return 1
        fi
    fi

    if [[ "$owned" == "1" ]]; then
        transaction_commit || return 1
    fi
    return 0
}

shellxp_plugins_add() {
    _shellxp_plugins_edit add "$@"
}

shellxp_plugins_remove() {
    _shellxp_plugins_edit remove "$@"
}
