#!/usr/bin/env bash
# Dependency Health Check

set -euo pipefail

readonly GREEN='\\033[0;32m'
readonly RED='\\033[0;31m'
readonly NC='\\033[0m'

log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }

main() {
    echo "Dependency Health Check"
    echo "======================"
    
    local issues=0
    
    if command -v node >/dev/null 2>&1; then
        log_success "Node.js: $(node --version)"
    else
        log_error "Node.js: not found"
        ((issues++))
    fi
    
    if command -v npm >/dev/null 2>&1; then
        log_success "npm: v$(npm --version)"
    else
        log_error "npm: not found" 
        ((issues++))
    fi
    
    if command -v python3 >/dev/null 2>&1; then
        log_success "Python: $(python3 --version | cut -d' ' -f2)"
    else
        log_error "Python: not found"
        ((issues++))
    fi
    
    echo
    if [[ $issues -eq 0 ]]; then
        log_success "All core dependencies are available"
    else
        log_error "$issues dependencies are missing"
    fi
}

main "$@"
