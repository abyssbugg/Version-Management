#!/usr/bin/env bash
# =============================================================================
# Platform Contract Test (remediation directive M5 / finding P1-9, A5-new)
# =============================================================================
# Pins the canonical platform API contract:
#
#   1. lib/env.sh is the CANONICAL implementation of the platform API
#      (detect_os / get_os / get_shell). lib/utils.sh must not carry its own
#      platform code — every name it historically exposed must resolve to a
#      value IDENTICAL to the env.sh canonical (the P1-9 drift finding was
#      utils.sh get_os == "wsl" vs env.sh detect_os == "linux" under WSL).
#
#   2. BINDING DECISION (P1-9): WSL is reported as "wsl", never "linux", by
#      BOTH get_os and detect_os. "wsl" is the more informative value and
#      there is exactly ONE WSL semantic across the platform API. The
#      contract is pinned at unit level by overriding the detection inputs
#      (a PATH-shimmed `uname` plus the VMS_PROC_VERSION override for the
#      /proc/version path) — /proc/version itself is not portable to mock.
#
#   3. get_shell is the login-shell name: basename of $SHELL, default
#      /bin/bash. It returns a slash-free, resolvable shell name.
#
#   4. A5-new regression guard: sourcing any lib/*.sh must not clobber the
#      caller's global SCRIPT_DIR. Each hygiene-passed library sets a private
#      _VMS_<NAME>_DIR derived from BASH_SOURCE and leaves SCRIPT_DIR alone.
# =============================================================================

TEST_FILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TEST_FILE_DIR/../.." && pwd)"

# shellcheck source=tests/helpers.sh
source "$TEST_FILE_DIR/../helpers.sh"

LIB_DIR="$ROOT_DIR/lib"

failures=0
assert() {
    assert_equals "$1" "$2" "$3" || failures=$((failures + 1))
}

# Run `code` in a pristine bash that has sourced only `$lib`.
# Extra args are KEY=VALUE environment overrides for the child.
# Stderr (library logging) is discarded; stdout carries the function value.
_with_lib() {
    local lib="$1" code="$2"
    shift 2
    env "$@" bash -c "source '$lib' >/dev/null 2>&1; $code" 2>/dev/null
}

# =============================================================================
# 1. Host contract: detect_os agrees with an independent platform reading
# =============================================================================

test_host_detect_os_matches_platform() {
    local expected="" kernel
    kernel="$(uname -s)"
    case "$kernel" in
        Darwin*) expected="macos" ;;
        Linux*)
            # Independent WSL reading — must match the lib's binding decision.
            if [[ -f /proc/version ]] && grep -q Microsoft /proc/version 2>/dev/null; then
                expected="wsl"
            else
                expected="linux"
            fi
            ;;
        CYGWIN*|MINGW*|MSYS*) expected="windows" ;;
        *) expected="unknown" ;;
    esac
    local actual
    actual="$(_with_lib "$LIB_DIR/env.sh" "detect_os")"
    assert "$expected" "$actual" "detect_os matches independent host reading ($kernel -> $expected)"
}

# =============================================================================
# 2. ONE semantic: get_os and detect_os agree for the current host
# =============================================================================

test_host_get_os_detect_os_agree() {
    local via_get_os via_detect_os
    via_get_os="$(_with_lib "$LIB_DIR/env.sh" "get_os")"
    via_detect_os="$(_with_lib "$LIB_DIR/env.sh" "detect_os")"
    assert "$via_detect_os" "$via_get_os" \
        "get_os == detect_os on this host (ONE platform semantic, P1-9)"
}

# =============================================================================
# 3. Wrapper equality: utils.sh names return IDENTICAL values to env.sh
#    canonicals when each file is sourced alone (the P1-9 drift finding)
# =============================================================================

test_utils_get_os_matches_env_canonical() {
    local env_val utils_val
    env_val="$(_with_lib "$LIB_DIR/env.sh" "get_os")"
    utils_val="$(_with_lib "$LIB_DIR/utils.sh" "get_os")"
    assert "$env_val" "$utils_val" \
        "utils.sh get_os returns identical value to env.sh canonical get_os"
}

test_utils_detect_os_matches_env_canonical() {
    local env_val utils_val
    env_val="$(_with_lib "$LIB_DIR/env.sh" "detect_os")"
    utils_val="$(_with_lib "$LIB_DIR/utils.sh" "detect_os")"
    assert "$env_val" "$utils_val" \
        "utils.sh exposes detect_os with identical value to env.sh canonical"
}

test_utils_get_shell_matches_env_canonical() {
    local env_val utils_val
    env_val="$(_with_lib "$LIB_DIR/env.sh" "get_shell")"
    utils_val="$(_with_lib "$LIB_DIR/utils.sh" "get_shell")"
    assert "$env_val" "$utils_val" \
        "utils.sh get_shell returns identical value to env.sh canonical get_shell"
}

# =============================================================================
# 4. WSL contract (binding decision, pinned via detection-input overrides)
# =============================================================================

_test_wsl_semantic() {  # $1 = fixture content, $2 = expected value, $3 = label
    local fixture="$1" expected="$2" label="$3"
    local tmpbin fixture_path out
    tmpbin="$(mktemp -d)"
    printf '#!/bin/sh\necho Linux\n' > "$tmpbin/uname"
    chmod +x "$tmpbin/uname"
    fixture_path="$tmpbin/proc_version"
    printf '%s\n' "$fixture" > "$fixture_path"
    for fn_name in get_os detect_os; do
        out="$(PATH="$tmpbin:$PATH" VMS_PROC_VERSION="$fixture_path" \
            _with_lib "$LIB_DIR/env.sh" "$fn_name")"
        assert "$expected" "$out" "WSL contract: env.sh $fn_name -> $expected ($label)"
    done
    rm -rf "$tmpbin"
}

test_wsl_reports_wsl_not_linux() {
    # WSL1/WSL2 both stamp "Microsoft" into /proc/version.
    _test_wsl_semantic \
        "Linux version 5.15.90.1-microsoft-standard-WSL2 (mock@mock) #1 SMP Microsoft" \
        "wsl" "WSL2 /proc/version"
}

test_plain_linux_still_linux() {
    _test_wsl_semantic \
        "Linux version 6.1.0-vanilla (mock@mock) #1 SMP" \
        "linux" "non-WSL /proc/version"
}

# =============================================================================
# 5. get_shell contract: login-shell basename, slash-free and resolvable
# =============================================================================

test_get_shell_contract() {
    local expected_shell out
    expected_shell="$(basename "${SHELL:-/bin/bash}")"
    out="$(_with_lib "$LIB_DIR/env.sh" "get_shell")"
    assert "$expected_shell" "$out" "get_shell is basename(\$SHELL) with /bin/bash default"
    assert "0" "$([[ "$out" != */* ]] && echo 0 || echo 1)" "get_shell returns a basename (no slash)"
    if command -v "$out" >/dev/null 2>&1 || [[ -x "/bin/$out" ]]; then
        assert_equals "resolvable" "resolvable" "get_shell value '$out' resolves to a real shell"
    else
        failures=$((failures + 1))
        assert_equals "resolvable shell" "unresolvable: $out" "get_shell value resolves to a real shell"
    fi
}

# =============================================================================
# 6. A5-new regression guard: sourcing lib/*.sh never clobbers caller
#    SCRIPT_DIR; each hygiene-passed library defines its private dir instead.
#    Entry format: file.sh : private-var (or "-") : expected-dir (lib|root|none)
# =============================================================================

_A5NEW_ENTRIES=(
    "nvm.sh:_VMS_NVM_DIR:lib"
    "validation.sh:_VMS_VALIDATION_DIR:lib"
    "utils.sh:_VMS_UTILS_DIR:lib"
    "env.sh:-:none"
    "fonts.sh:_VMS_FONTS_DIR:root"
    "auto-activate.sh:_VMS_AUTO_ACTIVATE_DIR:lib"
    "error-handling.sh:_VMS_ERROR_HANDLING_DIR:lib"
    "plugins.sh:_VMS_PLUGINS_DIR:lib"
    "pyvm.sh:_VMS_PYVM_DIR:lib"
    "fnm.sh:_VMS_FNM_DIR:lib"
    "jenv.sh:_VMS_JENV_DIR:lib"
    "gvm.sh:_VMS_GVM_DIR:lib"
    "rustup.sh:_VMS_RUSTUP_DIR:lib"
    "phpenv.sh:_VMS_PHPENV_DIR:lib"
)

test_script_dir_hygiene_a5new() {
    local sentinel="/vms-a5new-sentinel/unchanged"
    local entry file pvar where path got_dir got_private expected_dir
    for entry in "${_A5NEW_ENTRIES[@]}"; do
        file="${entry%%:*}"
        where="${entry##*:}"
        pvar="${entry#*:}"; pvar="${pvar%:*}"
        path="$LIB_DIR/$file"

        got_dir="$(SCRIPT_DIR="$sentinel" bash -c \
            "source '$path' >/dev/null 2>&1; printf %s \"\${SCRIPT_DIR:-}\"" 2>/dev/null)"
        assert "$sentinel" "$got_dir" \
            "A5-new: sourcing lib/$file leaves caller SCRIPT_DIR untouched"

        if [[ "$where" == "none" ]]; then
            continue  # env.sh assigns no SCRIPT_DIR at all
        fi
        got_private="$(SCRIPT_DIR="$sentinel" bash -c \
            "source '$path' >/dev/null 2>&1; printf %s \"\${$pvar:-}\"" 2>/dev/null)"
        case "$where" in
            lib)  expected_dir="$LIB_DIR" ;;
            root) expected_dir="$ROOT_DIR" ;;
        esac
        assert "$expected_dir" "$got_private" \
            "A5-new: lib/$file sets private $pvar = $where dir"
    done
}

# =============================================================================
# 7. Root-script wrapper parity (P1-9 remainder): the standalone root
#    executables must expose get_os/get_shell values IDENTICAL to the
#    env.sh canonical — no local duplicate platform detection may survive.
#
#    Both scripts execute top-level code on source (set -euo pipefail,
#    config exports, lib sourcing; main() is guarded by BASH_SOURCE[0] == $0).
#    Per the remediation directive, each probe SOURCES the script inside a
#    disposable child bash under a mktemp -d HOME sandbox — never in this
#    test shell, never without a sandbox. Sourcing defines functions and
#    exports config only (no filesystem mutation); stderr is discarded.
# =============================================================================

_ROOT_SANDBOX_HOME="$(mktemp -d "${TMPDIR:-/tmp}/vms-wrappers-home.XXXXXX")"

_with_root_script() {
    local script="$1" code="$2"
    shift 2
    env HOME="$_ROOT_SANDBOX_HOME" "$@" bash -c \
        "source '$script' >/dev/null 2>&1; $code" 2>/dev/null
}

_ROOT_SCRIPTS=("$ROOT_DIR/version-manager.sh" "$ROOT_DIR/version-advanced.sh")

# WSL seam (same detection-input override as section 4): a PATH-shimmed
# `uname` plus a VMS_PROC_VERSION fixture stamped "Microsoft". The canonical
# answer is "wsl"; the pre-fix duplicate bodies answered "linux" — RED by
# construction against the pre-fix state.
test_root_scripts_get_os_wsl_seam() {
    local tmpbin fixture out script
    tmpbin="$(mktemp -d)"
    printf '#!/bin/sh\necho Linux\n' > "$tmpbin/uname"
    chmod +x "$tmpbin/uname"
    fixture="$tmpbin/proc_version"
    printf 'Linux version 5.15.90.1-microsoft-standard-WSL2 (mock@mock) #1 SMP Microsoft\n' > "$fixture"
    for script in "${_ROOT_SCRIPTS[@]}"; do
        out="$(_with_root_script "$script" "get_os" \
            PATH="$tmpbin:$PATH" VMS_PROC_VERSION="$fixture")"
        assert "wsl" "$out" \
            "P1-9: $(basename "$script") get_os reports wsl under the WSL seam"
    done
    rm -rf "$tmpbin"
}

# Non-WSL seam: the same uname shim with a non-Microsoft fixture must still
# answer "linux" — parity, not drift, is the contract. (Regression guard:
# passes in both pre- and post-fix states; the seam tests above discriminate.)
test_root_scripts_get_os_linux_seam() {
    local tmpbin fixture out script
    tmpbin="$(mktemp -d)"
    printf '#!/bin/sh\necho Linux\n' > "$tmpbin/uname"
    chmod +x "$tmpbin/uname"
    fixture="$tmpbin/proc_version"
    printf 'Linux version 6.1.0-vanilla (mock@mock) #1 SMP\n' > "$fixture"
    for script in "${_ROOT_SCRIPTS[@]}"; do
        out="$(_with_root_script "$script" "get_os" \
            PATH="$tmpbin:$PATH" VMS_PROC_VERSION="$fixture")"
        assert "linux" "$out" \
            "P1-9: $(basename "$script") get_os reports linux for non-WSL Linux"
    done
    rm -rf "$tmpbin"
}

# get_shell parity: SHELL says zsh while the probe runs under bash. The
# canonical get_shell is the login-shell name ("zsh"); the pre-fix
# version-manager.sh body probed the running shell ("bash"), and
# version-advanced.sh exposed no get_shell at all — RED by construction.
test_root_scripts_get_shell_login_shell_parity() {
    local out script
    for script in "${_ROOT_SCRIPTS[@]}"; do
        out="$(_with_root_script "$script" "get_shell" SHELL=/bin/zsh)"
        assert "zsh" "$out" \
            "P1-9: $(basename "$script") get_shell is the login shell (env.sh parity)"
    done
}

# Host parity: each script's get_os equals env.sh's canonical on this host.
# (Non-discriminating on a non-WSL host; kept as a cheap standing guard.)
test_root_scripts_host_get_os_parity() {
    local canonical out script
    canonical="$(_with_lib "$LIB_DIR/env.sh" "get_os")"
    for script in "${_ROOT_SCRIPTS[@]}"; do
        out="$(_with_root_script "$script" "get_os")"
        assert "$canonical" "$out" \
            "P1-9: $(basename "$script") get_os == env.sh canonical on this host"
    done
}

# =============================================================================
# Run
# =============================================================================

# AX-17: get_shell_config (the rc file the managed blocks target) has ONE
# definition — lib/env.sh — and selects zsh/bash/POSIX-fallback files.
test_get_shell_config_canonical() {
    local defs
    defs=$(cd "$ROOT_DIR" && git grep -lE '^[[:space:]]*get_shell_config\(\)' -- '*.sh' ':!tests' 2>/dev/null | tr '\n' ' ')
    assert "lib/env.sh " "$defs" "get_shell_config defined only in lib/env.sh"
    local h
    h=$(mktemp -d "${TMPDIR:-/tmp}/vms-shellcfg.XXXXXX")
    _cfg() { HOME="$h" SHELL="$1" bash -c 'source "$1/logger.sh" >/dev/null 2>&1; source "$1/env.sh" >/dev/null 2>&1; get_shell_config' _ "$LIB_DIR"; }
    assert "$h/.zshrc" "$(_cfg /bin/zsh)" "zsh login shell -> ~/.zshrc"
    assert "$h/.bash_profile" "$(_cfg /bin/bash)" "bash without ~/.bashrc -> ~/.bash_profile"
    : > "$h/.bashrc"
    assert "$h/.bashrc" "$(_cfg /bin/bash)" "bash with ~/.bashrc -> ~/.bashrc"
    assert "$h/.profile" "$(_cfg /usr/local/bin/fish)" "fish falls back to ~/.profile (never a fish config)"
    rm -rf -- "$h"
}

test_host_detect_os_matches_platform
test_host_get_os_detect_os_agree
test_utils_get_os_matches_env_canonical
test_utils_detect_os_matches_env_canonical
test_utils_get_shell_matches_env_canonical
test_wsl_reports_wsl_not_linux
test_plain_linux_still_linux
test_get_shell_contract
test_script_dir_hygiene_a5new
test_root_scripts_get_os_wsl_seam
test_root_scripts_get_os_linux_seam
test_root_scripts_get_shell_login_shell_parity
test_root_scripts_host_get_os_parity
test_get_shell_config_canonical
rm -rf "$_ROOT_SANDBOX_HOME"

if [[ "$failures" -gt 0 ]]; then
    echo "test_platform_contract.sh: $failures contract violation(s)"
    exit 1
fi
exit 0
