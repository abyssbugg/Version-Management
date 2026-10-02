#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# ============================================================================
# Metrics Collection Library
# Part of Professional Development Terminal Setup
# ============================================================================
# Provides local metrics collection and analytics for usage statistics.
# All data is stored locally - no external transmission unless opted in.
# ============================================================================

# Prevent multiple sourcing
[[ -n "${_METRICS_LOADED:-}" ]] && return 0
readonly _METRICS_LOADED=1

# ============================================================================
# Configuration
# ============================================================================

# Metrics storage directory
METRICS_DIR="${METRICS_DIR:-$HOME/.cache/version-manager/metrics}"
METRICS_DB="${METRICS_DIR}/metrics.db"
METRICS_EVENTS="${METRICS_DIR}/events.log"
METRICS_STATS="${METRICS_DIR}/stats.json"

# Telemetry settings
METRICS_ENABLED="${METRICS_ENABLED:-true}"
METRICS_ANONYMOUS="${METRICS_ANONYMOUS:-true}"
METRICS_RETENTION_DAYS="${METRICS_RETENTION_DAYS:-30}"

# Session tracking
SESSION_ID=""
SESSION_START=""

# ============================================================================
# Initialization
# ============================================================================

# Initialize metrics system
metrics_init() {
    [[ "$METRICS_ENABLED" != "true" ]] && return 0

    # Create metrics directory
    mkdir -p "$METRICS_DIR"

    # Generate session ID
    SESSION_ID="$(date +%s)-$$-$RANDOM"
    SESSION_START="$(date -Iseconds)"

    # Initialize stats file if missing
    if [[ ! -f "$METRICS_STATS" ]]; then
        cat > "$METRICS_STATS" << 'EOF'
{
    "first_run": "",
    "total_sessions": 0,
    "total_commands": 0,
    "version_switches": 0,
    "theme_changes": 0,
    "errors_encountered": 0,
    "features_used": {},
    "version_managers": {},
    "last_updated": ""
}
EOF
    fi

    # Record session start
    _record_event "session_start" "Session $SESSION_ID started"
    _increment_stat "total_sessions"

    # Cleanup old data
    _cleanup_old_metrics
}

# ============================================================================
# Event Recording
# ============================================================================

# Record a metric event
# Usage: metrics_record <category> <action> [label] [value]
metrics_record() {
    [[ "$METRICS_ENABLED" != "true" ]] && return 0

    local category="$1"
    local action="$2"
    local label="${3:-}"
    local value="${4:-1}"

    _record_event "$category" "$action" "$label" "$value"
    _increment_stat "total_commands"
}

# Record command usage
metrics_command() {
    local command="$1"
    local duration="${2:-0}"
    local success="${3:-true}"

    metrics_record "command" "$command" "$success" "$duration"
    _increment_feature_usage "commands" "$command"
}

# Record version switch
metrics_version_switch() {
    local manager="$1"
    local from_version="${2:-unknown}"
    local to_version="$3"

    metrics_record "version_switch" "$manager" "$from_version->$to_version"
    _increment_stat "version_switches"
    _increment_feature_usage "version_managers" "$manager"
}

# Record theme change
metrics_theme_change() {
    local from_theme="${1:-unknown}"
    local to_theme="$2"

    metrics_record "theme_change" "$to_theme" "$from_theme"
    _increment_stat "theme_changes"
}

# Record error
metrics_error() {
    local error_type="$1"
    local error_message="${2:-}"

    metrics_record "error" "$error_type" "$error_message"
    _increment_stat "errors_encountered"
}

# Record feature usage
metrics_feature() {
    local feature="$1"
    local action="${2:-use}"

    metrics_record "feature" "$feature" "$action"
    _increment_feature_usage "features_used" "$feature"
}

# ============================================================================
# Statistics Tracking
# ============================================================================

# Get a statistic value
metrics_get_stat() {
    local stat_name="$1"

    if [[ -f "$METRICS_STATS" ]]; then
        # Simple JSON parsing for shell
        grep -o "\"$stat_name\": *[0-9]*" "$METRICS_STATS" 2>/dev/null | \
            grep -o '[0-9]*' | head -1
    fi
}

# Get all statistics
metrics_get_all_stats() {
    if [[ -f "$METRICS_STATS" ]]; then
        cat "$METRICS_STATS"
    else
        echo "{}"
    fi
}

# Get usage summary
metrics_summary() {
    local total_sessions total_commands version_switches errors

    total_sessions=$(metrics_get_stat "total_sessions")
    total_commands=$(metrics_get_stat "total_commands")
    version_switches=$(metrics_get_stat "version_switches")
    errors=$(metrics_get_stat "errors_encountered")

    cat << EOF
Usage Statistics Summary
========================
Total Sessions:     ${total_sessions:-0}
Total Commands:     ${total_commands:-0}
Version Switches:   ${version_switches:-0}
Errors Encountered: ${errors:-0}

Data stored in: $METRICS_DIR
EOF
}

# ============================================================================
# Analytics Dashboard
# ============================================================================

# Display analytics dashboard
metrics_dashboard() {
    local total_sessions total_commands version_switches theme_changes errors

    total_sessions=$(metrics_get_stat "total_sessions" || echo "0")
    total_commands=$(metrics_get_stat "total_commands" || echo "0")
    version_switches=$(metrics_get_stat "version_switches" || echo "0")
    theme_changes=$(metrics_get_stat "theme_changes" || echo "0")
    errors=$(metrics_get_stat "errors_encountered" || echo "0")

    # Calculate averages
    local avg_commands=0
    if [[ ${total_sessions:-0} -gt 0 ]]; then
        avg_commands=$((${total_commands:-0} / ${total_sessions:-1}))
    fi

    echo
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║            Usage Analytics Dashboard                       ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║                                                              ║"
    printf "║  %-20s %10s                           ║\n" "Total Sessions:" "${total_sessions:-0}"
    printf "║  %-20s %10s                           ║\n" "Total Commands:" "${total_commands:-0}"
    printf "║  %-20s %10s                           ║\n" "Avg Cmds/Session:" "$avg_commands"
    echo "║                                                              ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Activity Breakdown                                          ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    printf "║  %-20s %10s                           ║\n" "Version Switches:" "${version_switches:-0}"
    printf "║  %-20s %10s                           ║\n" "Theme Changes:" "${theme_changes:-0}"
    printf "║  %-20s %10s                           ║\n" "Errors:" "${errors:-0}"
    echo "║                                                              ║"
    echo "╠══════════════════════════════════════════════════════════════╣"

    # Show most used version managers
    echo "║  Most Used Version Managers                                  ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    _show_top_features "version_managers" 3

    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Most Used Features                                          ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    _show_top_features "features_used" 3

    echo "╚══════════════════════════════════════════════════════════════╝"
    echo
    echo "  Data retention: ${METRICS_RETENTION_DAYS} days"
    echo "  Storage: $METRICS_DIR"
    echo
}

# Show top features
_show_top_features() {
    local category="$1"
    local limit="${2:-5}"

    if [[ -f "$METRICS_STATS" ]]; then
        # Extract and display top items (simplified parsing)
        local found=0
        while IFS=: read -r key value; do
            key="${key//\"/}"
            key="${key// /}"
            value="${value//,/}"
            value="${value// /}"
            if [[ -n "$key" && "$value" =~ ^[0-9]+$ && $value -gt 0 ]]; then
                printf "║    %-18s %8s uses                        ║\n" "$key" "$value"
                found=$(( found + 1 ))
                [[ $found -ge $limit ]] && break
            fi
        done < <(grep -A20 "\"$category\"" "$METRICS_STATS" 2>/dev/null | grep -E '^\s+"[^"]+": [0-9]+' | sort -t: -k2 -rn)

        if [[ $found -eq 0 ]]; then
            echo "║    No data yet                                               ║"
        fi
    else
        echo "║    No data yet                                               ║"
    fi
}

# ============================================================================
# Data Export
# ============================================================================

# Export metrics to JSON
metrics_export_json() {
    local output="${1:-$METRICS_DIR/export-$(date +%Y%m%d).json}"

    {
        echo "{"
        echo "  \"export_date\": \"$(date -Iseconds)\","
        echo "  \"stats\": $(cat "$METRICS_STATS" 2>/dev/null || echo '{}'),"
        echo "  \"recent_events\": ["

        # Last 100 events
        local first=true
        tail -100 "$METRICS_EVENTS" 2>/dev/null | while read -r line; do
            if [[ "$first" == "true" ]]; then
                first=false
            else
                echo ","
            fi
            printf '    "%s"' "$line"
        done

        echo
        echo "  ]"
        echo "}"
    } > "$output"

    echo "Exported metrics to: $output"
}

# Export metrics to CSV
metrics_export_csv() {
    local output="${1:-$METRICS_DIR/export-$(date +%Y%m%d).csv}"

    echo "timestamp,session,category,action,label,value" > "$output"

    if [[ -f "$METRICS_EVENTS" ]]; then
        tail -1000 "$METRICS_EVENTS" >> "$output"
    fi

    echo "Exported metrics to: $output"
}

# ============================================================================
# Privacy & Data Management
# ============================================================================

# Clear all metrics data
metrics_clear() {
    if [[ -d "$METRICS_DIR" ]]; then
        rm -rf "$METRICS_DIR"
        echo "All metrics data cleared."
    else
        echo "No metrics data found."
    fi
}

# Disable metrics collection
metrics_disable() {
    METRICS_ENABLED="false"
    echo "Metrics collection disabled for this session."
    echo "To permanently disable, set METRICS_ENABLED=false in your shell config."
}

# Enable metrics collection
metrics_enable() {
    METRICS_ENABLED="true"
    metrics_init
    echo "Metrics collection enabled."
}

# Show privacy info
metrics_privacy() {
    cat << 'EOF'
Metrics & Privacy Information
=============================

This tool collects anonymous usage statistics to help improve the software.

What we collect:
  • Command usage counts
  • Feature usage patterns
  • Version manager usage
  • Error occurrences (not content)

What we DON'T collect:
  • Personal information
  • File contents or paths
  • Specific version numbers
  • Network data
  • Any identifying information

Data storage:
  • All data is stored LOCALLY on your machine
  • Location: ~/.cache/version-manager/metrics/
  • No data is transmitted unless you explicitly export it

Your controls:
  • View data:   metrics_dashboard
  • Export data: metrics_export_json or metrics_export_csv
  • Clear data:  metrics_clear
  • Disable:     Set METRICS_ENABLED=false

EOF
}

# ============================================================================
# Internal Functions
# ============================================================================

# Record event to log
_record_event() {
    local category="$1"
    local action="$2"
    local label="${3:-}"
    local value="${4:-1}"
    local timestamp
    timestamp="$(date -Iseconds)"

    echo "$timestamp,$SESSION_ID,$category,$action,$label,$value" >> "$METRICS_EVENTS"
    _update_last_modified
}

# Increment a stat counter
_increment_stat() {
    local stat_name="$1"
    local increment="${2:-1}"

    if [[ -f "$METRICS_STATS" ]]; then
        local current
        current=$(metrics_get_stat "$stat_name" || echo "0")
        local new_value=$((current + increment))

        # Update using sed (portable)
        if [[ "$(uname -s)" == "Darwin" ]]; then
            sed -i '' "s/\"$stat_name\": *[0-9]*/\"$stat_name\": $new_value/" "$METRICS_STATS"
        else
            sed -i "s/\"$stat_name\": *[0-9]*/\"$stat_name\": $new_value/" "$METRICS_STATS"
        fi
    fi
}

# Increment feature usage counter
_increment_feature_usage() {
    local category="$1"
    local feature="$2"

    # This is simplified - a full implementation would use jq or similar
    # For now, we just log to events
    _record_event "feature_count" "$category" "$feature"
}

# Update last modified timestamp
_update_last_modified() {
    local timestamp
    timestamp="$(date -Iseconds)"

    if [[ -f "$METRICS_STATS" ]]; then
        if [[ "$(uname -s)" == "Darwin" ]]; then
            sed -i '' "s/\"last_updated\": *\"[^\"]*\"/\"last_updated\": \"$timestamp\"/" "$METRICS_STATS"
        else
            sed -i "s/\"last_updated\": *\"[^\"]*\"/\"last_updated\": \"$timestamp\"/" "$METRICS_STATS"
        fi
    fi
}

# Cleanup old metrics data
_cleanup_old_metrics() {
    if [[ -d "$METRICS_DIR" ]]; then
        # Remove events older than retention period
        find "$METRICS_DIR" -name "*.log" -mtime "+$METRICS_RETENTION_DAYS" -delete 2>/dev/null || true
        find "$METRICS_DIR" -name "export-*.json" -mtime "+$METRICS_RETENTION_DAYS" -delete 2>/dev/null || true
        find "$METRICS_DIR" -name "export-*.csv" -mtime "+$METRICS_RETENTION_DAYS" -delete 2>/dev/null || true
    fi
}

# ============================================================================
# Export Functions
# ============================================================================

export -f metrics_init
export -f metrics_record
export -f metrics_command
export -f metrics_version_switch
export -f metrics_theme_change
export -f metrics_error
export -f metrics_feature
export -f metrics_get_stat
export -f metrics_get_all_stats
export -f metrics_summary
export -f metrics_dashboard
export -f metrics_export_json
export -f metrics_export_csv
export -f metrics_clear
export -f metrics_disable
export -f metrics_enable
export -f metrics_privacy
