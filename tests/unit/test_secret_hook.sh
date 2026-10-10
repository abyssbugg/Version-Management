#!/usr/bin/env bash
# =============================================================================
# P1-5: the local pre-commit secret hook (scripts/check-no-secrets.sh)
# =============================================================================
# The hook used to match only lowercase, unprefixed, `=`-assigned names
# (`password="..."`), so the most common real leak shapes passed:
# `API_KEY="..."`, `export GITHUB_TOKEN='...'`, `db_password: "..."`.
# Contract pinned here:
#   - hardcoded literals assigned to secret-like names are rejected in any
#     case, with prefixes/suffixes, via `=` or `:` (exit 1, file named);
#   - expansions (`"$VAR"`, `"${X:-}"`) and empty values pass (exit 0);
#   - the shipped tree itself is clean under the hook.
# gitleaks in CI stays the authoritative scanner; this is the fast local net.
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SBX="$(mktemp -d "${TMPDIR:-/tmp}/vms-secret-hook.XXXXXX")"
trap 'rm -rf -- "$SBX"' EXIT
HOOK="$ROOT/scripts/check-no-secrets.sh"
failures=0

expect() {  # <expected rc> <label> <line...>
    local want="$1" label="$2" f="$SBX/case.sh" rc
    shift 2
    printf '%s\n' '#!/usr/bin/env bash' "$@" > "$f"
    bash "$HOOK" "$f" >/dev/null 2>&1
    rc=$?
    if [[ "$rc" == "$want" ]]; then
        printf 'PASS: %s\n' "$label"
    else
        printf 'FAIL: %s (rc=%s, want %s)\n' "$label" "$rc" "$want"
        failures=$((failures + 1))
    fi
}

# Rejected: literal secrets.
expect 1 "lowercase password literal"        'password="hunter2"'
expect 1 "uppercase prefixed API key"        'API_KEY="sk-live-0123456789abcdef"'
expect 1 "exported GitHub token"             "export GITHUB_TOKEN='ghp_0123456789abcdefghij'"
expect 1 "yaml-style colon assignment"       'db_password: "s3cr3t-value-123"'
expect 1 "mixed-case client secret"          'ClientSecret = "abcdefgh12345678"'
expect 1 "aws access key"                    'AWS_ACCESS_KEY_ID="AKIAABCDEFGHIJKLMNOP"'
expect 1 "private key variable"              'PRIVATE_KEY="0123456789abcdef0123"'

# Accepted: no literal value.
expect 0 "expansion of another variable"     'API_KEY="$OTHER_KEY"'
expect 0 "parameter default expansion"       'GITHUB_TOKEN="${GITHUB_TOKEN:-}"'
expect 0 "positional argument"               'token="$1"'
expect 0 "empty value"                       'SECRET=""'
expect 0 "unrelated assignment"              'tokenizer="whitespace"'

# The shipped shell code is clean under the hook (pre-commit parity).
mapfile -t shipped < <(cd "$ROOT" && git ls-files '*.sh' | grep -vE '^FontPatcher/')
if (cd "$ROOT" && bash "$HOOK" "${shipped[@]}" >/dev/null 2>&1); then
    printf 'PASS: shipped shell code is clean under the hook (%s files)\n' "${#shipped[@]}"
else
    printf 'FAIL: shipped shell code trips the hook:\n'
    (cd "$ROOT" && bash "$HOOK" "${shipped[@]}" 2>&1 | head -10 | sed 's/^/    /')
    failures=$((failures + 1))
fi

printf 'Secret hook (P1-5): %s failure(s)\n' "$failures"
[[ "$failures" -eq 0 ]]
