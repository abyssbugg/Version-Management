#!/usr/bin/env bash
# Consolidated System Diagnostics Script
# Provides comprehensive system and development environment diagnostics

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/logger.sh"

# Colors for output
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Output format (terminal or json)
OUTPUT_FORMAT="${OUTPUT_FORMAT:-terminal}"

# Diagnostic history directory
DIAG_HISTORY_DIR="${HOME}/.cache/version-manager/diagnostics"

# Counters for scoring
declare -g TOTAL_CHECKS=0
declare -g PASSED_CHECKS=0
declare -g WARNINGS=0
declare -g ERRORS=0

# JSON accumulator
declare -g JSON_RESULTS=""

show_usage() {
    echo "Usage: $0 [OPTION]"
    echo "Comprehensive system diagnostics"
    echo
    echo "Options:"
    echo "  --quick      Quick system check (shell, basic tools)"
    echo "  --full       Full diagnostic scan (all checks)"
    echo "  --versions   Check all version managers"
    echo "  --python     Python-specific diagnostics"
    echo "  --setup      Validate complete setup"
    echo "  --dashboard  Show health dashboard with scores"
    echo "  --json       Output results in JSON format"
    echo "  --history    Show diagnostic history"
    echo "  --help       Show this help message"
}

# Helper function to check if a command exists
check_command() {
    local cmd="$1"
    local name="${2:-$cmd}"
    ((TOTAL_CHECKS++))
    
    if command -v "$cmd" >/dev/null 2>&1; then
        local version
        version=$("$cmd" --version 2>/dev/null | head -n1 || echo "installed")
        ((PASSED_CHECKS++))
        
        if [[ "$OUTPUT_FORMAT" == "json" ]]; then
            JSON_RESULTS+="{\"check\":\"$name\",\"status\":\"pass\",\"value\":\"$version\"},"
        else
            echo -e "${GREEN}✓${NC} $name: $version"
        fi
        return 0
    else
        ((ERRORS++))
        if [[ "$OUTPUT_FORMAT" == "json" ]]; then
            JSON_RESULTS+="{\"check\":\"$name\",\"status\":\"fail\",\"value\":\"not found\"},"
        else
            echo -e "${RED}✗${NC} $name: not found"
        fi
        return 1
    fi
}

# Check with warning level
check_optional() {
    local cmd="$1"
    local name="${2:-$cmd}"
    ((TOTAL_CHECKS++))
    
    if command -v "$cmd" >/dev/null 2>&1; then
        local version
        version=$("$cmd" --version 2>/dev/null | head -n1 || echo "installed")
        ((PASSED_CHECKS++))
        
        if [[ "$OUTPUT_FORMAT" == "json" ]]; then
            JSON_RESULTS+="{\"check\":\"$name\",\"status\":\"pass\",\"value\":\"$version\"},"
        else
            echo -e "${GREEN}✓${NC} $name: $version"
        fi
        return 0
    else
        ((WARNINGS++))
        if [[ "$OUTPUT_FORMAT" == "json" ]]; then
            JSON_RESULTS+="{\"check\":\"$name\",\"status\":\"warn\",\"value\":\"not installed\"},"
        else
            echo -e "${YELLOW}!${NC} $name: not installed (optional)"
        fi
        return 1
    fi
}

# Record a check result
record_check() {
    local name="$1"
    local status="$2"  # pass, warn, fail
    local value="${3:-}"
    local suggestion="${4:-}"
    
    ((TOTAL_CHECKS++))
    
    case "$status" in
        pass) ((PASSED_CHECKS++)) ;;
        warn) ((WARNINGS++)) ;;
        fail) ((ERRORS++)) ;;
    esac
    
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        JSON_RESULTS+="{\"check\":\"$name\",\"status\":\"$status\",\"value\":\"$value\""
        [[ -n "$suggestion" ]] && JSON_RESULTS+=",\"suggestion\":\"$suggestion\""
        JSON_RESULTS+="},"
    fi
}

# Calculate health score
calculate_score() {
    if [[ $TOTAL_CHECKS -eq 0 ]]; then
        echo 0
        return
    fi
    echo $(( (PASSED_CHECKS * 100) / TOTAL_CHECKS ))
}

# Get score color
get_score_color() {
    local score=$1
    if (( score >= 80 )); then
        echo "$GREEN"
    elif (( score >= 60 )); then
        echo "$YELLOW"
    else
        echo "$RED"
    fi
}

# Initialize history directory
init_history() {
    mkdir -p "$DIAG_HISTORY_DIR"
}

# Save diagnostic to history
save_to_history() {
    init_history
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local score
    score=$(calculate_score)
    
    cat > "$DIAG_HISTORY_DIR/diag_${timestamp}.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "score": $score,
    "total_checks": $TOTAL_CHECKS,
    "passed": $PASSED_CHECKS,
    "warnings": $WARNINGS,
    "errors": $ERRORS
}
EOF
}

# Show diagnostic history
show_history() {
    init_history
    echo -e "${BOLD}=== Diagnostic History ===${NC}"
    echo
    
    local count=0
    for file in $(ls -t "$DIAG_HISTORY_DIR"/diag_*.json 2>/dev/null | head -10); do
        if [[ -f "$file" ]]; then
            local timestamp score
            timestamp=$(grep -o '"timestamp"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" | cut -d'"' -f4)
            score=$(grep -o '"score"[[:space:]]*:[[:space:]]*[0-9]*' "$file" | grep -o '[0-9]*$')
            local color
            color=$(get_score_color "${score:-0}")
            echo -e "  ${timestamp}: Score ${color}${score:-0}%${NC}"
            ((count++))
        fi
    done
    
    if [[ $count -eq 0 ]]; then
        echo "  No diagnostic history found"
        echo "  Run --full or --quick to create history"
    fi
    echo
}

quick_check() {
    log_info " Running quick system check..."
    echo
    
    echo "=== Shell Environment ==="
    echo "  Current shell: ${SHELL:-unknown}"
    echo "  Shell version: $(${SHELL:-/bin/bash} --version | head -n1)"
    echo "  Terminal: ${TERM:-unknown}"
    echo
    
    echo "=== Core Tools ==="
    check_command "git" "Git" || true
    check_command "curl" "curl" || true
    check_command "node" "Node.js" || true
    check_command "npm" "npm" || true
    check_command "python3" "Python3" || true
    echo
    
    echo "=== Shell Configuration ==="
    [[ -f "$HOME/.zshrc" ]] && echo -e "${GREEN}✓${NC} ~/.zshrc exists" || echo -e "${YELLOW}!${NC} ~/.zshrc not found"
    [[ -f "$HOME/.bashrc" ]] && echo -e "${GREEN}✓${NC} ~/.bashrc exists" || echo -e "${YELLOW}!${NC} ~/.bashrc not found"
    [[ -f "$HOME/.p10k.zsh" ]] && echo -e "${GREEN}✓${NC} ~/.p10k.zsh exists" || echo -e "${YELLOW}!${NC} ~/.p10k.zsh not found"
    echo
    
    log_success "Quick check completed"
}

full_diagnostic() {
    log_info " Running full diagnostic scan..."
    echo
    
    # Run all checks
    quick_check
    check_versions
    python_diagnostics
    validate_setup
    
    echo "=== System Info ==="
    echo "  OS: $(uname -s) $(uname -r)"
    echo "  Arch: $(uname -m)"
    echo "  User: $(whoami)"
    echo "  Home: $HOME"
    echo
    
    echo "=== Disk Space ==="
    df -h "$HOME" 2>/dev/null | tail -1 || echo "  Unable to check disk space"
    echo
    
    log_success "Full diagnostic completed"
}

check_versions() {
    log_info " Checking version managers..."
    echo
    
    echo "=== Node.js (nvm) ==="
    if [[ -d "${NVM_DIR:-$HOME/.nvm}" ]]; then
        echo -e "${GREEN}✓${NC} NVM directory exists: ${NVM_DIR:-$HOME/.nvm}"
        if [[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]; then
            echo -e "${GREEN}✓${NC} nvm.sh found"
            # Check if nvm is loaded
            if command -v nvm >/dev/null 2>&1; then
                echo "  NVM version: $(nvm --version 2>/dev/null || echo 'unknown')"
                echo "  Current Node: $(nvm current 2>/dev/null || echo 'none')"
            else
                echo -e "${YELLOW}!${NC} nvm not loaded in current shell"
            fi
        fi
    else
        echo -e "${RED}✗${NC} NVM not installed"
    fi
    echo
    
    echo "=== Python (pyenv) ==="
    if command -v pyenv >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} pyenv installed"
        echo "  Version: $(pyenv --version 2>/dev/null || echo 'unknown')"
        echo "  Current Python: $(pyenv version-name 2>/dev/null || echo 'system')"
    elif [[ -d "$HOME/.pyenv" ]]; then
        echo -e "${YELLOW}!${NC} pyenv directory exists but not in PATH"
    else
        echo -e "${RED}✗${NC} pyenv not installed"
    fi
    echo
    
    echo "=== Go (goenv) ==="
    if command -v goenv >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} goenv installed"
        echo "  Current Go: $(goenv version 2>/dev/null | cut -d' ' -f1 || echo 'none')"
    elif command -v go >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Go installed (system): $(go version 2>/dev/null | cut -d' ' -f3 || echo 'unknown')"
    else
        echo -e "${YELLOW}!${NC} Go/goenv not installed"
    fi
    echo
    
    echo "=== Rust (rustup) ==="
    if command -v rustup >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} rustup installed"
        echo "  Toolchain: $(rustup show active-toolchain 2>/dev/null | head -1 || echo 'default')"
        check_command "rustc" "Rust compiler" || true
        check_command "cargo" "Cargo" || true
    else
        echo -e "${YELLOW}!${NC} rustup not installed"
    fi
    echo
    
    echo "=== Java (jenv) ==="
    if command -v jenv >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} jenv installed"
        echo "  Current Java: $(jenv version 2>/dev/null | cut -d' ' -f1 || echo 'none')"
    elif command -v java >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Java installed (system)"
        java -version 2>&1 | head -1
    else
        echo -e "${YELLOW}!${NC} Java/jenv not installed"
    fi
    echo
    
    log_success "Version check completed"
}

python_diagnostics() {
    log_info "🐍 Running Python diagnostics..."
    echo
    
    echo "=== Python Installation ==="
    check_command "python3" "Python 3" || true
    check_command "pip3" "pip3" || true
    check_command "pipenv" "pipenv" || true
    check_command "poetry" "poetry" || true
    echo
    
    echo "=== Python Paths ==="
    if command -v python3 >/dev/null 2>&1; then
        echo "  Executable: $(which python3)"
        echo "  Site packages: $(python3 -c 'import site; print(site.getsitepackages()[0])' 2>/dev/null || echo 'unknown')"
    fi
    echo
    
    echo "=== pyenv Status ==="
    if command -v pyenv >/dev/null 2>&1; then
        echo "  PYENV_ROOT: ${PYENV_ROOT:-$HOME/.pyenv}"
        echo "  Installed versions:"
        pyenv versions 2>/dev/null | head -5 || echo "    (none)"
    fi
    echo
    
    echo "=== Virtual Environment ==="
    if [[ -n "${VIRTUAL_ENV:-}" ]]; then
        echo -e "${GREEN}✓${NC} Active venv: $VIRTUAL_ENV"
    else
        echo "  No virtual environment active"
    fi
    echo
    
    log_success "Python diagnostics completed"
}

validate_setup() {
    log_info " Validating complete setup..."
    echo
    
    local issues=0
    
    echo "=== Project Files Check ==="
    [[ -f ".nvmrc" ]] && echo -e "${GREEN}✓${NC} .nvmrc present" || { echo -e "${YELLOW}!${NC} .nvmrc missing"; ((issues++)) || true; }
    [[ -f ".python-version" ]] && echo -e "${GREEN}✓${NC} .python-version present" || { echo -e "${YELLOW}!${NC} .python-version missing"; ((issues++)) || true; }
    [[ -f "package.json" ]] && echo -e "${GREEN}✓${NC} package.json present" || echo -e "${BLUE}i${NC} package.json not present (optional)"
    echo
    
    echo "=== Theme Configuration ==="
    if [[ -f "$HOME/.p10k.zsh" ]]; then
        echo -e "${GREEN}✓${NC} PowerLevel10k config found"
    else
        echo -e "${YELLOW}!${NC} PowerLevel10k not configured"
        ((issues++)) || true
    fi
    echo
    
    echo "=== Font Check ==="
    if command -v fc-list >/dev/null 2>&1; then
        if fc-list | grep -qi "meslo"; then
            echo -e "${GREEN}✓${NC} MesloLGS Nerd Font detected"
        else
            echo -e "${YELLOW}!${NC} MesloLGS Nerd Font not found in system"
            ((issues++)) || true
        fi
    else
        echo -e "${BLUE}i${NC} fc-list not available, cannot check fonts"
    fi
    echo
    
    echo "=== Summary ==="
    if [[ $issues -eq 0 ]]; then
        echo -e "${GREEN}All checks passed!${NC}"
    else
        echo -e "${YELLOW}Found $issues potential issue(s)${NC}"
    fi
    echo
    
    log_success "Setup validation completed"
}

# Health Dashboard
health_dashboard() {
    log_info "🏥 System Health Dashboard"
    echo
    
    # Reset counters
    TOTAL_CHECKS=0
    PASSED_CHECKS=0
    WARNINGS=0
    ERRORS=0
    
    # Collect all checks silently
    local old_format="$OUTPUT_FORMAT"
    OUTPUT_FORMAT="silent"
    
    # Shell environment
    [[ -n "${SHELL:-}" ]] && ((PASSED_CHECKS++)) || ((ERRORS++)); ((TOTAL_CHECKS++))
    [[ -f "$HOME/.zshrc" ]] && ((PASSED_CHECKS++)) || ((WARNINGS++)); ((TOTAL_CHECKS++))
    [[ -f "$HOME/.p10k.zsh" ]] && ((PASSED_CHECKS++)) || ((WARNINGS++)); ((TOTAL_CHECKS++))
    
    # Core tools
    command -v git >/dev/null 2>&1 && ((PASSED_CHECKS++)) || ((ERRORS++)); ((TOTAL_CHECKS++))
    command -v curl >/dev/null 2>&1 && ((PASSED_CHECKS++)) || ((ERRORS++)); ((TOTAL_CHECKS++))
    
    # Version managers
    [[ -d "${NVM_DIR:-$HOME/.nvm}" ]] && ((PASSED_CHECKS++)) || ((WARNINGS++)); ((TOTAL_CHECKS++))
    command -v pyenv >/dev/null 2>&1 && ((PASSED_CHECKS++)) || ((WARNINGS++)); ((TOTAL_CHECKS++))
    command -v node >/dev/null 2>&1 && ((PASSED_CHECKS++)) || ((WARNINGS++)); ((TOTAL_CHECKS++))
    command -v python3 >/dev/null 2>&1 && ((PASSED_CHECKS++)) || ((WARNINGS++)); ((TOTAL_CHECKS++))
    
    # Optional tools
    command -v go >/dev/null 2>&1 && ((PASSED_CHECKS++)) || ((WARNINGS++)); ((TOTAL_CHECKS++))
    command -v rustc >/dev/null 2>&1 && ((PASSED_CHECKS++)) || ((WARNINGS++)); ((TOTAL_CHECKS++))
    command -v java >/dev/null 2>&1 && ((PASSED_CHECKS++)) || ((WARNINGS++)); ((TOTAL_CHECKS++))
    
    OUTPUT_FORMAT="$old_format"
    
    local score
    score=$(calculate_score)
    local color
    color=$(get_score_color "$score")
    
    # Display dashboard
    echo -e "${BOLD}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║              SYSTEM HEALTH DASHBOARD                   ║${NC}"
    echo -e "${BOLD}╠════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC}                                                        ${BOLD}║${NC}"
    
    # Score bar
    local bar_filled=$((score / 5))
    local bar_empty=$((20 - bar_filled))
    local bar=""
    for ((i=0; i<bar_filled; i++)); do bar+="█"; done
    for ((i=0; i<bar_empty; i++)); do bar+="░"; done
    
    echo -e "${BOLD}║${NC}  Health Score: ${color}${bar}${NC} ${color}${score}%${NC}        ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}                                                        ${BOLD}║${NC}"
    echo -e "${BOLD}╠════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC}  ${GREEN}✓ Passed:${NC}  $PASSED_CHECKS                                        ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  ${YELLOW}! Warnings:${NC} $WARNINGS                                        ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  ${RED}✗ Errors:${NC}   $ERRORS                                        ${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  Total Checks: $TOTAL_CHECKS                                    ${BOLD}║${NC}"
    echo -e "${BOLD}╠════════════════════════════════════════════════════════╣${NC}"
    
    # Status message
    if (( score >= 80 )); then
        echo -e "${BOLD}║${NC}  ${GREEN}Status: Excellent - System is well configured${NC}         ${BOLD}║${NC}"
    elif (( score >= 60 )); then
        echo -e "${BOLD}║${NC}  ${YELLOW}Status: Good - Minor improvements recommended${NC}         ${BOLD}║${NC}"
    else
        echo -e "${BOLD}║${NC}  ${RED}Status: Needs Attention - Run --full for details${NC}     ${BOLD}║${NC}"
    fi
    
    echo -e "${BOLD}╚════════════════════════════════════════════════════════╝${NC}"
    echo
    
    # Show fix suggestions if there are issues
    if (( ERRORS > 0 || WARNINGS > 3 )); then
        show_fix_suggestions
    fi
    
    # Save to history
    save_to_history
}

# Show fix suggestions
show_fix_suggestions() {
    echo -e "${BOLD}=== Recommended Fixes ===${NC}"
    echo
    
    # Check for common issues and suggest fixes
    if ! command -v git >/dev/null 2>&1; then
        echo -e "${CYAN}→${NC} Install Git:"
        echo "    brew install git  # macOS"
        echo "    sudo apt install git  # Ubuntu/Debian"
        echo
    fi
    
    if [[ ! -d "${NVM_DIR:-$HOME/.nvm}" ]]; then
        echo -e "${CYAN}→${NC} Install NVM:"
        echo "    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash"
        echo
    fi
    
    if ! command -v pyenv >/dev/null 2>&1; then
        echo -e "${CYAN}→${NC} Install pyenv:"
        echo "    brew install pyenv  # macOS"
        echo "    curl https://pyenv.run | bash  # Linux"
        echo
    fi
    
    if [[ ! -f "$HOME/.p10k.zsh" ]]; then
        echo -e "${CYAN}→${NC} Configure PowerLevel10k:"
        echo "    ./setup-theme.sh professional"
        echo
    fi
    
    if ! command -v node >/dev/null 2>&1; then
        echo -e "${CYAN}→${NC} Install Node.js:"
        echo "    nvm install --lts"
        echo
    fi
}

# Output results as JSON
output_json() {
    # Reset and run checks
    TOTAL_CHECKS=0
    PASSED_CHECKS=0
    WARNINGS=0
    ERRORS=0
    JSON_RESULTS=""
    OUTPUT_FORMAT="json"
    
    # Run all checks
    quick_check >/dev/null 2>&1 || true
    check_versions >/dev/null 2>&1 || true
    
    # Remove trailing comma from results
    JSON_RESULTS="${JSON_RESULTS%,}"
    
    local score
    score=$(calculate_score)
    
    cat << EOF
{
    "timestamp": "$(date -Iseconds)",
    "score": $score,
    "summary": {
        "total_checks": $TOTAL_CHECKS,
        "passed": $PASSED_CHECKS,
        "warnings": $WARNINGS,
        "errors": $ERRORS
    },
    "checks": [$JSON_RESULTS]
}
EOF
    
    save_to_history
}

# Main execution
case "${1:-}" in
    --quick)     quick_check; save_to_history ;;
    --full)      full_diagnostic; save_to_history ;;
    --versions)  check_versions ;;
    --python)    python_diagnostics ;;
    --setup)     validate_setup ;;
    --dashboard) health_dashboard ;;
    --json)      output_json ;;
    --history)   show_history ;;
    --help)      show_usage ;;
    *)           show_usage; exit 1 ;;
esac
