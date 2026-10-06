#!/usr/bin/env bash
# P3-1: transaction-backed icon edits; configuration is parsed, never sourced.
set -euo pipefail
_VMS_ICONS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

show_usage() {
    printf 'Usage: %s [--dry-run] {--fix|--customize|--reset|--preview|--help}\n' "$0"
}

# Fixed program, with paths and user text passed only as data. ANSI-C quoted
# literals preserve quotes/backslashes without evaluating shell substitutions.
_icons_render() {
    python3 -c '
import pathlib, re, sys
mode, path, choice, icon = sys.argv[1:]
s = pathlib.Path(path).read_text()
if mode == "fix":
    for old, new in zip(["📁", "📂", "🔧", "⚙️", "🐍", "📦", "🟢", "🔴", "⚡"],
                        ["\uf07b", "\uf115", "\uf0ad", "\ue615", "\ue73c", "\uf487", "\uf00c", "\uf00d", "\uf0e7"]):
        s = s.replace(old, new)
else:
    keys = {"1": "POWERLEVEL9K_OS_ICON_CONTENT_EXPANSION", "2": "POWERLEVEL9K_FOLDER_ICON",
            "3": "POWERLEVEL9K_VCS_BRANCH_ICON", "4": r"POWERLEVEL9K_PROMPT_CHAR_OK_(?:[A-Z0-9_]+|\{[A-Z0-9_,]+\})_CONTENT_EXPANSION"}
    if choice == "3": icon += " "
    quote = chr(39)
    literal = "$" + quote + icon.replace("\\", "\\\\").replace(quote, "\\" + quote).replace("\r", "\\r").replace("\t", "\\t") + quote
    key = keys[choice]
    value = r"(?:\$" + quote + r"(?:\\.|[^" + quote + r"\\])*" + quote + "|" + quote + "[^" + quote + "]*" + quote + r"|\"(?:\\.|[^\"\\])*\"|[^\s;#]+)"
    assignment = re.compile(r"^(\s*(?:typeset\s+-g\s+)?" + key + r"=)" + value + r"([ \t]*(?:#.*)?)(\r?\n)?$")
    count = 0
    lines = []
    for line in s.splitlines(keepends=True):
        m = assignment.fullmatch(line)
        if m:
            line = m[1] + literal + m[2] + (m[3] or "")
            count += 1
        lines.append(line)
    if not count:
        sys.exit("No supported assignment found for selected icon; no changes made")
    s = "".join(lines)
sys.stdout.write(s)
' "$@"
}

main() (
    local mode='' dry_run="${TRANSACTION_DRY_RUN:-0}" arg choice='' icon=''
    # Read-only/error/idempotent paths must not write an inherited log file.
    unset LOG_FILE
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=1 ;;
            --fix | --customize | --reset | --preview)
                [[ -z "$mode" ]] || {
                    printf 'Conflicting operation modes\n' >&2
                    return 2
                }
                mode="${arg#--}"
                ;;
            --help | -h)
                show_usage
                return 0
                ;;
            *)
                printf 'Unknown argument: %s\n' "$arg" >&2
                return 2
                ;;
        esac
    done
    [[ -n "$mode" ]] || {
        show_usage
        return 1
    }
    if [[ "$mode" == preview ]]; then
        cat <<'PREVIEW'
Professional Development Theme Preview:
======================================

     ~/projects/my-app   main  20.19.2  3.12.8  ⌚ 10:30:25  ✓

This theme features:
  • Enhanced version management indicators (Go 1.23.4, Rust 1.82.0, Java 21.0.2)
  • Customizable OS, directory, and status icons

Apple Style Theme Preview:
==========================

   ~/projects/my-app  main 20.19.2 3.12.8 ⌚ 10:30:25 ✘

Minimal Theme Preview:
======================

  ~/projects/my-app main N:20.19.2 P:3.12.8 10:30:25
PREVIEW
        return 0
    fi
    local file="$HOME/.p10k.zsh" target generated expected actual candidate='' template
    [[ -f "$file" ]] || {
        printf 'No regular .p10k.zsh configuration found\n' >&2
        return 1
    }
    source "$_VMS_ICONS_ROOT/lib/mutation.sh"
    mutation_resolve_content_target "$file" || return 1
    target="$_MUTATION_RESOLVED_TARGET"
    [[ "$file$target" != *$'\n'* && "$file$target" != *$'\t'* ]] || return 1
    if [[ "$mode" == customize ]]; then
        printf 'Customizable icon segments:\n  1) OS icon\n  2) Directory icon\n  3) Git branch icon\n  4) Prompt character (OK state)\n  5) Cancel\n'
        read -r -p 'Select segment to customize (1-5): ' choice || return 0
        case "$choice" in
            5) return 0 ;;
            1 | 2 | 3 | 4)
                read -r -p 'Enter new icon: ' icon || return 0
                [[ -n "$icon" ]] || return 0
                ;;
            *)
                printf 'Invalid choice\n' >&2
                return 2
                ;;
        esac
    fi
    command -v zsh >/dev/null 2>&1 || {
        printf 'zsh is required to validate configuration\n' >&2
        return 1
    }
    if [[ "$mode" == reset ]]; then
        template=professional-dev
        if grep -qE 'Apple.*Monterey|^# Apple-Style Powerlevel10k' "$file"; then
            template=apple-style
        elif grep -q 'Minimal.*Theme' "$file"; then
            template=minimal
        elif grep -q Rainbow "$file"; then template=rainbow; fi
        generated=$(cat "$_VMS_ICONS_ROOT/config/$template-p10k.zsh" && printf '\001') || return 1
    else
        command -v python3 >/dev/null 2>&1 || {
            printf 'python3 is required to render icons safely\n' >&2
            return 1
        }
        generated=$(_icons_render "$mode" "$file" "$choice" "$icon" && printf '\001') || return 1
    fi
    generated="${generated%$'\001'}"
    printf '%s' "$generated" | zsh -fn || return 1
    expected=$(printf '%s' "$generated" | _txn_sha256 /dev/stdin) || return 1
    actual=$(_txn_sha256 "$target") || return 1
    if [[ "$dry_run" == 1 ]]; then
        printf '[dry-run] Would %s icons: %s\n' "$mode" "$file"
        return 0
    fi
    [[ "$expected" != "$actual" ]] || {
        printf 'Icons already current\n'
        return 0
    }
    source "$_VMS_ICONS_ROOT/lib/lock.sh"
    local lock_held=0
    _icons_cleanup() {
        local rc=$?
        trap - EXIT HUP INT TERM
        [[ -z "$candidate" ]] || rm -f -- "$candidate" || rc=1
        if [[ -n "${_TRANSACTION_ACTIVE:-}" ]]; then
            _txn_journal mutation_write "target=$file mode=apply result=failed exit_code=$rc"
            transaction_rollback || rc=1
        fi
        if [[ "$lock_held" == 1 ]]; then lock_release workstation-mutation || rc=1; fi
        exit "$rc"
    }
    trap _icons_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    lock_acquire workstation-mutation || return 1
    lock_held=1
    mutation_resolve_content_target "$file" || return 1
    [[ "$_MUTATION_RESOLVED_TARGET" == "$target" && "$(_txn_sha256 "$target")" == "$actual" ]] || {
        printf 'Configuration changed while preparing edit; retry\n' >&2
        return 1
    }
    candidate=$(mktemp "$(dirname "$target")/.vms-icons.XXXXXX") || return 1
    cp -p "$target" "$candidate" || return 1
    printf '%s' "$generated" >"$candidate" || return 1
    zsh -fn "$candidate" || return 1
    transaction_start theme_icons || return 1
    log_info "Backup ID: $_TRANSACTION_DIR"
    transaction_add_file "$file" || return 1
    if [[ "$file" != "$target" ]]; then transaction_add_file "$target" || return 1; fi
    mv -f -- "$candidate" "$target" || return 1
    candidate=''
    [[ "$(_txn_sha256 "$target")" == "$expected" ]] || return 1
    zsh -fn "$target" || return 1
    _txn_journal mutation_write "target=$file mode=apply result=verified exit_code=0"
    transaction_commit || return 1
    printf 'Icons updated. Restart your terminal to apply.\n'
)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
