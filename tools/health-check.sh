#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2086,SC2155,SC2005,SC2207,SC2016

# Quick Health Check for Development Environment

echo "🏥 Development Environment Health Check"
echo "======================================="
echo

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check functions
check() {
    if eval "$2" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $1"
        return 0
    else
        echo -e "${RED}✗${NC} $1"
        return 1
    fi
}

check_version() {
    local name=$1
    local cmd=$2
    local version=$(eval "$cmd" 2>/dev/null || echo "not installed")
    if [[ "$version" != "not installed" ]]; then
        echo -e "${GREEN}✓${NC} $name: $version"
    else
        echo -e "${RED}✗${NC} $name: not installed"
    fi
}

# System checks
echo " Version Managers:"
check_version "Node.js" "node --version"
check_version "Python" "python3 --version | awk '{print \$2}'"
check_version "npm" "npm --version"
check "nvm" "[ -d ~/.nvm ]"
check "pyenv" "command -v pyenv"
echo

echo " Terminal Setup:"
check "PowerLevel10k" "[ -f ~/.p10k.zsh ]"
check "Oh My Zsh" "[ -d ~/.oh-my-zsh ]"
check "MesloLGS Font" "ls ~/Library/Fonts/MesloLGS*.ttf 2>/dev/null | grep -q ttf"
echo

echo " Development Tools:"
check "Git" "command -v git"
check "Homebrew" "command -v brew"
check "VS Code CLI" "command -v code"
echo

echo " Project Files:"
expected_node_version="$(tr -d '[:space:]' < .nvmrc 2>/dev/null || true)"
if [[ -n "$expected_node_version" ]]; then
    installed_node_version="$(node --version 2>/dev/null | sed 's/^v//' || true)"
    check ".nvmrc (expects ${expected_node_version}, installed ${installed_node_version:-none})" "[[ '${installed_node_version}' == '${expected_node_version}' ]]"
else
    check ".nvmrc present" "[ -f .nvmrc ]"
fi
check ".python-version (3.12.11)" "grep -q '3.12.11' .python-version 2>/dev/null"
check "VS Code settings" "[ -f vscode-settings.json ]"
echo

# Performance metrics
if [[ -n "${ZSH_VERSION:-}" ]]; then
    echo " Shell Performance:"
    startup_time=$(zsh -i -c exit 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$startup_time" ]]; then
        echo "  Startup time: ${startup_time}s"
    fi
    echo "  Shell: zsh $ZSH_VERSION"
fi
