#!/usr/bin/env bash
# check-no-secrets.sh — Pre-commit hook that fails when hardcoded secrets are found
# Exit 1 (fail) if matches found; exit 0 (pass) if clean.

set -euo pipefail

PATTERN='(password|secret|api_key|token)[[:space:]]*=[[:space:]]*["'"'"'][^"'"'"']+["'"'"']'

found=0
for file in "$@"; do
    if grep -nE "$PATTERN" "$file"; then
        echo "FAIL: hardcoded secret pattern found in $file" >&2
        found=1
    fi
done

if [[ $found -eq 1 ]]; then
    exit 1
fi

exit 0
