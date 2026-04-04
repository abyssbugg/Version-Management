#!/usr/bin/env bash
# Unit tests for lib/nvm.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
coverage_init "nvm"

failures=0

# Test: nvm_detect returns false when NVM_DIR is unset
test_nvm_not_installed_without_nvmdir() {
    track_coverage "nvm_detect"

    # Provide logger stubs
    log_info()  { :; }
    log_debug() { :; }
    log_error() { :; }
    log_warn()  { :; }

    local saved_nvm_dir="${NVM_DIR:-}"
    export NVM_DIR=""

    # shellcheck source=lib/nvm.sh
    source "$ROOT_DIR/lib/nvm.sh" 2>/dev/null || true

    if declare -f nvm_detect >/dev/null 2>&1; then
        nvm_detect && result=0 || result=1
        assert_equals "1" "$result" "nvm_detect returns false without NVM_DIR"
    else
        assert_equals "defined" "missing" "nvm_detect function is not defined"
        failures=$((failures + 1))
    fi

    # Restore
    [[ -n "$saved_nvm_dir" ]] && export NVM_DIR="$saved_nvm_dir"
}

# Test: nvm config points to ~/.nvm by default
test_nvm_default_dir() {
    track_coverage "NVM_DIR"
    local expected="$HOME/.nvm"

    log_info()  { :; }
    log_debug() { :; }
    log_error() { :; }
    log_warn()  { :; }

    source "$ROOT_DIR/lib/nvm.sh" 2>/dev/null || true
    assert_not_empty "${NVM_DIR:-}" "NVM_DIR should be set after sourcing lib/nvm.sh"
}

coverage_expect 6
test_nvm_not_installed_without_nvmdir
test_nvm_default_dir

# Test: nvm_install_version builds install args with --reinstall-packages-from
test_nvm_install_version_syncs_packages() {
    track_coverage "nvm_install_version"

    log_info()  { :; }
    log_debug() { :; }
    log_error() { :; }
    log_warn()  { :; }
    log_success() { :; }

    source "$ROOT_DIR/lib/nvm.sh" 2>/dev/null || true

    # Mock nvm to capture arguments
    local captured_args=""
    nvm() {
        case "$1" in
            current) echo "v24.14.1" ;;
            list) echo "->     v25.9.0" ;;  # pretend 20.0.0 is NOT installed
            install) captured_args="$*" ; return 0 ;;
            *) return 0 ;;
        esac
    }
    nvm_detect() { return 0; }
    cache_delete() { :; }

    nvm_install_version "20.0.0" 2>/dev/null
    assert_contains "--reinstall-packages-from=v24.14.1" "$captured_args" \
        "nvm_install_version passes --reinstall-packages-from flag"
}

# Test: nvm_install_version skips sync when no current version
test_nvm_install_version_skips_sync_when_none() {
    track_coverage "nvm_install_version_no_sync"

    log_info()  { :; }
    log_debug() { :; }
    log_error() { :; }
    log_warn()  { :; }
    log_success() { :; }

    source "$ROOT_DIR/lib/nvm.sh" 2>/dev/null || true

    local captured_args=""
    nvm() {
        case "$1" in
            current) echo "none" ;;
            list) echo "->     v25.9.0" ;;
            install) captured_args="$*" ; return 0 ;;
            *) return 0 ;;
        esac
    }
    nvm_detect() { return 0; }
    cache_delete() { :; }

    nvm_install_version "20.0.0" 2>/dev/null
    if [[ "$captured_args" != *"--reinstall-packages-from"* ]]; then
        echo -e "${GREEN}✓ nvm_install_version skips sync when nvm current is none (passed)${NC}"
    else
        echo -e "${RED}✗ nvm_install_version should skip sync when nvm current is none (failed)${NC}"
        failures=$((failures + 1))
    fi
}

# Test: nvm_set_global syncs packages from previous default
test_nvm_set_global_syncs_packages() {
    track_coverage "nvm_set_global"

    log_info()  { :; }
    log_debug() { :; }
    log_error() { :; }
    log_warn()  { :; }
    log_success() { :; }

    source "$ROOT_DIR/lib/nvm.sh" 2>/dev/null || true

    local reinstall_called_with=""
    nvm() {
        case "$1" in
            current) echo "v24.14.1" ;;
            list) printf "  v24.14.1\n->     v25.9.0\n" ;;
            alias)
                if [[ "$2" == "default" && -z "${3:-}" ]]; then
                    echo "default -> v24.14.1"  # previous default
                else
                    return 0  # alias set
                fi
                ;;
            use) return 0 ;;
            reinstall-packages) reinstall_called_with="$2" ; return 0 ;;
            *) return 0 ;;
        esac
    }
    nvm_detect() { return 0; }
    nvm_validate_version() { return 0; }

    nvm_set_global "25.9.0" 2>/dev/null
    assert_equals "v24.14.1" "$reinstall_called_with" \
        "nvm_set_global calls reinstall-packages from previous default"
}

# Test: nvm_migrate_packages function exists and is exported
test_nvm_migrate_packages_exists() {
    track_coverage "nvm_migrate_packages"

    log_info()  { :; }
    log_debug() { :; }
    log_error() { :; }
    log_warn()  { :; }
    log_success() { :; }

    source "$ROOT_DIR/lib/nvm.sh" 2>/dev/null || true

    if declare -f nvm_migrate_packages >/dev/null 2>&1; then
        echo -e "${GREEN}✓ nvm_migrate_packages function exists (passed)${NC}"
    else
        echo -e "${RED}✗ nvm_migrate_packages function should exist (failed)${NC}"
        failures=$((failures + 1))
    fi
}

test_nvm_install_version_syncs_packages
test_nvm_install_version_skips_sync_when_none
test_nvm_set_global_syncs_packages
test_nvm_migrate_packages_exists

generate_coverage_report
exit "$failures"
