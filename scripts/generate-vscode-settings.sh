#!/usr/bin/env bash
# Generate repo-local VS Code settings; P3-1/B1.9 transaction-backed publication.
set -euo pipefail

_VMS_VSCODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$_VMS_VSCODE_DIR/.." && pwd)"
# shellcheck source=lib/logger.sh
source "$repo_root/lib/logger.sh"
readonly TEMPLATE_FILE="$repo_root/config/vscode-settings.template.json"
readonly OUTPUT_FILE="$repo_root/vscode-settings.json"
readonly NVMRC_FILE="$repo_root/.nvmrc"

detect_node_version() {
    local version=""
    if [[ -f "$NVMRC_FILE" ]]; then
        version=$(tr -d '[:space:]' <"$NVMRC_FILE") || return 1
    fi
    # Detection must not source arbitrary NVM init code, especially in dry-run.
    if [[ -z "$version" ]] && command -v node >/dev/null 2>&1; then
        version=$(node --version 2>/dev/null) || version=""
        version="${version#v}"
    fi
    printf '%s\n' "${version:-20.19.2}"
}

detect_nvm_dir() {
    if [[ -n "${NVM_DIR:-}" ]]; then
        printf '%s\n' "$NVM_DIR"
    elif [[ -d "$HOME/.nvm" || ! -d /usr/local/nvm ]]; then
        printf '%s/.nvm\n' "$HOME"
    else
        printf '/usr/local/nvm\n'
    fi
}

# Fixed parser programs; all paths and values cross the boundary as argv/stdin,
# never interpolated source. Unknown template tokens fail before publication.
# Mode 'validate' checks JSON only; replacement values may contain literal {{ }}.
_vscode_json() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, re, sys
try:
    data = json.load(sys.stdin)
    if not isinstance(data, dict):
        raise ValueError("settings must be a JSON object")
    if sys.argv[1] == "render":
        values = dict(zip(("NVM_DIR", "NODE_VERSION", "HOME"), sys.argv[2:]))
        def token(match):
            name = match.group(1)
            if name not in values:
                raise ValueError("unknown placeholder: " + name)
            return values[name]
        def replace(value):
            if isinstance(value, str):
                return re.sub(r"\{\{([^{}]+)\}\}", token, value)
            if isinstance(value, list):
                return [replace(item) for item in value]
            if isinstance(value, dict):
                return {k: v if k.startswith("//") else replace(v) for k, v in value.items()}
            return value
        print(json.dumps(replace(data), indent=4, ensure_ascii=False))
except (ValueError, OSError) as exc:
    print("Invalid settings: " + str(exc), file=sys.stderr)
    sys.exit(1)
' "$@"
    elif command -v node >/dev/null 2>&1; then
        node -e '
const fs = require("fs");
try {
    const data = JSON.parse(fs.readFileSync(0, "utf8"));
    if (!data || Array.isArray(data) || typeof data !== "object") {
        throw new Error("settings must be a JSON object");
    }
    if (process.argv[1] === "render") {
        const values = new Map(["NVM_DIR", "NODE_VERSION", "HOME"].map((k, i) => [k, process.argv[i + 2]]));
        function replace(value) {
            if (typeof value === "string") {
                return value.replace(/\{\{([^{}]+)\}\}/g, (_, key) => {
                    if (!values.has(key)) throw new Error("unknown placeholder: " + key);
                    return values.get(key);
                });
            }
            if (Array.isArray(value)) return value.map(replace);
            if (value && typeof value === "object") {
                return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, k.startsWith("//") ? v : replace(v)]));
            }
            return value;
        }
        console.log(JSON.stringify(replace(data), null, 4));
    }
} catch (error) {
    console.error("Invalid settings: " + error.message);
    process.exit(1);
}
' "$@"
    else
        printf 'A JSON parser (python3 or node) is required.\n' >&2
        return 1
    fi
}

validate_template() {
    [[ -f "$TEMPLATE_FILE" ]] && _vscode_json validate <"$TEMPLATE_FILE"
}

validate_generated_settings() {
    [[ -f "$1" ]] && _vscode_json validate <"$1"
}

show_usage_instructions() {
    printf 'Generated file: %s\nCopy the desired settings into VS Code Settings (JSON).\n' "$1"
}

# Subshell confines traps, transaction state and preview logging policy to this
# invocation, including when callers source the script and call main directly.
main() (
    local dry_run="${TRANSACTION_DRY_RUN:-0}" arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=1 ;;
            --help | -h)
                printf 'Usage: %s [--dry-run] [--help]\n' "${BASH_SOURCE[0]}"
                return 0
                ;;
            *)
                printf 'Unknown argument: %s\n' "$arg" >&2
                return 2
                ;;
        esac
    done
    # A plan must not cause indirect log/backup/journal writes.
    if [[ "$dry_run" == 1 ]]; then unset LOG_FILE; fi
    local generated nvm_dir node_version target expected actual candidate=""
    nvm_dir=$(detect_nvm_dir) || return 1
    node_version=$(detect_node_version) || return 1
    [[ -f "$TEMPLATE_FILE" ]] || {
        log_error "Template missing: $TEMPLATE_FILE"
        return 1
    }
    generated=$(_vscode_json render "$nvm_dir" "$node_version" "$HOME" <"$TEMPLATE_FILE") || return 1
    # shellcheck source=lib/mutation.sh
    source "$repo_root/lib/mutation.sh"
    mutation_resolve_content_target "$OUTPUT_FILE" || return 1
    target="$_MUTATION_RESOLVED_TARGET"
    if [[ -L "$OUTPUT_FILE" && ! -f "$target" ]] || [[ -e "$target" && ! -f "$target" ]]; then
        log_error "Output must be a regular file or a symlink to one: $OUTPUT_FILE"
        return 1
    fi
    if [[ "$OUTPUT_FILE$target" == *$'\n'* || "$OUTPUT_FILE$target" == *$'\t'* ]]; then
        log_error 'Output paths cannot contain tabs or newlines'
        return 1
    fi
    if [[ "$dry_run" == 1 ]]; then
        printf '[dry-run] Would generate validated settings: %s\n' "$OUTPUT_FILE"
        return 0
    fi
    expected=$(printf '%s\n' "$generated" | _txn_sha256 /dev/stdin) || return 1
    if [[ -f "$target" ]]; then
        actual=$(_txn_sha256 "$target") || return 1
        if [[ "$actual" == "$expected" ]]; then
            log_info "Settings already current: $OUTPUT_FILE"
            return 0
        fi
    fi
    # Serialize cooperating generator runs; the no-change and preview paths
    # above deliberately avoid creating lock state.
    # shellcheck source=lib/lock.sh
    source "$repo_root/lib/lock.sh"
    local lock_held=0
    _vscode_cleanup() {
        local rc=$?
        trap - EXIT HUP INT TERM
        if [[ -n "$candidate" ]]; then rm -f -- "$candidate" || rc=1; fi
        if [[ -n "${_TRANSACTION_ACTIVE:-}" ]]; then
            _txn_journal mutation_write "target=$OUTPUT_FILE mode=apply result=failed exit_code=$rc"
            if ! transaction_rollback; then
                log_error 'Settings rollback failed; retain the reported backup for recovery'
                rc=1
            fi
        fi
        if [[ "$lock_held" == 1 ]]; then lock_release vscode-settings || rc=1; fi
        exit "$rc"
    }
    trap _vscode_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    lock_acquire vscode-settings || return 1
    lock_held=1
    mutation_resolve_content_target "$OUTPUT_FILE" || return 1
    [[ "$_MUTATION_RESOLVED_TARGET" == "$target" ]] || {
        log_error 'Settings output target changed while waiting for lock'
        return 1
    }
    candidate=$(mktemp "$(dirname "$target")/.vms-vscode.XXXXXX") || return 1
    if [[ -f "$target" ]]; then cp -p "$target" "$candidate" || return 1; fi
    printf '%s\n' "$generated" >"$candidate" || return 1
    validate_generated_settings "$candidate" || return 1
    transaction_start vscode_settings || return 1
    log_info "Backup ID: $_TRANSACTION_DIR"
    transaction_add_file "$OUTPUT_FILE" || return 1
    if [[ "$target" != "$OUTPUT_FILE" ]]; then transaction_add_file "$target" || return 1; fi
    mv -f -- "$candidate" "$target" || return 1
    candidate=""
    validate_generated_settings "$target" || return 1
    actual=$(_txn_sha256 "$target") || return 1
    [[ "$actual" == "$expected" ]] || {
        log_error 'Settings verification failed'
        return 1
    }
    _txn_journal mutation_write "target=$OUTPUT_FILE mode=apply result=verified exit_code=0"
    transaction_commit || return 1
    show_usage_instructions "$OUTPUT_FILE"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
