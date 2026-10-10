#!/usr/bin/env bash
# check-no-secrets.sh — Pre-commit hook that fails when hardcoded secrets are found
# Exit 1 (fail) if matches found; exit 0 (pass) if clean.
#
# P1-5: matches a QUOTED LITERAL of 4+ characters assigned (`=` or `:`) to a
# secret-like name, case-insensitively and with any prefix/suffix:
#   password=, API_KEY=, export GITHUB_TOKEN=, db_password:, ClientSecret =,
#   AWS_ACCESS_KEY_ID=, PRIVATE_KEY= ...
# A value that starts with `$` (an expansion such as "$1" or "${X:-}") or is
# empty is not a literal and passes. gitleaks in CI remains the
# authoritative scanner; this is the fast local net. Pinned by
# tests/unit/test_secret_hook.sh.

set -euo pipefail

Q="[\"']"
NAME='[A-Za-z0-9_]*(password|passwd|secret|api_?key|token|access_?key|private_?key)s?(_[A-Za-z0-9_]*)?'
PATTERN="(^|[^A-Za-z0-9_])${NAME}[[:space:]]*[:=][[:space:]]*${Q}[^\"'\$[:space:]][^\"'\$]{3,}${Q}"

found=0
for file in "$@"; do
    if grep -inE "$PATTERN" "$file"; then
        echo "FAIL: hardcoded secret pattern found in $file" >&2
        found=1
    fi
done

if [[ $found -eq 1 ]]; then
    exit 1
fi

exit 0
