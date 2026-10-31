#!/usr/bin/env bash
# Dependency Health Check

set -euo pipefail

# F-A6: canonical logging/colors from lib/logger.sh. This tool previously
# carried its own duplicate palette — whose '\\033' single-quoted literals
# never rendered as color at all.
_TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_TOOL_DIR}/../lib/logger.sh"

log_success() { printf '%b\n' "${GREEN}[✓]${NC} $*"; }
log_error() { printf '%b\n' "${RED}[✗]${NC} $*"; }

main() {
    echo "Dependency Health Check"
    echo "======================"

    local issues=0

    if command -v node >/dev/null 2>&1; then
        log_success "Node.js: $(node --version)"
    else
        log_error "Node.js: not found"
        issues=$(( issues + 1 ))
    fi

    if command -v npm >/dev/null 2>&1; then
        log_success "npm: v$(npm --version)"
    else
        log_error "npm: not found"
        issues=$(( issues + 1 ))
    fi

    if command -v python3 >/dev/null 2>&1; then
        log_success "Python: $(python3 --version | cut -d' ' -f2)"
    else
        log_error "Python: not found"
        issues=$(( issues + 1 ))
    fi

    echo
    if [[ $issues -eq 0 ]]; then
        log_success "All core dependencies are available"
    else
        log_error "$issues dependencies are missing"
    fi
}

main "$@"
