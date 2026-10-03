#!/usr/bin/env bash
# =============================================================================
# Logger Contract Test (remediation directive M4 / finding B2.4)
# =============================================================================
# Binding invariant (M1/M4): "Logs go to STDERR; value-returning functions
# own a clean stdout."
#
# Live B2.4 symptom: a value-returning function (theme_detect_current in
# lib/theme-ops.sh) captured via command substitution returned
#   "[timestamp] [WARN] No Powerlevel10k configuration file found\nnone"
# instead of "none", because the logger wrote INFO/WARN/SUCCESS/DEBUG to
# stdout. Only ERROR already went to stderr.
#
# Also asserted (regression guards the M4 stream fix must not break):
#   - DEBUG gating of log_debug
#   - SILENT_MODE suppression of terminal output (file logging still occurs)
#   - LOG_FILE file logging
#   - sourcing logger.sh leaves the caller's shell options unchanged (M1)
# =============================================================================

source ../helpers.sh
source ../../lib/logger.sh

ROOT_DIR="$(cd "$(pwd)/../.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"

failures=0
record() {
    # assert_* helpers print ✓/✗ and return non-zero on failure; accumulate.
    "$@" || failures=$((failures + 1))
}

# ── a. Every log level writes to STDERR, never stdout ────────────────────────
# Streams are captured separately: stdout via command substitution, stderr to
# a file. Substring assertions are color-agnostic (colors may or may not be
# emitted depending on TTY detection).

test_log_streams() {
    local pair
    for pair in log_info:INFO log_warn:WARN log_error:ERROR log_success:SUCCESS; do
        local fn="${pair%%:*}"
        local tag="${pair##*:}"
        local msg="stream-contract ${tag} probe"
        local err_file="$TMP_ROOT/logger_contract.$$.$tag.err"
        local out err
        out="$("$fn" "$msg" 2>"$err_file")"
        err="$(cat "$err_file")"
        rm -f "$err_file"
        record assert_equals "" "$out" "$fn writes NOTHING to stdout (B2.4)"
        record assert_contains "[$tag]" "$err" "$fn tags the message on stderr"
        record assert_contains "$msg" "$err" "$fn delivers the message on stderr"
    done
}

# ── b. Command substitution of a logging value-returner yields ONLY the value
# Reproduces the theme_detect_current pattern (log_warn then echo "none")
# defined locally — no dependency on theme-ops.sh.

value_returning_fn() {
    log_warn "transient diagnostic: configuration file not found"
    echo "none"
}

test_value_fn_owns_stdout() {
    local result
    result="$(value_returning_fn)"
    record assert_equals "none" "$result" \
        "command substitution of logging+value fn returns ONLY the value (B2.4 live symptom)"

    # Diagnostics stay reachable on stderr for callers that want them.
    local err
    err="$(value_returning_fn 2>&1 >/dev/null)"
    record assert_contains "[WARN]" "$err" \
        "value-returning fn's log line still observable on stderr"
}

# ── c1. DEBUG gating still works ─────────────────────────────────────────────
test_debug_gating() {
    local err_file="$TMP_ROOT/logger_contract.$$.debug.err"
    local out err
    unset DEBUG

    out="$(log_debug "gated-off probe" 2>"$err_file")"
    err="$(cat "$err_file")"
    rm -f "$err_file"
    record assert_equals "" "$out" "DEBUG off: log_debug writes nothing to stdout"
    record assert_equals "" "$err" "DEBUG off: log_debug writes nothing to stderr"

    DEBUG=true
    out="$(log_debug "gated-on probe" 2>"$err_file")"
    err="$(cat "$err_file")"
    rm -f "$err_file"
    record assert_equals "" "$out" "DEBUG on: log_debug writes nothing to stdout"
    record assert_contains "[DEBUG]" "$err" "DEBUG on: log_debug reaches stderr"
    record assert_contains "gated-on probe" "$err" "DEBUG on: message delivered on stderr"
    unset DEBUG
}

# ── c2. SILENT_MODE still suppresses terminal output (file logging remains) ──
test_silent_mode() {
    local log_file="$TMP_ROOT/logger_contract.$$.silent.log"
    local err_file="$TMP_ROOT/logger_contract.$$.silent.err"
    rm -f "$log_file" "$err_file"
    LOG_FILE="$log_file"
    SILENT_MODE=true
    local out err
    out="$(log_info "silent probe" 2>"$err_file")"
    err="$(cat "$err_file")"
    rm -f "$err_file"
    unset SILENT_MODE LOG_FILE
    record assert_equals "" "$out" "SILENT_MODE: stdout suppressed"
    record assert_equals "" "$err" "SILENT_MODE: stderr suppressed"
    record assert_file_exists "$log_file" "SILENT_MODE: file logging still occurs"
    record assert_contains "[INFO] silent probe" "$(cat "$log_file" 2>/dev/null)" \
        "SILENT_MODE: file line content unchanged"
    rm -f "$log_file"
}

# ── d. File logging via LOG_FILE still writes the log file ───────────────────
test_file_logging() {
    local log_file="$TMP_ROOT/logger_contract.$$.file.log"
    rm -f "$log_file"
    LOG_FILE="$log_file"
    log_info "file probe" >/dev/null 2>&1
    unset LOG_FILE
    record assert_file_exists "$log_file" "LOG_FILE: log file created"
    record assert_contains "[INFO] file probe" "$(cat "$log_file" 2>/dev/null)" \
        "LOG_FILE: file line content unchanged"
    rm -f "$log_file"
}

# ── e. Library contract regression: logger must not set global options (M1) ──
test_logger_library_contract() {
    local pre post
    pre="$(bash -c 'printf %s "$-"')"
    post="$(bash -c "source '$ROOT_DIR/lib/logger.sh' >/dev/null 2>&1; printf %s \"\$-\"")"
    record assert_equals "$pre" "$post" \
        "sourcing logger.sh leaves caller \$- unchanged (M1, plain caller)"

    pre="$(bash -c 'set -euo pipefail; printf %s "$-"')"
    post="$(bash -c "set -euo pipefail; source '$ROOT_DIR/lib/logger.sh' >/dev/null 2>&1; printf %s \"\$-\"")"
    record assert_equals "$pre" "$post" \
        "sourcing logger.sh leaves caller \$- unchanged (M1, strict caller)"
}

# ── Run ──────────────────────────────────────────────────────────────────────
test_log_streams
test_value_fn_owns_stdout
test_debug_gating
test_silent_mode
test_file_logging
test_logger_library_contract

if [[ "$failures" -gt 0 ]]; then
    echo "test_logger_contract.sh: $failures contract violation(s)"
    exit 1
fi
exit 0
