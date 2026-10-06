#!/usr/bin/env bash
# P3-1: fonts and repo-local terminal artifacts form one verified transaction.
set -euo pipefail
_VMS_SLICK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_slick_json() {
    cat <<'JSON'
{
  "terminal.integrated.fontFamily": "MesloLGS NF",
  "terminal.integrated.fontSize": 14,
  "terminal.integrated.lineHeight": 1.2,
  "terminal.integrated.letterSpacing": 0,
  "terminal.integrated.fontWeight": "normal",
  "terminal.integrated.fontWeightBold": "bold",
  "terminal.integrated.allowChords": false,
  "terminal.integrated.cursorBlinking": true,
  "terminal.integrated.cursorStyle": "line",
  "terminal.integrated.drawBoldTextInBrightColors": false,
  "terminal.integrated.minimumContrastRatio": 4.5,
  "terminal.integrated.tabStopWidth": 4,
  "workbench.colorTheme": "Default Dark Modern",
  "editor.fontFamily": "MesloLGS NF, 'Courier New', monospace",
  "editor.fontSize": 14,
  "editor.fontLigatures": true,
  "debug.console.fontFamily": "MesloLGS NF"
}
JSON
}
_slick_demo() {
    cat <<'DEMO'
#!/usr/bin/env bash
# Test Nerd Font Icons Display
set -euo pipefail
cat <<'ICONS'
 Testing Nerd Font Icons Display...
==================================

 Directory Icons:
   Home: 
   Folder: 
   File: 

🔀 Git Icons:
   Branch: 
   Modified: 
   Added: 
   Deleted: 
   Renamed: 
   Untracked: 

⚙️  System Icons:
   Terminal: 
   Clock: 
   CPU: 
   Memory: 

 Language Icons:
   Node.js: 
   Python: 
   JavaScript: 
   TypeScript: 
   React: 
   Vue: 

 Status Icons:
   Success: 
   Error: 
   Warning: 
   Info: 

 Tool Icons:
   Settings: 
   Package: 
   Download: 
   Upload: 

If you see proper icons above (not squares/question marks),
your Nerd Font is working correctly!
ICONS
DEMO
}
_slick_validate_json() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json, sys; json.load(sys.stdin)'
    elif command -v node >/dev/null 2>&1; then
        node -e 'JSON.parse(require("fs").readFileSync(0, "utf8"))'
    else
        printf 'python3 or node is required to validate settings\n' >&2
        return 1
    fi
}

main() (
    local dry_run="${TRANSACTION_DRY_RUN:-0}" arg
    unset LOG_FILE
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=1 ;;
            --help | -h)
                printf 'Usage: %s [--dry-run] [--help]\n' "$0"
                return 0
                ;;
            *)
                printf 'Unknown argument: %s\n' "$arg" >&2
                return 2
                ;;
        esac
    done
    local json demo font_dir="$HOME/Library/Fonts"
    json=$(_slick_json) || return 1
    demo=$(_slick_demo) || return 1
    printf '%s\n' "$json" | _slick_validate_json || return 1
    printf '%s\n' "$demo" | bash -n || return 1
    source "$_VMS_SLICK_ROOT/lib/mutation.sh"
    local -a files=() sources=() kinds=() targets=() hashes=() before=() changed=() candidates=() created_dirs=()
    local font file target hash old i j parent lock_held=0 cache_attempted=0 committed=0 fonts_changed=0
    for font in "$_VMS_SLICK_ROOT"/*.ttf; do
        [[ -f "$font" ]] || continue
        files+=("$font_dir/$(basename "$font")")
        sources+=("$font")
        kinds+=(font)
    done
    files+=("$_VMS_SLICK_ROOT/vscode-terminal-fonts.json" "$_VMS_SLICK_ROOT/test-nerd-font-icons.sh")
    sources+=('' '')
    kinds+=(json demo)
    _slick_resolve() {
        local path="$1" ancestor
        if [[ -e "$path" && ! -f "$path" ]] || [[ -L "$path" && ! -f "$path" ]]; then
            printf 'Refusing nonregular or dangling target: %s\n' "$path" >&2
            return 1
        fi
        if [[ -d "$(dirname "$path")" ]]; then
            mutation_resolve_content_target "$path" || return 1
            target="$_MUTATION_RESOLVED_TARGET"
        else
            ancestor=$(dirname "$path")
            while [[ ! -e "$ancestor" && ! -L "$ancestor" ]]; do ancestor=$(dirname "$ancestor"); done
            [[ -d "$ancestor" ]] || return 1
            target="$path"
        fi
        [[ "$path$target" != *$'\n'* && "$path$target" != *$'\t'* ]] || return 1
    }
    for ((i = 0; i < ${#files[@]}; i++)); do
        file="${files[i]}"
        _slick_resolve "$file" || return 1
        # Two logical outputs must never overwrite the same resolved file.
        for ((j = 0; j < i; j++)); do
            [[ "$target" != "${targets[j]}" ]] || {
                printf 'Output targets alias each other\n' >&2
                return 1
            }
        done
        targets+=("$target")
        case "${kinds[i]}" in
            font) hash=$(_txn_sha256 "${sources[i]}") || return 1 ;;
            json) hash=$(printf '%s\n' "$json" | _txn_sha256 /dev/stdin) || return 1 ;;
            demo) hash=$(printf '%s\n' "$demo" | _txn_sha256 /dev/stdin) || return 1 ;;
        esac
        hashes+=("$hash")
        old=absent
        if [[ -f "$target" ]]; then old=$(_txn_sha256 "$target") || return 1; fi
        before+=("$old")
        if [[ "$hash" != "$old" ]] || [[ "${kinds[i]}" == demo && ! -x "$target" ]]; then
            changed+=("$i")
            if [[ "${kinds[i]}" == font ]]; then fonts_changed=1; fi
        fi
    done
    if [[ "$dry_run" == 1 ]]; then
        printf '[dry-run] Would prepare terminal files:\n'
        printf '  %s\n' "${files[@]}"
        return 0
    fi
    [[ ${#changed[@]} -gt 0 ]] || {
        printf 'Terminal setup already current\n'
        return 0
    }
    source "$_VMS_SLICK_ROOT/lib/lock.sh"
    _slick_cleanup() {
        local rc=$? item
        trap - EXIT HUP INT TERM
        for item in "${candidates[@]}"; do [[ -z "$item" ]] || rm -f -- "$item" || rc=1; done
        if [[ -n "${_TRANSACTION_ACTIVE:-}" ]]; then
            _txn_journal mutation_write "mode=apply result=failed exit_code=$rc"
            transaction_rollback || rc=1
            if [[ "$cache_attempted" == 1 ]]; then
                fc-cache -f "$font_dir" >/dev/null 2>&1 || {
                    printf 'Font files restored; cache refresh failed\n' >&2
                    rc=1
                }
            fi
        fi
        if [[ "$committed" == 0 ]]; then
            for ((j = ${#created_dirs[@]} - 1; j >= 0; j--)); do rmdir -- "${created_dirs[j]}" 2>/dev/null || rc=1; done
        fi
        if [[ "$lock_held" == 1 ]]; then lock_release workstation-mutation || rc=1; fi
        exit "$rc"
    }
    trap _slick_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    lock_acquire workstation-mutation || return 1
    lock_held=1
    _slick_mkdir() {
        local dir="$1"
        [[ -d "$dir" ]] && return 0
        [[ ! -e "$dir" && ! -L "$dir" ]] || return 1
        _slick_mkdir "$(dirname "$dir")" || return 1
        mkdir -- "$dir" || return 1
        created_dirs+=("$dir")
    }
    # Recheck the entire plan after the lock, not just the last output.
    for ((i = 0; i < ${#files[@]}; i++)); do
        _slick_resolve "${files[i]}" || return 1
        old=absent
        if [[ -f "$target" ]]; then old=$(_txn_sha256 "$target") || return 1; fi
        [[ "$target" == "${targets[i]}" && "$old" == "${before[i]}" ]] || {
            printf 'Target changed while preparing setup; retry\n' >&2
            return 1
        }
    done
    # Stage/validate all candidates before registering or publishing any output.
    for i in "${changed[@]}"; do
        target="${targets[i]}"
        parent=$(dirname "$target")
        _slick_mkdir "$parent" || return 1
        candidates[i]=$(mktemp "$parent/.vms-slick.XXXXXX") || return 1
        local file_mode=644 mode_source="$target"
        if [[ ! -f "$target" && "${kinds[i]}" == font ]]; then mode_source="${sources[i]}"; fi
        if [[ -f "$mode_source" ]]; then
            file_mode=$(stat -c '%a' "$mode_source" 2>/dev/null || stat -f '%Lp' "$mode_source" 2>/dev/null) || return 1
        fi
        case "${kinds[i]}" in
            font)
                cat "${sources[i]}" >"${candidates[i]}" || return 1
                ;;
            json)
                printf '%s\n' "$json" >"${candidates[i]}" || return 1
                _slick_validate_json <"${candidates[i]}" || return 1
                ;;
            demo)
                printf '%s\n' "$demo" >"${candidates[i]}" || return 1
                bash -n "${candidates[i]}" || return 1
                if [[ ! -f "$target" ]]; then file_mode=755; fi
                ;;
        esac
        chmod "$file_mode" "${candidates[i]}" || return 1
        if [[ "${kinds[i]}" == demo ]]; then chmod u+x "${candidates[i]}" || return 1; fi
        [[ "$(_txn_sha256 "${candidates[i]}")" == "${hashes[i]}" ]] || return 1
    done
    transaction_start slick_terminal || return 1
    log_info "Backup ID: $_TRANSACTION_DIR"
    for i in "${changed[@]}"; do
        transaction_add_file "${files[i]}" || return 1
        if [[ "${files[i]}" != "${targets[i]}" ]]; then transaction_add_file "${targets[i]}" || return 1; fi
    done
    for i in "${changed[@]}"; do
        mv -f -- "${candidates[i]}" "${targets[i]}" || return 1
        candidates[i]=''
        [[ "$(_txn_sha256 "${targets[i]}")" == "${hashes[i]}" ]] || return 1
        _txn_journal mutation_write "target=${files[i]} mode=apply result=verified exit_code=0"
    done
    if [[ "$fonts_changed" == 1 ]] && command -v fc-cache >/dev/null 2>&1; then
        cache_attempted=1
        fc-cache -f "$font_dir" >/dev/null 2>&1 || return 1
    fi
    transaction_commit || return 1
    committed=1
    printf 'Slick terminal setup completed!\nCopy vscode-terminal-fonts.json into VS Code settings, restart VS Code,\nand run ./test-nerd-font-icons.sh to verify the glyph display.\n'
)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
