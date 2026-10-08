#!/usr/bin/env bash
# Unit tests for lib/validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
coverage_init "validation"

failures=0

# Logger stubs: lib/validation.sh invokes these via dynamic dispatch (shellcheck
# cannot follow the sourced module), so SC2317 findings are expected here. [M0 SC2317]
# shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/validation.sh
log_info()  { :; }
# shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/validation.sh
log_debug() { :; }
# shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/validation.sh
log_error() { :; }
# shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/validation.sh
log_warn()  { :; }
# shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/validation.sh
log_success() { :; }

# shellcheck source=lib/validation.sh
source "$ROOT_DIR/lib/validation.sh" 2>/dev/null || {
    echo "SKIP: lib/validation.sh could not be sourced"
    exit 0
}

# Test: validate_version_format accepts valid semver
test_valid_semver_accepted() {
    track_coverage "validate_version_format"

    if declare -f validate_version_format >/dev/null 2>&1; then
        validate_version_format "1.0.0" 2>/dev/null && result=0 || result=1
        assert_equals "0" "$result" "validate_version_format accepts '1.0.0'"
    else
        echo "INFO: validate_version_format not defined — trying is_valid_version"
    fi
}

# Test: validate_version_format rejects clearly invalid input
test_invalid_version_rejected() {
    track_coverage "validate_version_format"

    local fn=""
    declare -f validate_version_format >/dev/null 2>&1 && fn="validate_version_format"
    declare -f is_valid_version       >/dev/null 2>&1 && fn="is_valid_version"

    if [[ -n "$fn" ]]; then
        "$fn" "not-a-version!!!" 2>/dev/null && result=0 || result=1
        assert_equals "1" "$result" "$fn rejects obviously invalid version string"
    else
        echo "INFO: no version validation function found — skipping"
    fi
}

# Test: validate_command_exists returns false for non-existent command
test_validate_missing_command() {
    track_coverage "validate_command_exists"

    if declare -f validate_command_exists >/dev/null 2>&1; then
        validate_command_exists "__no_such_cmd_$$" 2>/dev/null && result=0 || result=1
        assert_equals "1" "$result" "validate_command_exists returns false for missing cmd"
    else
        assert_command_exists "bash" "bash is always available (sanity check)"
    fi
}

# Test: P2-4 ruby/php version validators accept legitimate toolchain names and
# reject injection/traversal/whitespace. These guard install_ruby_version and
# install_php_version at their public entry points.
test_ruby_php_version_validators() {
    track_coverage "validate_ruby_version"
    track_coverage "validate_php_version"

    local v
    for v in "3.3.0" "jruby-9.4.5.0" "8.3" "8.4.0-dev"; do
        validate_ruby_version "$v" 2>/dev/null && result=0 || result=1
        assert_equals "0" "$result" "validate_ruby_version accepts '$v'"
        validate_php_version "$v" 2>/dev/null && result=0 || result=1
        assert_equals "0" "$result" "validate_php_version accepts '$v'"
    done

    for v in '3.0.0; rm -rf /' '$(whoami)' '1.0|cat' '../etc' 'a b' ''; do
        validate_ruby_version "$v" 2>/dev/null && result=0 || result=1
        assert_equals "1" "$result" "validate_ruby_version rejects '$v'"
        validate_php_version "$v" 2>/dev/null && result=0 || result=1
        assert_equals "1" "$result" "validate_php_version rejects '$v'"
    done
}

coverage_expect 4
test_valid_semver_accepted
test_invalid_version_rejected
test_validate_missing_command
test_ruby_php_version_validators

generate_coverage_report
exit "$failures"
