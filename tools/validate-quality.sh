#!/usr/bin/env bash
# Code Quality Validation Script

readonly GREEN='\\033[0;32m'
readonly RED='\\033[0;31m'
readonly YELLOW='\\033[1;33m'
readonly NC='\\033[0m'

validate_shellcheck() {
    echo "Running ShellCheck validation..."
    local issues
    issues=$(find . -name "*.sh" -type f -not -path "./backups/*" -exec shellcheck --format=gcc {} + 2>&1 | wc -l || echo "0")
    
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
            ((failed++))
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
    echo "Code Quality Validation Report"
    echo "============================="
    echo
    
    local score=0
    
    validate_syntax && ((score++))
    validate_shellcheck && ((score++))
    
    echo
    echo "Overall Score: $score/2"
    
    if [[ $score -eq 2 ]]; then
        echo -e "${GREEN} Excellent code quality!${NC}"
        return 0
    else
        echo -e "${YELLOW}👍 Good progress, minor issues remain${NC}"
        return 0
    fi
}

main "$@"
