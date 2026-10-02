#!/usr/bin/env bash
# =============================================================================
# Syntax Gate (remediation directive M0 step 2, finding B1.4)
# =============================================================================
# Replaces the old `find ... -exec bash -n {} \; -print` gate, whose exit
# status came from `find` (always 0 regardless of parse failures), with a
# fail-closed loop. Adds `zsh -n` for shipped Zsh theme assets — three themes
# previously shipped with parse errors (config/apple-style-p10k.zsh,
# config/minimal-p10k.zsh, config/rainbow-p10k.zsh).
#
# Exit: 0 iff every checked file parses. A missing zsh binary fails closed.
# =============================================================================

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

errf="$(mktemp "${TMPDIR:-/tmp}/vms-syntax-err.XXXXXX")"
trap 'rm -f "$errf"' EXIT

failures=0
checked=0

check_with() {
    local interpreter="$1"
    local f="$2"
    if "$interpreter" -n "$f" 2>"$errf"; then
        :
    else
        echo "SYNTAX FAIL ($interpreter): $f"
        sed 's/^/    /' "$errf"
        failures=$((failures + 1))
    fi
    checked=$((checked + 1))
}

while IFS= read -r f; do check_with bash "$f"; done < <(
    find . -name '*.sh' -type f \
        -not -path './backups/*' \
        -not -path './.git/*' \
        -not -path './node_modules/*' \
        | sort
)

if command -v zsh >/dev/null 2>&1; then
    while IFS= read -r f; do check_with zsh "$f"; done < <(
        find config -name '*.zsh' -type f | sort
    )
else
    echo "SYNTAX GATE: zsh not found — cannot verify shipped Zsh assets (fail-closed)"
    failures=$((failures + 1))
fi

echo "syntax-check: ${checked} file(s) checked, ${failures} failure(s)"
[[ $failures -eq 0 ]]
