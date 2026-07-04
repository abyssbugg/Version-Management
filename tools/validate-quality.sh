#!/usr/bin/env bash
# Code Quality Validation Script

set -euo pipefail

readonly GREEN='\\033[0;32m'
readonly RED='\\033[0;31m'
readonly YELLOW='\\033[1;33m'
readonly NC='\\033[0m'

usage() {
        cat << EOF
Usage: $0 [--advisory] [-h|--help]

Options:
    --advisory   Report quality failures but exit 0
    -h, --help   Show this help message
EOF
}

validate_shellcheck() {
    echo "Running ShellCheck validation..."
    local issues=0
    local output=""

    if ! output=$(find . -name "*.sh" -type f -not -path "./backups/*" -exec shellcheck --format=gcc {} + 2>&1); then
        :
    fi

    if [[ -n "$output" ]]; then
        issues=$(printf '%s\n' "$output" | wc -l | tr -d '[:space:]')
    fi
    
    if [[ $issues -lt 50 ]]; then
        echo -e "${GREEN} ShellCheck: $issues issues (EXCELLENT)${NC}"
        return 0
    elif [[ $issues -lt 100 ]]; then
        echo -e "${YELLOW}  ShellCheck: $issues issues (GOOD)${NC}"
        return 0
    else
        echo -e "${RED} ShellCheck: $issues issues (NEEDS WORK)${NC}"
        return 1
    fi
}

validate_syntax() {
    echo "Validating syntax for all scripts..."
    local failed=0
    
    while IFS= read -r -d '' script; do
        if ! bash -n "$script" 2>/dev/null; then
            echo -e "${RED} Syntax error in: $script${NC}"
            failed=$((failed + 1))
        fi
    done < <(find . -name "*.sh" -type f -not -path "./backups/*" -print0)
    
    if [[ $failed -eq 0 ]]; then
        echo -e "${GREEN} All scripts pass syntax validation${NC}"
        return 0
    else
        echo -e "${RED} $failed scripts have syntax errors${NC}"
        return 1
    fi
}

main() {
    local advisory_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --advisory)
                advisory_mode=true
                shift
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *)
                echo -e "${RED}Unknown argument: $1${NC}" >&2
                usage >&2
                return 2
                ;;
        esac
    done

    echo "Code Quality Validation Report"
    echo "============================="
    if [[ "$advisory_mode" == "true" ]]; then
        echo -e "${YELLOW}ADVISORY MODE - failures do not gate${NC}"
    fi
    echo
    
    local score=0
    local syntax_status=0
    local shellcheck_status=0
    
    if validate_syntax; then
        score=$((score + 1))
    else
        syntax_status=1
    fi

    if validate_shellcheck; then
        score=$((score + 1))
    else
        shellcheck_status=1
    fi
    
    echo
    echo "Overall Score: $score/2"
    
    if [[ $score -eq 2 ]]; then
        echo -e "${GREEN} Excellent code quality!${NC}"
        return 0
    elif [[ "$advisory_mode" == "true" ]]; then
        echo -e "${YELLOW}👍 Good progress, minor issues remain${NC}"
        return 0
    else
        echo -e "${RED}FAIL: Mandatory quality checks failed${NC}"
        if [[ $syntax_status -ne 0 ]]; then
            echo -e "${RED} - Syntax validation failed${NC}"
        fi
        if [[ $shellcheck_status -ne 0 ]]; then
            echo -e "${RED} - ShellCheck validation failed${NC}"
        fi
        return 1
    fi
}

main "$@"
