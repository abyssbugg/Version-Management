#!/usr/bin/env bash
# shellcheck disable=SC1091
# ============================================================================
# Analytics Report Generator
# Part of Professional Development Terminal Setup
# ============================================================================
# Generates comprehensive analytics reports from collected metrics.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source dependencies
source "$SCRIPT_DIR/lib/logger.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/metrics.sh"

# ============================================================================
# Configuration
# ============================================================================

REPORT_FORMAT="${REPORT_FORMAT:-text}"
REPORT_PERIOD="${REPORT_PERIOD:-30}"  # days

# Colors
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly CYAN='\033[0;36m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# ============================================================================
# Report Generation
# ============================================================================

# Generate text report
generate_text_report() {
    echo
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║         📈 Analytics Report - Version Manager Suite              ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo
    echo "Generated: $(date)"
    echo "Period: Last $REPORT_PERIOD days"
    echo

    # Overview section
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  OVERVIEW"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    local total_sessions total_commands version_switches theme_changes errors
    total_sessions=$(metrics_get_stat "total_sessions" || echo "0")
    total_commands=$(metrics_get_stat "total_commands" || echo "0")
    version_switches=$(metrics_get_stat "version_switches" || echo "0")
    theme_changes=$(metrics_get_stat "theme_changes" || echo "0")
    errors=$(metrics_get_stat "errors_encountered" || echo "0")

    printf "  %-25s %10s\n" "Total Sessions:" "${total_sessions:-0}"
    printf "  %-25s %10s\n" "Total Commands:" "${total_commands:-0}"
    printf "  %-25s %10s\n" "Version Switches:" "${version_switches:-0}"
    printf "  %-25s %10s\n" "Theme Changes:" "${theme_changes:-0}"
    printf "  %-25s %10s\n" "Errors:" "${errors:-0}"
    echo

    # Calculate health score
    local health_score=100
    if [[ ${errors:-0} -gt 0 && ${total_commands:-0} -gt 0 ]]; then
        local error_rate=$((errors * 100 / total_commands))
        health_score=$((100 - error_rate))
        [[ $health_score -lt 0 ]] && health_score=0
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  HEALTH SCORE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    # Visual health bar
    local bar_width=40
    local filled=$((health_score * bar_width / 100))
    local empty=$((bar_width - filled))

    printf "  ["
    if [[ $health_score -ge 80 ]]; then
        printf "${GREEN}"
    elif [[ $health_score -ge 50 ]]; then
        printf "${YELLOW}"
    else
        printf "${RED}"
    fi
    printf "%${filled}s" | tr ' ' '█'
    printf "${NC}"
    printf "%${empty}s" | tr ' ' '░'
    printf "] %d%%\n" "$health_score"
    echo

    if [[ $health_score -ge 90 ]]; then
        echo "  Status: ${GREEN}Excellent${NC} - System running smoothly"
    elif [[ $health_score -ge 70 ]]; then
        echo "  Status: ${GREEN}Good${NC} - Minor issues detected"
    elif [[ $health_score -ge 50 ]]; then
        echo "  Status: ${YELLOW}Fair${NC} - Some issues need attention"
    else
        echo "  Status: ${RED}Poor${NC} - Multiple issues detected"
    fi
    echo

    # Usage patterns
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  USAGE PATTERNS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    if [[ ${total_sessions:-0} -gt 0 ]]; then
        local avg_commands=$((${total_commands:-0} / ${total_sessions:-1}))
        printf "  %-25s %10s\n" "Avg commands/session:" "$avg_commands"

        local avg_switches=$((${version_switches:-0} * 100 / ${total_sessions:-1}))
        printf "  %-25s %10s%%\n" "Sessions with switches:" "$avg_switches"
    else
        echo "  No usage data available yet."
    fi
    echo

    # Recent activity
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  RECENT ACTIVITY (Last 10 events)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    if [[ -f "$METRICS_EVENTS" ]]; then
        tail -10 "$METRICS_EVENTS" 2>/dev/null | while IFS=, read -r timestamp session category action label value; do
            printf "  %-20s %-15s %s\n" "${timestamp:0:19}" "$category" "$action"
        done
    else
        echo "  No events recorded yet."
    fi
    echo

    # Recommendations
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  RECOMMENDATIONS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    local recommendations=0

    if [[ ${errors:-0} -gt 5 ]]; then
        echo "  • Run diagnostics to investigate errors: ./tools/system-diagnostics.sh"
        recommendations=$(( recommendations + 1 ))
    fi

    if [[ ${version_switches:-0} -eq 0 && ${total_sessions:-0} -gt 3 ]]; then
        echo "  • Consider using .nvmrc/.python-version files for automatic switching"
        recommendations=$(( recommendations + 1 ))
    fi

    if [[ ${total_sessions:-0} -lt 5 ]]; then
        echo "  • Continue using the tools to build up usage data"
        recommendations=$(( recommendations + 1 ))
    fi

    if [[ $recommendations -eq 0 ]]; then
        echo "  ✓ No specific recommendations at this time."
    fi
    echo

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Report complete. Run 'metrics_dashboard' for interactive view."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
}

# Generate JSON report
generate_json_report() {
    local total_sessions total_commands version_switches theme_changes errors
    total_sessions=$(metrics_get_stat "total_sessions" || echo "0")
    total_commands=$(metrics_get_stat "total_commands" || echo "0")
    version_switches=$(metrics_get_stat "version_switches" || echo "0")
    theme_changes=$(metrics_get_stat "theme_changes" || echo "0")
    errors=$(metrics_get_stat "errors_encountered" || echo "0")

    local health_score=100
    if [[ ${errors:-0} -gt 0 && ${total_commands:-0} -gt 0 ]]; then
        local error_rate=$((errors * 100 / total_commands))
        health_score=$((100 - error_rate))
        [[ $health_score -lt 0 ]] && health_score=0
    fi

    cat << EOF
{
    "report_date": "$(date -Iseconds)",
    "period_days": $REPORT_PERIOD,
    "overview": {
        "total_sessions": ${total_sessions:-0},
        "total_commands": ${total_commands:-0},
        "version_switches": ${version_switches:-0},
        "theme_changes": ${theme_changes:-0},
        "errors": ${errors:-0}
    },
    "health": {
        "score": $health_score,
        "status": "$(
            if [[ $health_score -ge 90 ]]; then echo "excellent"
            elif [[ $health_score -ge 70 ]]; then echo "good"
            elif [[ $health_score -ge 50 ]]; then echo "fair"
            else echo "poor"
            fi
        )"
    },
    "storage": {
        "metrics_dir": "$METRICS_DIR",
        "retention_days": $METRICS_RETENTION_DAYS
    }
}
EOF
}

# Generate markdown report
generate_markdown_report() {
    local total_sessions total_commands version_switches theme_changes errors
    total_sessions=$(metrics_get_stat "total_sessions" || echo "0")
    total_commands=$(metrics_get_stat "total_commands" || echo "0")
    version_switches=$(metrics_get_stat "version_switches" || echo "0")
    theme_changes=$(metrics_get_stat "theme_changes" || echo "0")
    errors=$(metrics_get_stat "errors_encountered" || echo "0")

    cat << EOF
# Analytics Report

**Generated:** $(date)
**Period:** Last $REPORT_PERIOD days

## Overview

| Metric | Value |
|--------|-------|
| Total Sessions | ${total_sessions:-0} |
| Total Commands | ${total_commands:-0} |
| Version Switches | ${version_switches:-0} |
| Theme Changes | ${theme_changes:-0} |
| Errors | ${errors:-0} |

## Health Score

EOF

    local health_score=100
    if [[ ${errors:-0} -gt 0 && ${total_commands:-0} -gt 0 ]]; then
        local error_rate=$((errors * 100 / total_commands))
        health_score=$((100 - error_rate))
        [[ $health_score -lt 0 ]] && health_score=0
    fi

    echo "**Score:** $health_score%"
    echo

    if [[ $health_score -ge 90 ]]; then
        echo "**Status:**  Excellent - System running smoothly"
    elif [[ $health_score -ge 70 ]]; then
        echo "**Status:**  Good - Minor issues detected"
    elif [[ $health_score -ge 50 ]]; then
        echo "**Status:**  Fair - Some issues need attention"
    else
        echo "**Status:**  Poor - Multiple issues detected"
    fi

    cat << EOF

## Data Storage

- **Location:** \`$METRICS_DIR\`
- **Retention:** $METRICS_RETENTION_DAYS days

---
*Report generated by Version Manager Analytics*
EOF
}

# ============================================================================
# Usage
# ============================================================================

show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Generate analytics reports from collected metrics.

Options:
    -f, --format FORMAT    Output format: text, json, markdown (default: text)
    -p, --period DAYS      Report period in days (default: 30)
    -o, --output FILE      Save report to file
    -d, --dashboard        Show interactive dashboard
    --privacy              Show privacy information
    -h, --help             Show this help message

Examples:
    $(basename "$0")                    # Text report to stdout
    $(basename "$0") -f json            # JSON report to stdout
    $(basename "$0") -f markdown -o report.md  # Save markdown report
    $(basename "$0") --dashboard        # Interactive dashboard

EOF
}

# ============================================================================
# Main
# ============================================================================

main() {
    local output_file=""
    local show_dashboard=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--format)
                REPORT_FORMAT="$2"
                shift 2
                ;;
            -p|--period)
                REPORT_PERIOD="$2"
                shift 2
                ;;
            -o|--output)
                output_file="$2"
                shift 2
                ;;
            -d|--dashboard)
                show_dashboard=true
                shift
                ;;
            --privacy)
                metrics_privacy
                exit 0
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Initialize metrics
    metrics_init

    if [[ "$show_dashboard" == "true" ]]; then
        metrics_dashboard
        exit 0
    fi

    # Generate report
    local report
    case "$REPORT_FORMAT" in
        json)
            report=$(generate_json_report)
            ;;
        markdown|md)
            report=$(generate_markdown_report)
            ;;
        text|*)
            report=$(generate_text_report)
            ;;
    esac

    # Output report
    if [[ -n "$output_file" ]]; then
        echo "$report" > "$output_file"
        echo "Report saved to: $output_file"
    else
        echo "$report"
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
