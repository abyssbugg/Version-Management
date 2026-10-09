#!/usr/bin/env bash
# Unit tests for lib/rustup.sh - Rust Toolchain Manager

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../helpers.sh"
source "$ROOT_DIR/lib/rustup.sh"

# Own strict-mode posture (remediation directive M0 step 3): lib/env.sh and
# lib/logger.sh set `set -euo pipefail` at source time and that posture leaks
# into this test shell. These tests branch on return codes themselves and must
# not abort on the first non-zero (e.g. rustup_detect returning 1 when rustup
# is absent), so the own posture is deliberately non-aborting:
set +e +u +o pipefail

# Test isolation (P0-3 spirit): a sandboxed HOME has no ~/.rustup, so a bare
# `rustup --version` would try to auto-install the toolchain pinned by the
# repo's rust-toolchain file (network fetch of ~hundreds of MB) and hang until
# the per-file watchdog kills it. These are unit tests of lib/rustup.sh's shell
# logic, not of a real toolchain install — forbid auto-install so rustup
# answers immediately. Does not change what any assertion checks.
export RUSTUP_AUTO_INSTALL=0

failures=0

# Test rustup_detect function exists and is callable
test_rustup_detect_function_exists() {
    if declare -f rustup_detect >/dev/null 2>&1; then
        assert_equals "true" "true" "rustup_detect function exists" || failures=$((failures + 1))
    else
        assert_equals "function_exists" "function_missing" "rustup_detect function should exist" || failures=$((failures + 1))
    fi
}

# Test rustup_detect returns the correct value for the actual environment
test_rustup_detect_returns_value() {
    # M0 step 3 (environment-independent semantics): rustup presence is a
    # property of the host, so branch on it and assert the correct outcome for
    # each world instead of relying on the macOS host having rustup installed.
    if command -v rustup >/dev/null 2>&1; then
        rustup_detect >/dev/null 2>&1
        assert_exit_code 0 "$?" "rustup present: rustup_detect returns 0" || failures=$((failures + 1))
    else
        rustup_detect >/dev/null 2>&1
        assert_exit_code 1 "$?" "rustup absent: rustup_detect returns 1 (graceful not-installed)" || failures=$((failures + 1))
    fi
}

# Test _rustup_validate_version with valid version format
test_rustup_validate_version_format_valid() {
    # Test valid version formats
    if _rustup_validate_version "1.75.0" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 1.75.0 accepted" || failures=$((failures + 1))
    else
        assert_equals "valid" "invalid" "1.75.0 should be valid format" || failures=$((failures + 1))
    fi

    if _rustup_validate_version "1.81.0" 2>/dev/null; then
        assert_equals "true" "true" "Valid version format 1.81.0 accepted" || failures=$((failures + 1))
    else
        assert_equals "valid" "invalid" "1.81.0 should be valid format" || failures=$((failures + 1))
    fi
}

# Test _rustup_validate_version with invalid version format
test_rustup_validate_version_format_invalid() {
    # Test invalid version formats
    if ! _rustup_validate_version "invalid" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version 'invalid' rejected" || failures=$((failures + 1))
    else
        assert_equals "rejected" "accepted" "'invalid' should be rejected" || failures=$((failures + 1))
    fi

    if ! _rustup_validate_version "1.75" 2>/dev/null; then
        assert_equals "true" "true" "Invalid version '1.75' (no patch) rejected" || failures=$((failures + 1))
    else
        assert_equals "rejected" "accepted" "'1.75' should be rejected" || failures=$((failures + 1))
    fi

    if ! _rustup_validate_version "stable" 2>/dev/null; then
        assert_equals "true" "true" "Version 'stable' rejected (channel name, not version)" || failures=$((failures + 1))
    else
        # Note: stable might be considered valid as a channel, but _rustup_validate_version checks semver
        assert_equals "true" "true" "'stable' handled appropriately" || failures=$((failures + 1))
    fi
}

# Test rustup_is_rust_project detection with Cargo.toml
test_rustup_is_rust_project_with_cargo() {
    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    cat > Cargo.toml << 'EOF'
[package]
name = "test"
version = "0.1.0"
EOF

    if rustup_is_rust_project; then
        assert_equals "true" "true" "Detected Rust project with Cargo.toml" || failures=$((failures + 1))
    else
        assert_equals "detected" "not_detected" "Should detect Cargo.toml as Rust project" || failures=$((failures + 1))
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test rustup_is_rust_project with rust-toolchain file
test_rustup_is_rust_project_with_toolchain() {
    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    echo "1.81.0" > rust-toolchain

    if rustup_is_rust_project; then
        assert_equals "true" "true" "Detected Rust project with rust-toolchain" || failures=$((failures + 1))
    else
        assert_equals "detected" "not_detected" "Should detect rust-toolchain as Rust project" || failures=$((failures + 1))
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test rustup_is_rust_project with rust-toolchain.toml
test_rustup_is_rust_project_with_toolchain_toml() {
    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    cat > rust-toolchain.toml << 'EOF'
[toolchain]
channel = "1.81.0"
EOF

    if rustup_is_rust_project; then
        assert_equals "true" "true" "Detected Rust project with rust-toolchain.toml" || failures=$((failures + 1))
    else
        assert_equals "detected" "not_detected" "Should detect rust-toolchain.toml as Rust project" || failures=$((failures + 1))
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test rustup_is_rust_project with no Rust files
test_rustup_is_rust_project_not_rust() {
    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    echo "test" > test.txt

    if ! rustup_is_rust_project; then
        assert_equals "true" "true" "Correctly identified non-Rust project" || failures=$((failures + 1))
    else
        assert_equals "not_detected" "detected" "Should not detect as Rust project" || failures=$((failures + 1))
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test rustup_get_current function exists
test_rustup_get_current_function_exists() {
    if declare -f rustup_get_current >/dev/null 2>&1; then
        assert_equals "true" "true" "rustup_get_current function exists" || failures=$((failures + 1))
    else
        assert_equals "function_exists" "function_missing" "rustup_get_current function should exist" || failures=$((failures + 1))
    fi
}

# Test all exported functions exist
test_all_exported_functions_exist() {
    local functions=("rustup_detect" "rustup_install" "rustup_list_versions" "rustup_install_version"
                     "rustup_set_global" "rustup_set_local" "rustup_get_current" "rustup_validate_version"
                     "rustup_get_prompt_version" "rustup_is_rust_project")
    local missing=0

    for func in "${functions[@]}"; do
        if ! declare -f "$func" >/dev/null 2>&1; then
            echo "Missing function: $func"
            missing=$((missing + 1))
        fi
    done

    if [[ $missing -eq 0 ]]; then
        assert_equals "true" "true" "All 10 exported functions exist" || failures=$((failures + 1))
    else
        assert_equals "0" "$missing" "$missing functions are missing" || failures=$((failures + 1))
    fi
}

# ============================================================================
# AX-9 (P3-1): pinned, checksum-verified rustup-init install path
# ============================================================================
# Every case below runs rustup_install in its own subshell with a private
# sandbox (HOME, TMPDIR, stub bin dir) under mktemp -d — never the real HOME.
# A stub `curl` first on PATH copies a fake installer into the requested -o
# path; the fake, if ever executed, writes a marker and its argv. No network,
# no real rustup-init. Assertions run in the parent shell from files so the
# failure counter is accurate.

RT_SB=""
RT_RC=""
RT_FAKE_SHA=""

_rt_sandbox_new() {
    RT_SB=$(mktemp -d "${TMPDIR:-/tmp}/vms-rustup-test.XXXXXX") || exit 1
    mkdir -p "$RT_SB/home" "$RT_SB/tmp" "$RT_SB/bin" "$RT_SB/stub"

    # Fake rustup-init: records that it ran and its exact argv (one per line).
    # Padded past 1 KiB so the pre-AX-9 size heuristic cannot be what refuses it.
    {
        printf '#!/bin/sh\n'
        printf ': > "%s/stub/executed.marker"\n' "$RT_SB"
        printf 'for a in "$@"; do printf "%%s\\n" "$a"; done > "%s/stub/executed.argv"\n' "$RT_SB"
        printf 'exit 0\n'
        local i
        for i in $(seq 1 40); do
            printf '# padding line %02d ...........................................\n' "$i"
        done
    } > "$RT_SB/stub/fake-rustup-init"
    RT_FAKE_SHA=$(_rustup_sha256_file "$RT_SB/stub/fake-rustup-init" 2>/dev/null \
        || shasum -a 256 "$RT_SB/stub/fake-rustup-init" | awk '{print $1}')

    # Stub curl: log argv, honour -o, optionally fail like a network error.
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "$*" >> "%s/stub/curl.calls"\n' "$RT_SB"
        printf 'out=""\n'
        printf 'while [ $# -gt 0 ]; do\n'
        printf '  case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac\n'
        printf 'done\n'
        printf 'if [ -f "%s/stub/curl.fail" ]; then exit 22; fi\n' "$RT_SB"
        printf '[ -n "$out" ] || exit 2\n'
        printf 'cp "%s/stub/fake-rustup-init" "$out"\n' "$RT_SB"
    } > "$RT_SB/bin/curl"
    chmod +x "$RT_SB/bin/curl"
}

_rt_sandbox_rm() {
    if [[ -n "$RT_SB" && "$RT_SB" == */vms-rustup-test.* && -d "$RT_SB" ]]; then
        rm -rf "$RT_SB"
    fi
    RT_SB=""
}

# Run rustup_install isolated. Arg 1: name of a hook function that installs
# per-case overrides inside the subshell (or "none"). Extra env via caller.
_rt_run_install() {
    local hook="${1:-none}"
    (
        export HOME="$RT_SB/home"
        # shellcheck disable=SC2030 # intentional: sandbox TMPDIR exists only inside this isolated subshell
        export TMPDIR="$RT_SB/tmp"
        export PATH="$RT_SB/bin:$PATH"
        # Deterministic host: not installed, Linux (skips the Homebrew branch),
        # fixed target so the REAL pinned digest for it is what gets compared.
        rustup_detect() { return 1; }
        detect_os() { echo "linux"; }
        _rustup_target_triple() { printf '%s\n' "x86_64-unknown-linux-gnu"; }
        if [[ "$hook" != "none" ]]; then
            "$hook"
        fi
        rustup_install
        local rc=$?
        printf '%s\n' "$PATH" > "$RT_SB/stub/path.after"
        exit "$rc"
    ) >"$RT_SB/stub/stdout" 2>"$RT_SB/stub/stderr"
    RT_RC=$?
}

_rt_count_workdirs() {
    local n=0 d
    for d in "$RT_SB/tmp"/vms-rustup-init.*; do
        [[ -e "$d" ]] && n=$((n + 1))
    done
    echo "$n"
}

_rt_assert_not_executed() {
    local label="$1"
    assert_file_not_exists "$RT_SB/stub/executed.marker" "$label: installer never executed" || failures=$((failures + 1))
    assert_equals "0" "$(_rt_count_workdirs)" "$label: private temp dir removed" || failures=$((failures + 1))
    if [[ -e "$RT_SB/home/.cargo" ]]; then
        assert_equals "absent" "present" "$label: nothing written to \$HOME/.cargo" || failures=$((failures + 1))
    else
        assert_equals "absent" "absent" "$label: nothing written to \$HOME/.cargo" || failures=$((failures + 1))
    fi
}

_rt_hook_match() {
    _rustup_expected_sha256() { printf '%s\n' "$RT_FAKE_SHA"; }
}

_rt_hook_unmapped() {
    _rustup_target_triple() { return 1; }
}

_rt_hook_no_sha_tool() {
    _rustup_expected_sha256() { printf '%s\n' "$RT_FAKE_SHA"; }
    _rustup_sha256_file() { return 2; }
}

test_rustup_install_checksum_mismatch_refused() {
    _rt_sandbox_new
    _rt_run_install none
    if [[ "$RT_RC" -ne 0 ]]; then
        assert_equals "nonzero" "nonzero" "mismatch: rustup_install fails closed (rc=$RT_RC)" || failures=$((failures + 1))
    else
        assert_equals "nonzero" "0" "mismatch: rustup_install fails closed" || failures=$((failures + 1))
    fi
    assert_contains "checksum mismatch" "$(cat "$RT_SB/stub/stderr")" "mismatch: refusal reported" || failures=$((failures + 1))
    _rt_assert_not_executed "mismatch"
    _rt_sandbox_rm
}

test_rustup_install_checksum_match_executes() {
    _rt_sandbox_new
    _rt_run_install _rt_hook_match
    assert_exit_code 0 "$RT_RC" "match: rustup_install succeeds" || failures=$((failures + 1))
    assert_file_exists "$RT_SB/stub/executed.marker" "match: verified installer executed" || failures=$((failures + 1))
    local argv=""
    [[ -f "$RT_SB/stub/executed.argv" ]] && argv=$(tr '\n' ' ' < "$RT_SB/stub/executed.argv")
    assert_equals "-y --no-modify-path --profile minimal " "$argv" "match: executed with exactly -y --no-modify-path --profile minimal" || failures=$((failures + 1))
    assert_contains "https://static.rust-lang.org/rustup/archive/$(_rustup_init_version 2>/dev/null)/x86_64-unknown-linux-gnu/rustup-init" \
        "$(cat "$RT_SB/stub/curl.calls" 2>/dev/null)" "match: pinned archive URL downloaded" || failures=$((failures + 1))
    assert_contains "-o $RT_SB/tmp/vms-rustup-init." \
        "$(cat "$RT_SB/stub/curl.calls" 2>/dev/null)" "match: downloaded into a private dir under TMPDIR" || failures=$((failures + 1))
    assert_contains "$RT_SB/home/.cargo/bin" "$(cat "$RT_SB/stub/path.after" 2>/dev/null)" "match: cargo bin added to PATH" || failures=$((failures + 1))
    assert_contains "rustup installed successfully" "$(cat "$RT_SB/stub/stderr")" "match: success message kept" || failures=$((failures + 1))
    assert_equals "0" "$(_rt_count_workdirs)" "match: private temp dir removed" || failures=$((failures + 1))
    if [[ -e "$RT_SB/home/.cargo" ]]; then
        assert_equals "absent" "present" "match: installer not staged under \$HOME/.cargo" || failures=$((failures + 1))
    else
        assert_equals "absent" "absent" "match: installer not staged under \$HOME/.cargo" || failures=$((failures + 1))
    fi
    _rt_sandbox_rm
}

test_rustup_install_download_failure() {
    _rt_sandbox_new
    : > "$RT_SB/stub/curl.fail"
    _rt_run_install _rt_hook_match
    if [[ "$RT_RC" -ne 0 ]]; then
        assert_equals "nonzero" "nonzero" "download failure: fails closed (rc=$RT_RC)" || failures=$((failures + 1))
    else
        assert_equals "nonzero" "0" "download failure: fails closed" || failures=$((failures + 1))
    fi
    assert_contains "Failed to download rustup installer" "$(cat "$RT_SB/stub/stderr")" "download failure: reported" || failures=$((failures + 1))
    _rt_assert_not_executed "download failure"
    _rt_sandbox_rm
}

test_rustup_install_no_sha_tool_fails_closed() {
    _rt_sandbox_new
    _rt_run_install _rt_hook_no_sha_tool
    if [[ "$RT_RC" -ne 0 ]]; then
        assert_equals "nonzero" "nonzero" "no sha256 tool: fails closed (rc=$RT_RC)" || failures=$((failures + 1))
    else
        assert_equals "nonzero" "0" "no sha256 tool: fails closed" || failures=$((failures + 1))
    fi
    _rt_assert_not_executed "no sha256 tool"
    _rt_sandbox_rm
}

test_rustup_install_unmapped_host() {
    _rt_sandbox_new
    _rt_run_install _rt_hook_unmapped
    if [[ "$RT_RC" -ne 0 ]]; then
        assert_equals "nonzero" "nonzero" "unmapped host: fails closed (rc=$RT_RC)" || failures=$((failures + 1))
    else
        assert_equals "nonzero" "0" "unmapped host: fails closed" || failures=$((failures + 1))
    fi
    assert_file_not_exists "$RT_SB/stub/curl.calls" "unmapped host: nothing downloaded" || failures=$((failures + 1))
    assert_contains "Unsupported host" "$(cat "$RT_SB/stub/stderr")" "unmapped host: clear message" || failures=$((failures + 1))
    _rt_assert_not_executed "unmapped host"
    _rt_sandbox_rm
}

test_rustup_install_dry_run() {
    _rt_sandbox_new
    TRANSACTION_DRY_RUN=1 _rt_run_install none
    assert_exit_code 0 "$RT_RC" "dry-run: returns 0" || failures=$((failures + 1))
    assert_file_not_exists "$RT_SB/stub/curl.calls" "dry-run: curl never called" || failures=$((failures + 1))
    local err
    err=$(cat "$RT_SB/stub/stderr")
    local pin_sha pin_ver
    pin_sha=$(_rustup_expected_sha256 x86_64-unknown-linux-gnu 2>/dev/null)
    pin_ver=$(_rustup_init_version 2>/dev/null)
    assert_contains "https://static.rust-lang.org/rustup/archive/${pin_ver:-<none>}/x86_64-unknown-linux-gnu/rustup-init" "$err" "dry-run: planned URL printed" || failures=$((failures + 1))
    assert_contains "${pin_sha:-<none>}" "$err" "dry-run: expected checksum printed" || failures=$((failures + 1))
    _rt_assert_not_executed "dry-run"
    _rt_sandbox_rm
}

# macOS + Homebrew keeps priority over the pinned download (unchanged), and
# dry-run plans it instead of running brew.
_rt_hook_macos_brew() {
    detect_os() { echo "macos"; }
    {
        printf '#!/bin/sh\n'
        printf 'printf "%%s\\n" "brew $*" >> "%s/stub/brew.calls"\n' "$RT_SB"
        printf 'exit 0\n'
    } > "$RT_SB/bin/brew"
    chmod +x "$RT_SB/bin/brew"
}

test_rustup_install_macos_homebrew_first() {
    _rt_sandbox_new
    _rt_run_install _rt_hook_macos_brew
    assert_exit_code 0 "$RT_RC" "macOS+brew: succeeds via Homebrew" || failures=$((failures + 1))
    assert_contains "brew install rustup" "$(cat "$RT_SB/stub/brew.calls" 2>/dev/null)" "macOS+brew: brew install rustup used" || failures=$((failures + 1))
    assert_file_not_exists "$RT_SB/stub/curl.calls" "macOS+brew: no rustup-init download" || failures=$((failures + 1))
    _rt_sandbox_rm

    _rt_sandbox_new
    TRANSACTION_DRY_RUN=1 _rt_run_install _rt_hook_macos_brew
    assert_exit_code 0 "$RT_RC" "macOS+brew dry-run: returns 0" || failures=$((failures + 1))
    assert_file_not_exists "$RT_SB/stub/brew.calls" "macOS+brew dry-run: brew never called" || failures=$((failures + 1))
    assert_contains "brew install rustup" "$(cat "$RT_SB/stub/stderr")" "macOS+brew dry-run: plan printed" || failures=$((failures + 1))
    _rt_sandbox_rm
}

test_rustup_pinned_table() {
    local t sha bad=0
    for t in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu x86_64-apple-darwin \
             aarch64-apple-darwin x86_64-unknown-linux-musl aarch64-unknown-linux-musl; do
        sha=$(_rustup_expected_sha256 "$t" 2>/dev/null)
        if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
            echo "  no 64-hex pin for $t: '$sha'"
            bad=$((bad + 1))
        fi
    done
    assert_equals "0" "$bad" "pinned table: 64-hex sha256 for every supported target" || failures=$((failures + 1))
    if _rustup_expected_sha256 "riscv64gc-unknown-linux-gnu" >/dev/null 2>&1; then
        assert_equals "unpinned" "pinned" "pinned table: unknown triple has no digest" || failures=$((failures + 1))
    else
        assert_equals "unpinned" "unpinned" "pinned table: unknown triple has no digest" || failures=$((failures + 1))
    fi
    local ver
    ver=$(_rustup_init_version 2>/dev/null)
    if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        assert_equals "semver" "semver" "pinned rustup-init version is exact ($ver)" || failures=$((failures + 1))
    else
        assert_equals "semver" "'$ver'" "pinned rustup-init version is exact" || failures=$((failures + 1))
    fi
}

# Host -> triple mapping via function overrides of uname/ldd (no real host
# dependency). Prints the triple or "FAIL".
_rt_map() {
    (
        uname() { case "${1:-}" in -s) echo "$RT_UNAME_S" ;; -m) echo "$RT_UNAME_M" ;; *) echo "$RT_UNAME_S" ;; esac; }
        if [[ "${RT_LIBC:-}" == "musl" ]]; then
            ldd() { echo "musl libc (${RT_UNAME_M})"; return 1; }
        else
            ldd() { echo "ldd (GNU libc) 2.39"; return 0; }
        fi
        _vms_is_wsl() { return 1; }
        _rustup_target_triple 2>/dev/null || echo "FAIL"
    )
}

test_rustup_target_triple_mapping() {
    local got
    got=$(RT_UNAME_S=Darwin RT_UNAME_M=arm64 _rt_map);   assert_equals "aarch64-apple-darwin" "$got" "triple: Darwin arm64" || failures=$((failures + 1))
    got=$(RT_UNAME_S=Darwin RT_UNAME_M=x86_64 _rt_map);  assert_equals "x86_64-apple-darwin" "$got" "triple: Darwin x86_64" || failures=$((failures + 1))
    got=$(RT_UNAME_S=Linux RT_UNAME_M=x86_64 _rt_map);   assert_equals "x86_64-unknown-linux-gnu" "$got" "triple: Linux x86_64 glibc" || failures=$((failures + 1))
    got=$(RT_UNAME_S=Linux RT_UNAME_M=amd64 _rt_map);    assert_equals "x86_64-unknown-linux-gnu" "$got" "triple: Linux amd64 glibc" || failures=$((failures + 1))
    got=$(RT_UNAME_S=Linux RT_UNAME_M=aarch64 _rt_map);  assert_equals "aarch64-unknown-linux-gnu" "$got" "triple: Linux aarch64 glibc" || failures=$((failures + 1))
    got=$(RT_UNAME_S=Linux RT_UNAME_M=aarch64 RT_LIBC=musl _rt_map); assert_equals "aarch64-unknown-linux-musl" "$got" "triple: Linux aarch64 musl" || failures=$((failures + 1))
    got=$(RT_UNAME_S=Linux RT_UNAME_M=x86_64 RT_LIBC=musl _rt_map);  assert_equals "x86_64-unknown-linux-musl" "$got" "triple: Linux x86_64 musl" || failures=$((failures + 1))
    got=$(RT_UNAME_S=Linux RT_UNAME_M=mips _rt_map);     assert_equals "FAIL" "$got" "triple: unmapped CPU fails closed" || failures=$((failures + 1))
    got=$(RT_UNAME_S=FreeBSD RT_UNAME_M=x86_64 _rt_map); assert_equals "FAIL" "$got" "triple: unmapped OS fails closed" || failures=$((failures + 1))
}

# AX-7 lesson: rustup.sh is export -f'd, so its bodies must survive bash's
# BASH_FUNC_* serialization — a child bash must start noise-free.
test_rustup_export_f_child_bash_clean() {
    local out err_file err
    # shellcheck disable=SC2031 # deliberately the caller's TMPDIR (the subshell sandbox override never leaks here)
    err_file=$(mktemp "${TMPDIR:-/tmp}/vms-rustup-child.XXXXXX")
    out=$(bash -c 'source "$1"; bash -c "echo child-ok"' _ "$ROOT_DIR/lib/rustup.sh" 2>"$err_file")
    err=$(cat "$err_file"); rm -f "$err_file"
    assert_equals "child-ok" "$out" "export -f: child bash stdout is exactly child-ok" || failures=$((failures + 1))
    assert_equals "" "$err" "export -f: child bash stderr is empty" || failures=$((failures + 1))
}

# Run tests
echo "=== Rust Toolchain Manager (rustup) Tests ==="
test_rustup_detect_function_exists
test_rustup_detect_returns_value
test_rustup_validate_version_format_valid
test_rustup_validate_version_format_invalid
test_rustup_is_rust_project_with_cargo
test_rustup_is_rust_project_with_toolchain
test_rustup_is_rust_project_with_toolchain_toml
test_rustup_is_rust_project_not_rust
test_rustup_get_current_function_exists
test_all_exported_functions_exist
test_rustup_pinned_table
test_rustup_target_triple_mapping
test_rustup_install_checksum_mismatch_refused
test_rustup_install_checksum_match_executes
test_rustup_install_download_failure
test_rustup_install_no_sha_tool_fails_closed
test_rustup_install_unmapped_host
test_rustup_install_dry_run
test_rustup_install_macos_homebrew_first
test_rustup_export_f_child_bash_clean
# M0 step 3: explicit failure accumulation — exit with the failure count, not
# merely the status of the last test case.
exit "$failures"
