#!/usr/bin/env bash
# Unit tests for lib/error-handling.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$SCRIPT_DIR/../helpers.sh"

coverage_init "error_handling"

# ── Tests ─────────────────────────────────────────────────────────────────────
failures=0

record_assert() {
    "$@" || failures=$((failures + 1))
}

load_error_handling() {
    # shellcheck source=lib/error-handling.sh
    source "$ROOT_DIR/lib/error-handling.sh" 2>/dev/null || true
    # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
    log_error() { :; }
    # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
    log_warn()  { :; }
    # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
    log_debug() { :; }
}

write_counter_script() {
    local script_path="$1"
    cat > "$script_path" <<'SCRIPT'
#!/usr/bin/env bash
counter_file="$1"
count=0
if [[ -f "$counter_file" ]]; then
    count="$(cat "$counter_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$counter_file"
exit 1
SCRIPT
    chmod +x "$script_path"
}

test_safe_exec_argv_success() {
    track_coverage "safe_exec_argv"
    local tmp_dir marker script_path
    tmp_dir="$(mktemp -d)"
    marker="$tmp_dir/success.txt"
    script_path="$tmp_dir/write-success.sh"
    cat > "$script_path" <<'SCRIPT'
#!/usr/bin/env bash
printf 'ok:%s\n' "$2" > "$1"
SCRIPT
    chmod +x "$script_path"

    load_error_handling
    SAFE_EXEC_RETRIES=1 SAFE_EXEC_DELAY=0 safe_exec_argv "$script_path" "$marker" "value with spaces"

    record_assert assert_equals "ok:value with spaces" "$(cat "$marker")" "safe_exec_argv executes argv command successfully"
    rm -rf "$tmp_dir"
}

test_safe_exec_argv_retries() {
    track_coverage "safe_exec_argv"
    local tmp_dir counter script_path status count
    tmp_dir="$(mktemp -d)"
    counter="$tmp_dir/count.txt"
    script_path="$tmp_dir/fail.sh"
    write_counter_script "$script_path"

    load_error_handling
    status=0
    SAFE_EXEC_RETRIES=3 SAFE_EXEC_DELAY=0 safe_exec_argv "$script_path" "$counter" >/dev/null 2>&1 || status=$?
    count="$(cat "$counter" 2>/dev/null || echo 0)"

    record_assert assert_equals "1" "$status" "safe_exec_argv returns failure after retries"
    record_assert assert_equals "3" "$count" "safe_exec_argv retries correct number of times"
    rm -rf "$tmp_dir"
}

test_safe_exec_argv_empty_command() {
    track_coverage "safe_exec_argv"
    local status
    load_error_handling
    status=0
    SAFE_EXEC_RETRIES=1 SAFE_EXEC_DELAY=0 safe_exec_argv "" 2>/dev/null || status=$?

    record_assert assert_equals "1" "$status" "safe_exec_argv rejects empty command"
}

test_safe_exec_argv_preserves_inert_arguments() {
    track_coverage "safe_exec_argv"
    local tmp_dir helper output pwned_semicolon pwned_backtick pwned_subst
    tmp_dir="$(mktemp -d)"
    helper="$tmp_dir/argv-dump.sh"
    output="$tmp_dir/output.txt"
    pwned_semicolon="/tmp/pwned-$$"
    pwned_backtick="/tmp/pwned-backtick-$$"
    pwned_subst="/tmp/pwned-subst-$$"
    rm -f "$pwned_semicolon" "$pwned_backtick" "$pwned_subst"

    cat > "$helper" <<'SCRIPT'
#!/usr/bin/env bash
output_file="$1"
shift
{
    printf 'count=%s\n' "$#"
    printf 'second=%s\n' "$2"
    index=1
    for arg in "$@"; do
        printf 'arg%s=%s\n' "$index" "$arg"
        index=$((index + 1))
    done
} > "$output_file"
SCRIPT
    chmod +x "$helper"

    load_error_handling
    SAFE_EXEC_RETRIES=1 SAFE_EXEC_DELAY=0 safe_exec_argv \
        "$helper" \
        "$output" \
        "arg with spaces" \
        "a;touch $pwned_semicolon" \
        "\`touch $pwned_backtick\`" \
        "\$(touch $pwned_subst)" \
        "*"

    local actual
    actual="$(cat "$output")"
    record_assert assert_contains "count=5" "$actual" "safe_exec_argv preserves argument count"
    record_assert assert_contains "second=a;touch $pwned_semicolon" "$actual" "safe_exec_argv passes semicolon argument verbatim"
    record_assert assert_contains "arg1=arg with spaces" "$actual" "safe_exec_argv passes spaced argument verbatim"
    record_assert assert_contains "arg3=\`touch $pwned_backtick\`" "$actual" "safe_exec_argv passes backticks verbatim"
    record_assert assert_contains "arg4=\$(touch $pwned_subst)" "$actual" "safe_exec_argv passes command substitution verbatim"
    record_assert assert_contains "arg5=*" "$actual" "safe_exec_argv passes glob verbatim"
    record_assert assert_file_not_exists "$pwned_semicolon" "semicolon argument did not execute"
    record_assert assert_file_not_exists "$pwned_backtick" "backtick argument did not execute"
    record_assert assert_file_not_exists "$pwned_subst" "command substitution argument did not execute"
    rm -rf "$tmp_dir"
}

test_safe_exec_backoff_argv_retries() {
    track_coverage "safe_exec_backoff_argv"
    local tmp_dir counter script_path status count
    tmp_dir="$(mktemp -d)"
    counter="$tmp_dir/count.txt"
    script_path="$tmp_dir/fail-backoff.sh"
    write_counter_script "$script_path"

    load_error_handling
    status=0
    SAFE_EXEC_RETRIES=3 SAFE_EXEC_DELAY=0 safe_exec_backoff_argv "$script_path" "$counter" >/dev/null 2>&1 || status=$?
    count="$(cat "$counter" 2>/dev/null || echo 0)"

    record_assert assert_equals "1" "$status" "safe_exec_backoff_argv returns failure after retries"
    record_assert assert_equals "3" "$count" "safe_exec_backoff_argv retries correct number of times"
    rm -rf "$tmp_dir"
}

test_safe_exec_shell_trusted_pipeline() {
    track_coverage "safe_exec_shell_trusted"
    local output
    load_error_handling
    output="$(safe_exec_shell_trusted "printf '%s\n' alpha beta | grep beta")"

    record_assert assert_equals "beta" "$output" "safe_exec_shell_trusted executes literal pipeline"
}

test_safe_exec_legacy_warns_and_runs() {
    track_coverage "safe_exec"
    local tmp_dir stderr_file output warning
    tmp_dir="$(mktemp -d)"
    stderr_file="$tmp_dir/stderr.txt"

    load_error_handling
    # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
    log_warn() { echo "[WARN] $*" >&2; }
    output="$(safe_exec "printf legacy" 1 0 2>"$stderr_file")"
    warning="$(cat "$stderr_file")"

    record_assert assert_equals "legacy" "$output" "legacy safe_exec still executes trusted string"
    record_assert assert_contains "deprecated" "$warning" "legacy safe_exec emits deprecation warning"
    record_assert assert_contains "safe_exec_argv" "$warning" "legacy safe_exec warning directs to argv API"
    rm -rf "$tmp_dir"
}

coverage_expect 7
test_safe_exec_argv_success
test_safe_exec_argv_retries
test_safe_exec_argv_empty_command
test_safe_exec_argv_preserves_inert_arguments
test_safe_exec_backoff_argv_retries
test_safe_exec_shell_trusted_pipeline
test_safe_exec_legacy_warns_and_runs

generate_coverage_report

exit "$failures"
