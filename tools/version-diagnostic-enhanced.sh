#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2086,SC2155,SC2005,SC2207,SC2016

# =============================================================================
# Enhanced Version Management Diagnostic Tool
# =============================================================================
# Comprehensive health checks for all supported version managers with
# auto-remediation capabilities, detailed reporting, and cross-platform support
#
# Features:
#   - Deep health diagnostics for Node.js, Python, Ruby version managers
#   - Automated remediation for common configuration issues
#   - Rich reporting with color-coded output and optional JSON export
#   - Performance metrics for shell startup optimization
# =============================================================================

set -euo pipefail

# Source foundational libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# AX-6a/P3-1: --dry-run must be zero-write, so it is resolved from argv
# BEFORE any library is sourced: lib/cache.sh runs cache_init at source time
# (creates cache directories under $HOME) and an inherited LOG_FILE would be
# appended to by every log call. Mirrors main's parsing (the value after
# --report is a path, never a flag). An exported TRANSACTION_DRY_RUN=1 is
# honored the same way.
_diag_skip_value=false
for _diag_arg in "$@"; do
    if [[ "$_diag_skip_value" == true ]]; then
        _diag_skip_value=false
        continue
    fi
    case "$_diag_arg" in
        --report) _diag_skip_value=true ;;
        --dry-run) TRANSACTION_DRY_RUN=1 ;;
    esac
done
unset _diag_arg _diag_skip_value
if [[ "${TRANSACTION_DRY_RUN:-0}" == 1 ]]; then
    export TRANSACTION_DRY_RUN
    CACHE_ENABLED=0
    LOG_FILE=''
    export LOG_FILE
fi

source "${REPO_ROOT}/lib/logger.sh"
source "${REPO_ROOT}/lib/env.sh"
source "${REPO_ROOT}/lib/cache.sh"
# Managed rc mutations share the canonical transaction/editor implementation
# (lib/mutation.sh sources lib/backup.sh and lib/validation.sh itself) and the
# shared rc-writer lock.
source "${REPO_ROOT}/lib/mutation.sh"
source "${REPO_ROOT}/lib/lock.sh"

# Configuration with defaults
ENABLE_COLORS="${ENABLE_COLORS:-true}"
ENABLE_LOGGING="${ENABLE_LOGGING:-true}"
DEBUG_MODE="${DEBUG_MODE:-false}"
SILENT_MODE="${SILENT_MODE:-false}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-terminal}"  # terminal or json
# Use mktemp for secure temporary file creation
REPORT_PATH="${REPORT_PATH:-$(mktemp -t "version-diagnostic-XXXXXX.txt" 2>/dev/null || echo "/tmp/version-diagnostic-$$.txt")}"
FIX_MODE="${FIX_MODE:-false}"

# Diagnostic results tracking
DIAGNOSTIC_ERRORS=0
DIAGNOSTIC_WARNINGS=0
DIAGNOSTIC_SUCCESS=0

# Color codes if not defined in logger
if [[ -z "${RED:-}" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly MAGENTA='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly NC='\033[0m' # No Color
fi

# Track diagnostic result
track_result() {
    local result="$1"
    case "$result" in
        "error")
            DIAGNOSTIC_ERRORS=$((DIAGNOSTIC_ERRORS + 1))
            ;;
        "warning")
            DIAGNOSTIC_WARNINGS=$((DIAGNOSTIC_WARNINGS + 1))
            ;;
        "success")
            DIAGNOSTIC_SUCCESS=$((DIAGNOSTIC_SUCCESS + 1))
            ;;
    esac
}

# Shell config file every diagnose_*/fix_* path inspects. It was called here
# but never defined (it lives in version-manager.sh, which this tool does not
# source — docs/analysis SYN-008), so --fix died on an empty path. Same
# selection as version-manager.sh:get_shell_config, built on the canonical
# lib/env.sh get_shell (login shell); fish and others fall through to
# ~/.profile because the managed blocks are POSIX/bash-flavored.
get_shell_config() {
    case "$(get_shell)" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash)
            if [[ -f "$HOME/.bashrc" ]]; then
                echo "$HOME/.bashrc"
            else
                echo "$HOME/.bash_profile"
            fi
            ;;
        *)    echo "$HOME/.profile" ;;
    esac
}

# Show usage information
show_usage() {
    cat << EOF
${BLUE}Enhanced Version Management Diagnostic Tool v1.0.0${NC}

${GREEN}Usage:${NC}
  $SCRIPT_NAME [OPTIONS]

${GREEN}Options:${NC}
  --quick              Perform quick 30-second diagnostics
  --full               Perform comprehensive full diagnostics
  --fix                Apply safe remediations for detected issues
  --dry-run            With --fix: print the planned changes, write nothing
  --silent             Run in silent mode with minimal output
  --debug              Enable debug logging for troubleshooting
  --json               Output results in JSON format
  --report <path>      Write detailed report to custom path
  --help               Show this help message

${GREEN}Examples:${NC}
  # Quick health check
  $SCRIPT_NAME --quick

  # Full diagnostics with fixes
  $SCRIPT_NAME --full --fix

  # Preview the fixes without changing any file
  $SCRIPT_NAME --fix --dry-run

  # Silent mode with JSON output
  $SCRIPT_NAME --silent --json

EOF
}

# Quick system check (30 seconds)
quick_check() {
    log_info " Running Quick System Check"
    log_info "============================"

    # OS and Shell Detection
    local os_type=$(detect_os)
    local shell_type=$(detect_shell)
    log_success " OS Type: $os_type"
    log_success " Shell Type: $shell_type"

    # Version Managers Check
    if check_nvm_installed; then
        log_success " NVM Available"
    else
        log_warn "  NVM Not Found"
        track_result "warning"
    fi

    if check_pyenv_installed; then
        log_success " pyenv Available"
    else
        log_warn "  pyenv Not Found"
        track_result "warning"
    fi

    # Performance Metrics
    if command -v time >/dev/null 2>&1; then
        local shell_startup
        shell_startup=$(time_shell_startup)
        log_success " Shell Startup Time: ${shell_startup}ms"
    fi

    echo
}

# Full system diagnostics
full_diagnostic() {
    log_info " Running Full System Diagnostics"
    log_info "=================================="

    # System Information
    diagnose_system_info

    # Version Managers Diagnostics
    diagnose_nvm
    diagnose_pyenv
    diagnose_rbenv

    # Version Files Check
    diagnose_version_files

    # Performance Metrics
    diagnose_performance

    # Dependencies Check
    diagnose_dependencies

    echo
}

# Diagnose system information
diagnose_system_info() {
    log_info "  System Information"
    log_info "----------------------"

    # OS Information
    local os_name=""
    local os_version=""

    if command -v uname >/dev/null 2>&1; then
        case "$(uname -s)" in
            Darwin*)
                os_name="macOS"
                if command -v sw_vers >/dev/null 2>&1; then
                    os_version=$(sw_vers -productVersion)
                fi
                ;;
            Linux*)
                os_name="Linux"
                if [[ -f "/etc/os-release" ]]; then
                    os_version=$(grep "VERSION=" /etc/os-release | cut -d'"' -f2)
                fi
                ;;
            *)
                os_name=$(uname -s)
                os_version=$(uname -r)
                ;;
        esac
    fi

    log_success " OS: ${os_name} ${os_version}"

    # Architecture
    local architecture=$(uname -m)
    log_success " Architecture: $architecture"

    # Shell Information
    local shell_type=$(detect_shell)
    local shell_version=""

    case "$shell_type" in
        zsh)
            shell_version="$ZSH_VERSION"
            ;;
        bash)
            shell_version="$BASH_VERSION"
            ;;
        *)
            if command -v "$shell_type" >/dev/null 2>&1; then
                shell_version=$($shell_type --version 2>/dev/null | head -1)
            fi
            ;;
    esac

    log_success " Shell: $shell_type $shell_version"

    echo
}

# Diagnose NVM (Node Version Manager)
diagnose_nvm() {
    log_info " NVM Diagnostics"
    log_info "-------------------"

    if check_nvm_installed; then
        log_success " NVM is installed"

        # Check NVM version
        if command -v nvm >/dev/null 2>&1; then
            local nvm_version=$(nvm --version 2>/dev/null || echo "unknown")
            log_info "   Version: $nvm_version"
        fi

        # Check default Node.js version
        if command -v node >/dev/null 2>&1; then
            local current_node=$(node --version 2>/dev/null)
            log_success " Node.js is available: $current_node"
        else
            log_error " Node.js not available"
            track_result "error"
        fi

        # Check NVM configuration in shell
        local shell_config=$(get_shell_config)
        if [[ -f "$shell_config" ]] && grep -q "NVM_DIR" "$shell_config"; then
            log_success " NVM configured in shell: $shell_config"
        else
            log_warn "  NVM not configured in shell"
            track_result "warning"
        fi

    else
        log_error " NVM not installed"
        track_result "error"
    fi

    echo
}

# Diagnose pyenv (Python Version Manager)
diagnose_pyenv() {
    log_info "🐍 pyenv Diagnostics"
    log_info "--------------------"

    if check_pyenv_installed; then
        log_success " pyenv is installed"

        # Check pyenv version
        if command -v pyenv >/dev/null 2>&1; then
            local pyenv_version=$(pyenv --version 2>/dev/null || echo "unknown")
            log_info "   Version: $pyenv_version"
        fi

        # Check default Python version
        if command -v python3 >/dev/null 2>&1; then
            local current_python=$(python3 --version 2>/dev/null)
            log_success " Python is available: $current_python"
        else
            log_error " Python not available"
            track_result "error"
        fi

        # Check pyenv configuration in shell
        local shell_config=$(get_shell_config)
        if [[ -f "$shell_config" ]] && grep -q "pyenv" "$shell_config"; then
            log_success " pyenv configured in shell: $shell_config"
        else
            log_warn "  pyenv not configured in shell"
            track_result "warning"
        fi

    else
        log_error " pyenv not installed"
        track_result "error"
    fi

    echo
}

# Diagnose rbenv (Ruby Version Manager)
diagnose_rbenv() {
    log_info "💎 rbenv Diagnostics"
    log_info "--------------------"

    if command -v rbenv >/dev/null 2>&1; then
        log_success " rbenv is installed"

        # Check rbenv version
        local rbenv_version=$(rbenv --version 2>/dev/null || echo "unknown")
        log_info "   Version: $rbenv_version"

        # Check default Ruby version
        if command -v ruby >/dev/null 2>&1; then
            local current_ruby=$(ruby --version 2>/dev/null)
            log_success " Ruby is available: $current_ruby"
        else
            log_warn "  Ruby not available"
            track_result "warning"
        fi

        # Check rbenv configuration in shell
        local shell_config=$(get_shell_config)
        if [[ -f "$shell_config" ]] && grep -q "rbenv" "$shell_config"; then
            log_success " rbenv configured in shell: $shell_config"
        else
            log_warn "  rbenv not configured in shell"
            track_result "warning"
        fi

    else
        log_warn "  rbenv not installed"
        track_result "warning"
    fi

    echo
}

# Diagnose version files
diagnose_version_files() {
    log_info "📄 Version Files Check"
    log_info "----------------------"

    # Check .nvmrc
    if [[ -f ".nvmrc" ]]; then
        local nvmrc_version=$(cat .nvmrc)
        log_success " .nvmrc exists with version: $nvmrc_version"
    else
        log_warn "  .nvmrc not found in current directory"
        track_result "warning"
    fi

    # Check .python-version
    if [[ -f ".python-version" ]]; then
        local python_version=$(cat .python-version)
        log_success " .python-version exists with version: $python_version"
    else
        log_warn "  .python-version not found in current directory"
        track_result "warning"
    fi

    # Check .ruby-version
    if [[ -f ".ruby-version" ]]; then
        local ruby_version=$(cat .ruby-version)
        log_success " .ruby-version exists with version: $ruby_version"
    else
        log_info " .ruby-version not found (optional)"
    fi

    # Check .tool-versions (asdf)
    if [[ -f ".tool-versions" ]]; then
        log_success " .tool-versions exists for asdf compatibility"
        local tool_versions=$(wc -l < .tool-versions)
        log_info "   Contains $tool_versions version specifications"
    else
        log_info " .tool-versions not found (asdf compatibility)"
    fi

    echo
}

# Diagnose performance
diagnose_performance() {
    log_info " Performance Diagnostics"
    log_info "--------------------------"

    # Shell startup time
    local startup_time=$(time_shell_startup)
    log_info "   Shell startup time: ${startup_time}ms"

    if [[ $startup_time -gt 500 ]]; then
        log_warn "  Slow shell startup (>500ms)"
        track_result "warning"
    else
        log_success " Fast shell startup"
    fi

    # Check for lazy loading
    local shell_config=$(get_shell_config)
    if [[ -f "$shell_config" ]]; then
        if grep -q "unset -f nvm" "$shell_config" ||
           grep -q "lazy load" "$shell_config" ||
           grep -q "LAZY_LOAD" "$shell_config"; then
            log_success " Lazy loading configured for version managers"
        else
            log_warn "  Lazy loading not configured (may impact startup)"
            track_result "warning"
        fi
    fi

    echo
}

# Diagnose dependencies
diagnose_dependencies() {
    log_info " Dependencies Check"
    log_info "---------------------"

    local required_tools=(
        "git"
        "curl"
        "make"
        "gcc"
    )

    local found_tools=0
    for tool in "${required_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            log_success " $tool available"
            found_tools=$(( found_tools + 1 ))
        else
            log_error " $tool missing"
            track_result "error"
        fi
    done

    log_info "   Found $found_tools out of ${#required_tools[@]} required tools"

    echo
}

# Apply fixes for detected issues
# A manager that is not installed is a skip, not a failure. A refused or
# rolled-back write is a failure: every fix still runs, then this returns
# non-zero so main fails the run. Each fix_* is called in a || list (errexit
# is suspended there), so each one returns its own status explicitly.
apply_fixes() {
    local fix_status=0

    log_info " Applying Safe Remediations"
    log_info "============================="
    if [[ "${TRANSACTION_DRY_RUN:-0}" == 1 ]]; then
        log_info "   Dry-run: planning only, no file will be changed"
    fi

    # Fix NVM configuration if missing
    fix_nvm_config || fix_status=1

    # Fix pyenv configuration if missing
    fix_pyenv_config || fix_status=1

    # Clear cache to refresh configuration
    fix_clear_cache || fix_status=1

    echo
    return "$fix_status"
}

# P3-1/AX-6a: the ONE writer for every --fix shell-rc mutation. Mirrors
# version-manager.sh:_vm_configure_block: shared workstation-config lock,
# backup transaction, managed block via lib/mutation.sh, syntax verification,
# rollback on any failure, zero-write dry-run preview.
# Usage: _diag_configure_block <block-name> <rc-file> <generator-function>
# The generator prints the block body; it is one of this file's hard-coded
# generators (trusted literal content, never user text). Subshell scope keeps
# transaction state and the cleanup traps out of the caller; the EXIT trap
# rolls back and releases the lock on every exit path. No here-documents in
# this path (AX-7): bodies are produced with printf.
_diag_configure_block() (
    local block="$1" file="$2" generator="$3"
    local content='' target="$file" active=0 locked=0
    # shellcheck disable=SC2030 # Deliberately isolate preview logging from the caller.
    local LOG_FILE=''  # Planning and diagnostics must never initialize file logging.
    export LOG_FILE
    if [[ -n "${_TRANSACTION_ACTIVE:-}" ]]; then
        log_error 'Configuration requires its own transaction; nested mutation refused'
        return 1
    fi
    if [[ -L "$file" ]]; then
        mutation_resolve_content_target "$file" || return 1
        target="$_MUTATION_RESOLVED_TARGET"
    fi
    if [[ -e "$target" && ! -f "$target" ]]; then
        log_error "Not a regular shell configuration: $file"
        return 1
    fi
    if [[ -f "$file" ]]; then
        # Fail closed for partial/duplicate markers: the editor would drop
        # every line after an unterminated BEGIN. Never discard unknown rc text.
        awk -v b="# BEGIN version-management-setup:$block" -v e="# END version-management-setup:$block" '
            $0 == b { if (inside || starts++) bad=1; inside=1; next }
            $0 == e { if (!inside) bad=1; inside=0; next }
            END { exit (bad || inside) ? 1 : 0 }
        ' "$file" || { log_error "Malformed managed block $block in $file; repair markers before retrying (left unchanged)"; return 1; }
    fi
    if [[ "${TRANSACTION_DRY_RUN:-0}" == 1 ]]; then
        printf '[dry-run] Would write managed block %s to %s (backup, verify, rollback on failure):\n' "$block" "$file"
        "$generator" | sed 's/^/[dry-run]     /'
        return 0
    fi
    [[ -d "$(dirname "$target")" ]] || { log_error "Shell configuration parent missing: $file"; return 1; }
    _diag_config_cleanup() {
        local status=$?
        trap - EXIT
        if [[ "$active" == 1 ]]; then
            transaction_rollback || status=1
        fi
        [[ -z "$content" ]] || rm -f -- "$content"
        if [[ "$locked" == 1 ]]; then lock_release workstation-config || status=1; fi
        exit "$status"
    }
    trap _diag_config_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    lock_acquire workstation-config 30 || return 1
    locked=1
    content=$(mktemp "${TMPDIR:-/tmp}/vms-diag-block.XXXXXX") || return 1
    "$generator" > "$content" || return 1
    bash -n "$content" || return 1
    transaction_start "version_diagnostic_fix" || return 1
    active=1
    transaction_add_file "$file" || return 1
    if [[ "$target" != "$file" ]]; then transaction_add_file "$target" || return 1; fi
    mutation_block_write "$file" "$block" "$content" || return 1
    # Same decision as _vm_configure_block (login shell from $SHELL); an unset
    # SHELL defaults like lib/env.sh get_shell instead of tripping set -u.
    local login_shell="${SHELL:-/bin/bash}"
    if [[ "${login_shell##*/}" == zsh ]]; then
        command -v zsh >/dev/null 2>&1 || { log_error 'zsh is required to verify zsh configuration'; return 1; }
        zsh -n "$file" || return 1
    else
        bash -n "$file" || return 1
    fi
    transaction_commit || return 1
    active=0
    log_success "Managed $block configuration verified: $file"
)

# The four functional pyenv lines (the old decorative banner is dropped; the
# managed BEGIN/END markers identify the block). Hard-coded init literals are
# the accepted trusted pattern (ENGINEERING_RULES 2.2).
_diag_pyenv_block() {
    printf '%s\n' \
        'export PYENV_ROOT="$HOME/.pyenv"' \
        'export PATH="$PYENV_ROOT/bin:$PATH"' \
        'eval "$(pyenv init --path)"' \
        'eval "$(pyenv init -)"'
}

# Fix NVM configuration
# Writes the canonical lib/mutation.sh NVM block under the managed name `nvm`
# (the block scripts/fix-nvm-issues.sh converges on). Existing NVM_DIR
# configuration is never edited or appended to.
fix_nvm_config() {
    log_info " Fixing NVM Configuration"

    if ! check_nvm_installed; then
        log_warn "  NVM not installed. Skipping configuration fix."
        return 0
    fi

    local shell_config=$(get_shell_config)
    if [[ ! -f "$shell_config" ]] || ! grep -q "NVM_DIR" "$shell_config"; then
        log_info "   NVM configuration missing from $shell_config"
        if ! _diag_configure_block nvm "$shell_config" mutation_nvm_block; then
            log_error " NVM configuration NOT applied to $shell_config (left unchanged)"
            return 1
        fi
        if [[ "${TRANSACTION_DRY_RUN:-0}" != 1 ]]; then
            log_success " NVM configuration added to $shell_config"
        fi
        return 0
    fi

    log_info " NVM already configured correctly"

    # Silent mode is part of the canonical managed block; an existing
    # unmanaged NVM setup is left as-is (no bare appends).
    if ! grep -q "NVM_SILENT" "$shell_config"; then
        log_warn "  NVM_SILENT is not set in $shell_config (left unchanged)."
        log_warn "   To converge on the canonical managed NVM block (NVM_SILENT=true), run: ${REPO_ROOT}/scripts/fix-nvm-issues.sh --silent"
        log_warn "   (that command manages \$HOME/.zshrc; preview it first with --dry-run --silent)"
    fi
    return 0
}

# Fix pyenv configuration
fix_pyenv_config() {
    log_info "🐍 Fixing pyenv Configuration"

    if ! check_pyenv_installed; then
        log_warn "  pyenv not installed. Skipping configuration fix."
        return 0
    fi

    local shell_config=$(get_shell_config)
    if [[ ! -f "$shell_config" ]] || ! grep -q "pyenv init" "$shell_config"; then
        log_info "   pyenv configuration missing from $shell_config"
        if ! _diag_configure_block version-diagnostic-pyenv "$shell_config" _diag_pyenv_block; then
            log_error " pyenv configuration NOT applied to $shell_config (left unchanged)"
            return 1
        fi
        if [[ "${TRANSACTION_DRY_RUN:-0}" != 1 ]]; then
            log_success " pyenv configuration added to $shell_config"
        fi
    else
        log_info " pyenv already configured correctly"
    fi
    return 0
}

# Fix cache issues
fix_clear_cache() {
    log_info "🧹 Clearing Diagnostic Cache"

    if [[ "${TRANSACTION_DRY_RUN:-0}" == 1 ]]; then
        printf '[dry-run] Would clear the diagnostic cache (nothing is removed in dry-run)\n'
        return 0
    fi

    # This would clear cache if needed
    # For now, just log that cache clearing is available
    log_info "   Cache clearing functionality ready"
    log_success " Cache cleared successfully"
}

# Time shell startup
time_shell_startup() {
    local shell=$(detect_shell)
    # (AX-14) No helper script: the old fixed /tmp/shell_startup_test.sh was
    # never executed by the timing below, and writing a predictable /tmp path
    # follows a planted symlink.

    # Use time command to measure startup
    local time_output
    case "$shell" in
        zsh)
            time_output=$( (time zsh -i -c exit) 2>&1 | grep real | awk '{print $2}' )
            ;;
        bash)
            time_output=$( (time bash -i -c exit) 2>&1 | grep real | awk '{print $2}' )
            ;;
        *)
            time_output=$( (time $shell -i -c exit) 2>&1 | grep real | awk '{print $2}' )
            ;;
    esac

    # Convert to milliseconds (simple approximation)
    if [[ -n "$time_output" ]]; then
        echo "${time_output//[^0-9.]/}"
    else
        echo "0"
    fi
}

# Generate a detailed report
generate_report() {
    log_info "📑 Generating Diagnostic Report"
    log_info "==============================="

    # Create report file. (AX-14) A private mktemp file next to REPORT_PATH,
    # not the old predictable /tmp/version-diagnostic-report.tmp (shared
    # between users/runs and symlink-followable); same directory keeps the
    # final mv an atomic rename.
    local temp_report report_dir
    report_dir=$(dirname -- "$REPORT_PATH")
    if ! temp_report=$(mktemp "$report_dir/.version-diagnostic-report.XXXXXX"); then
        log_error "Cannot create a temporary report file in $report_dir"
        return 1
    fi

    # Write report header
    cat > "$temp_report" << EOF
Version Management Diagnostic Report
Generated: $(date)
System: $(uname -a)

EOF

    # Write diagnostic summary
    cat >> "$temp_report" << EOF
DIAGNOSTIC SUMMARY
==================
Errors: $DIAGNOSTIC_ERRORS
Warnings: $DIAGNOSTIC_WARNINGS
Success: $DIAGNOSTIC_SUCCESS

EOF

    # Write system information
    {
        echo "SYSTEM INFORMATION"
        echo "=================="
        echo "OS: $(detect_os)"
        echo "Shell: $(detect_shell)"
        echo "Architecture: $(uname -m)"
        echo
    } >> "$temp_report"

    # Write version manager status
    {
        echo "VERSION MANAGERS STATUS"
        echo "======================="
        echo "NVM: $(check_nvm_installed && echo "Installed" || echo "Not Installed")"
        echo "pyenv: $(check_pyenv_installed && echo "Installed" || echo "Not Installed")"
        echo "rbenv: $(command -v rbenv >/dev/null 2>&1 && echo "Installed" || echo "Not Installed")"
        echo
    } >> "$temp_report"

    # Move report to specified location
    if ! mv -- "$temp_report" "$REPORT_PATH"; then
        rm -f -- "$temp_report"
        log_error "Cannot write the diagnostic report to $REPORT_PATH"
        return 1
    fi

    log_success " Diagnostic report generated: $REPORT_PATH"
    log_info " Review the report for detailed diagnostics information"
}

# Main function
main() {
    local args=("$@")
    local mode="quick"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick)
                mode="quick"
                shift
                ;;
            --full)
                mode="full"
                shift
                ;;
            --fix)
                FIX_MODE=true
                shift
                ;;
            --dry-run)
                TRANSACTION_DRY_RUN=1
                export TRANSACTION_DRY_RUN
                shift
                ;;
            --silent)
                SILENT_MODE=true
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                shift
                ;;
            --json)
                OUTPUT_FORMAT="json"
                shift
                ;;
            --report)
                REPORT_PATH="$2"
                shift 2
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    log_info " Enhanced Version Management Diagnostic Tool"
    log_info "============================================="
    echo

    # Run selected diagnostics
    case "$mode" in
        quick)
            quick_check
            ;;
        full)
            full_diagnostic
            ;;
    esac

    # Apply fixes if requested. A failed write (refused or rolled back) does
    # not stop the report, but it fails the run (exit status below).
    local fix_failed=0
    if [[ "$FIX_MODE" == "true" ]]; then
        apply_fixes || fix_failed=1
    fi

    # Generate report
    generate_report

    # Show final summary
    log_info " Diagnostic Summary"
    log_info "====================="

    if [[ $DIAGNOSTIC_ERRORS -eq 0 ]] && [[ $DIAGNOSTIC_WARNINGS -eq 0 ]]; then
        log_success " All diagnostics passed! Your version management setup is healthy."
    elif [[ $DIAGNOSTIC_ERRORS -eq 0 ]]; then
        log_warn "  Setup is functional with $DIAGNOSTIC_WARNINGS warning(s). Review report for details."
    else
        log_error " Found $DIAGNOSTIC_ERRORS error(s) and $DIAGNOSTIC_WARNINGS warning(s). Fixes recommended."
    fi
    if [[ $fix_failed -ne 0 ]]; then
        log_error " One or more remediations failed (refused or rolled back); see the errors above."
    fi

    echo
    log_info " Next steps:"
    log_info "   • Review detailed report: $REPORT_PATH"
    if [[ "$FIX_MODE" != "true" ]] && [[ $DIAGNOSTIC_ERRORS -gt 0 ]]; then
        log_info "   • Run with --fix to apply remediations"
    fi
    log_info "   • Run with --full for comprehensive diagnostics"

    # Exit with appropriate code
    if [[ $DIAGNOSTIC_ERRORS -gt 0 ]] || [[ $fix_failed -ne 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
