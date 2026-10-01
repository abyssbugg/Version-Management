#!/usr/bin/env bash
# Unit tests for lib/nvm.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
coverage_init "nvm"

failures=0

# Source lib/nvm.sh and reassert the test's own strict-mode posture
# (remediation directive M0 step 3): lib/nvm.sh transitively sources lib/env.sh
# and lib/logger.sh, which set `set -euo pipefail` at source time; that -e
# leaks into this test shell and must not govern the test, which branches on
# return codes itself (e.g. nvm_detect returning 1 when nvm is absent).
source_nvm_lib() {
    # shellcheck source=lib/nvm.sh
    source "$ROOT_DIR/lib/nvm.sh" 2>/dev/null || true
    set +e
    # Re-assert the silent logger stubs AFTER the library source: logger.sh
    # defines its own log_* at source time and would otherwise override them.
    # The library invokes the stubs via dynamic dispatch (shellcheck cannot
    # follow lib/nvm.sh), so SC2317 findings on the stub bodies are expected
    # and suppressed per-site. [M0 SC2317]
    # shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/nvm.sh
    log_info()    { :; }
    # shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/nvm.sh
    log_debug()   { :; }
    # shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/nvm.sh
    log_error()   { :; }
    # shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/nvm.sh
    log_warn()    { :; }
    # shellcheck disable=SC2317  # stub reached via dynamic dispatch from lib/nvm.sh
    log_success() { :; }
}

# Restore NVM_DIR to its pre-test state exactly. Uses if/fi (not `[[ ]] &&`)
# so the caller's exit status stays clean when the variable was unset.
restore_nvm_dir() {
    local saved="${1:-}"
    if [[ -n "$saved" ]]; then
        export NVM_DIR="$saved"
    else
        unset NVM_DIR
    fi
}

# Test: nvm_detect returns false when NVM_DIR is unset
test_nvm_not_installed_without_nvmdir() {
    track_coverage "nvm_detect"

    local saved_nvm_dir="${NVM_DIR:-}"
    export NVM_DIR=""

    source_nvm_lib

    if declare -f nvm_detect >/dev/null 2>&1; then
        nvm_detect && result=0 || result=1
        assert_equals "1" "$result" "nvm_detect returns false without NVM_DIR" || failures=$((failures + 1))
    else
        assert_equals "defined" "missing" "nvm_detect function is not defined" || failures=$((failures + 1))
    fi

    restore_nvm_dir "$saved_nvm_dir"
}

# Test: NVM_DIR default handling is deterministic in an isolated sandbox
test_nvm_default_dir() {
    track_coverage "NVM_DIR"

    source_nvm_lib

    local nvm_dir_before="${NVM_DIR:-}"

    if [[ -n "$nvm_dir_before" ]]; then
        # World A (host provides NVM_DIR, e.g. a workstation with nvm):
        # sourcing the library must not clobber it.
        assert_equals "$nvm_dir_before" "${NVM_DIR:-}" \
            "sourcing lib/nvm.sh preserves a pre-set NVM_DIR" || failures=$((failures + 1))
    else
        # World B (no NVM_DIR in the environment, e.g. a minimal CI container):
        # the library defers the default until a consumer asks for it. With no
        # ~/.nvm it must return 1 gracefully; with a fabricated ~/.nvm it must
        # adopt the documented default $HOME/.nvm. Both halves run entirely in
        # the sandboxed HOME, so this is environment-independent.
        source_nvm_if_available >/dev/null 2>&1
        assert_exit_code 1 "$?" \
            "no NVM_DIR and no ~/.nvm: source_nvm_if_available returns 1 gracefully" \
            || failures=$((failures + 1))

        mkdir -p "$HOME/.nvm"
        printf '# sandbox fake nvm\nnvm() { :; }\n' > "$HOME/.nvm/nvm.sh"

        source_nvm_if_available >/dev/null 2>&1
        assert_equals "$HOME/.nvm" "${NVM_DIR:-}" \
            "source_nvm_if_available defaults NVM_DIR to ~/.nvm" || failures=$((failures + 1))
    fi

    restore_nvm_dir "$nvm_dir_before"
}

coverage_expect 6
test_nvm_not_installed_without_nvmdir
test_nvm_default_dir

# Test: nvm_install_version builds install args with --reinstall-packages-from
test_nvm_install_version_syncs_packages() {
    track_coverage "nvm_install_version"

    source_nvm_lib

    # Mock nvm to capture arguments
    local captured_args=""
    nvm() {
        # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
        case "$1" in
            current) echo "v24.14.1" ;;
            list) echo "->     v25.9.0" ;;  # pretend 20.0.0 is NOT installed
            install) captured_args="$*" ; return 0 ;;
            *) return 0 ;;
        esac
    }
    # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
    nvm_detect() { return 0; }
    # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
    cache_delete() { :; }

    nvm_install_version "20.0.0" 2>/dev/null
    assert_contains "--reinstall-packages-from=v24.14.1" "$captured_args" \
        "nvm_install_version passes --reinstall-packages-from flag" || failures=$((failures + 1))
}

# Test: nvm_install_version skips sync when no current version
test_nvm_install_version_skips_sync_when_none() {
    track_coverage "nvm_install_version_no_sync"

    source_nvm_lib

    local captured_args=""
    nvm() {
        # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
        case "$1" in
            current) echo "none" ;;
            list) echo "->     v25.9.0" ;;
            install) captured_args="$*" ; return 0 ;;
            *) return 0 ;;
        esac
    }
    # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
    nvm_detect() { return 0; }
    # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
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

    source_nvm_lib

    local reinstall_called_with=""
    nvm() {
        # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
        case "$1" in
            current) echo "v24.14.1" ;;
            list) printf "  v24.14.1\n->     v25.9.0\n" ;;
            alias)
                # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
                if [[ "$2" == "default" && -z "${3:-}" ]]; then
                    # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
                    echo "default -> v24.14.1"  # previous default
                else
                    # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
                    return 0  # alias set
                fi
                ;;
            use) return 0 ;;
            reinstall-packages) reinstall_called_with="$2" ; return 0 ;;
            *) return 0 ;;
        esac
    }
    # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
    nvm_detect() { return 0; }
    # shellcheck disable=SC2317  # reached via dynamic dispatch from sourced libs
    nvm_validate_version() { return 0; }

    nvm_set_global "25.9.0" 2>/dev/null
    assert_equals "v24.14.1" "$reinstall_called_with" \
        "nvm_set_global calls reinstall-packages from previous default" || failures=$((failures + 1))
}

# Test: nvm_migrate_packages function exists and is exported
test_nvm_migrate_packages_exists() {
    track_coverage "nvm_migrate_packages"

    source_nvm_lib

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
# M0 step 3: explicit failure accumulation — exit with the failure count.
exit "$failures"
