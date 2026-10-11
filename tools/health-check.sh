#!/usr/bin/env bash
# Quick Health Check for Development Environment
#
# RA-2 (re-audit 2026-10-10): every check runs as an argv command or a named
# function — never eval. The .nvmrc check used to build an eval'd string from
# the file's content, so running this inside a cloned repository executed code
# from that repository's .nvmrc. A failed check prints ✗ and never stops the
# report. Pinned by tests/unit/test_health_check.sh.

set -euo pipefail

echo "🏥 Development Environment Health Check"
echo "======================================="
echo

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# check <label> <command> [args...] — the label is printed as data (%s), so
# file-derived text cannot inject terminal escapes either.
check() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf '%b %s\n' "${GREEN}✓${NC}" "$label"
    else
        printf '%b %s\n' "${RED}✗${NC}" "$label"
    fi
    return 0
}

# check_version <name> <command> [args...]
check_version() {
    local name="$1" version=""
    shift
    if version=$("$@" 2>/dev/null) && [[ -n "$version" ]]; then
        printf '%b %s: %s\n' "${GREEN}✓${NC}" "$name" "$version"
    else
        printf '%b %s: not installed\n' "${RED}✗${NC}" "$name"
    fi
    return 0
}

_python_version() { python3 --version 2>/dev/null | awk '{print $2}'; }
_meslo_font_installed() { compgen -G "$HOME/Library/Fonts/MesloLGS*.ttf" >/dev/null; }

# System checks
echo " Version Managers:"
check_version "Node.js" node --version
check_version "Python" _python_version
check_version "npm" npm --version
check "nvm" test -d "$HOME/.nvm"
check "pyenv" command -v pyenv
echo

echo " Terminal Setup:"
check "PowerLevel10k" test -f "$HOME/.p10k.zsh"
check "Oh My Zsh" test -d "$HOME/.oh-my-zsh"
check "MesloLGS Font" _meslo_font_installed
echo

echo " Development Tools:"
check "Git" command -v git
check "Homebrew" command -v brew
check "VS Code CLI" command -v code
echo

echo " Project Files:"
expected_node_version="$(tr -d '[:space:]' < .nvmrc 2>/dev/null || true)"
if [[ -n "$expected_node_version" ]]; then
    installed_node_version="$(node --version 2>/dev/null | sed 's/^v//' || true)"
    _nvmrc_matches() { [[ "$installed_node_version" == "$expected_node_version" ]]; }
    check ".nvmrc (expects ${expected_node_version}, installed ${installed_node_version:-none})" _nvmrc_matches
else
    check ".nvmrc present" test -f .nvmrc
fi
check ".python-version (3.12.11)" grep -q '3.12.11' .python-version
check "VS Code settings" test -f vscode-settings.json
echo

# Performance metrics
if [[ -n "${ZSH_VERSION:-}" ]]; then
    echo " Shell Performance:"
    startup_time=$(zsh -i -c exit 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
    if [[ -n "$startup_time" ]]; then
        echo "  Startup time: ${startup_time}s"
    fi
    echo "  Shell: zsh $ZSH_VERSION"
fi
