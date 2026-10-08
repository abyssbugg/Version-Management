#!/usr/bin/env bash
# =============================================================================
# P2-7 unit tests: generated Dockerfile templates (version-advanced.sh)
# =============================================================================
# Each generator is executed in a mktemp project dir (the generators write
# the Dockerfile into the CWD) and the generated file is asserted against
# the P2-7 properties from MASTER_AUDIT/ROADMAP 4.7:
#
#   1. multi-stage           — FROM >= 2, "AS builder" present
#   2. non-root USER         — a USER line in the FINAL stage, not root/0
#   3. HEALTHCHECK           — present in the FINAL stage
#   4. artifacts-only copy   — COPY --from=builder in final stage, no
#                              broad "COPY . ." in the final stage
#   5. apt hygiene           — every "apt-get install" line carries
#                              --no-install-recommends (the deliverable
#                              scopes this to the final runtime stage; this
#                              file asserts it globally, which is stricter)
#   6. shell-valid probe     — the HEALTHCHECK CMD one-liner passes bash -n
#   7. generator hygiene     — no unexpanded shell placeholders, no empty
#                              image tag, no curl|bash (ENGINEERING_RULES 3)
#
# Accumulation pattern (set +e + helpers counters); exit code = failures.
# =============================================================================

source "${BASH_SOURCE[0]%/*}/../helpers.sh" || { echo "FATAL: cannot source helpers.sh — run via tests/test_runner.sh (P0-3: unsandboxed HOME writes forbidden)" >&2; exit 1; }
source ../../version-advanced.sh

set +e

TESTS_FAILED=0
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vms-docker-tpl.XXXXXX")"
trap 'rm -rf "$WORK_ROOT"' EXIT

# _check <label> <command...> — records pass/fail via the helpers counters.
_check() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "  $label"
    else
        fail "  $label"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# _check_output <label> <expected> <actual>
_check_output() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "  $label"
    else
        fail "  $label (expected: $expected, got: $actual)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# _final_stage <file> — print only the lines after the LAST FROM directive
_final_stage() {
    local file="$1"
    local last_from
    last_from=$(grep -n '^FROM ' "$file" | tail -1 | cut -d: -f1)
    tail -n "+$((last_from + 1))" "$file"
}

# _healthcheck_cmd <file> — print the shell fragment after HEALTHCHECK ... CMD
_healthcheck_cmd() {
    local file="$1"
    grep '^HEALTHCHECK' "$file" | sed -E 's/^HEALTHCHECK.*[[:space:]]CMD[[:space:]]//'
}

# _assert_properties <file> <final_stage_user> <expected_expose>
_assert_properties() {
    local file="$1" want_user="$2" want_expose="$3"
    local final_stage from_count users vars env_path_lines

    _check "$file: exists and is non-empty" test -s "$file"

    # 1. multi-stage
    from_count=$(grep -c '^FROM ' "$file" 2>/dev/null || echo 0)
    _check_output "$file: FROM count >= 2 (multi-stage)" "ok" \
        "$( (( from_count >= 2 )) && echo ok || echo "no:$from_count" )"
    _check "$file: builder stage named (AS builder)" \
        grep -q '^FROM .* AS builder$' "$file"

    # 2. non-root USER in the final stage
    final_stage=$(_final_stage "$file")
    _check "$file: USER present in final stage" \
        grep -q '^USER ' <<< "$final_stage"
    users=$(grep '^USER ' <<< "$final_stage" | awk '{print $2}' | sort -u | tr '\n' ' ')
    _check_output "$file: final-stage USER is non-root ('$want_user')" "ok" \
        "$( [[ "${users%% }" == "$want_user" && "$want_user" != "root" && "$want_user" != "0" ]] && echo ok || echo "no:[$users]" )"

    # 3. HEALTHCHECK in the final stage
    _check "$file: HEALTHCHECK present in final stage" \
        grep -q '^HEALTHCHECK' <<< "$final_stage"

    # 4. artifacts-only copies in the final stage
    _check "$file: final stage copies from builder (COPY --from=builder)" \
        grep -q '^COPY --from=builder ' <<< "$final_stage"
    _check "$file: no broad 'COPY . .' in final stage" \
        bash -c '[[ "$1" != *"COPY . ."* ]]' _ "$final_stage"

    # 5. apt hygiene: every apt-get install line carries --no-install-recommends
    _check "$file: every 'apt-get install' line carries --no-install-recommends" \
        bash -c '! grep "apt-get install" "$1" | grep -qv -- "--no-install-recommends"' _ "$file"

    # 6. HEALTHCHECK CMD shell fragment is shell-valid
    _check "$file: HEALTHCHECK CMD passes bash -n" \
        bash -n < <(_healthcheck_cmd "$file")

    # 7. generator hygiene
    #    a) no '${...}' leakage (catches unexpanded generator params)
    _check "$file: no '\${...}' placeholder leakage" \
        bash -c '[[ "$1" != *"\${"* ]]' _ "$file"
    #    b) the only $VAR that may survive generation is the intended
    #       literal $PATH (Docker ENV), and it must be the venv literal —
    #       a generation-time expansion would substitute a real host path.
    vars=$(grep -o '\$[A-Za-z_][A-Za-z0-9_]*' "$file" 2>/dev/null | sort -u | tr '\n' ' ')
    _check_output "$file: only the intended literal \$PATH survives generation" "ok" \
        "$( [[ -z "${vars// }" || "$vars" == "\$PATH " ]] && echo ok || echo "no:[$vars]" )"
    env_path_lines=$(grep '^ENV PATH=' "$file" 2>/dev/null | sort -u | tr '\n' '|')
    _check_output "$file: ENV PATH lines are the venv literal (or none)" "ok" \
        "$( [[ -z "$env_path_lines" || "$env_path_lines" == 'ENV PATH="/opt/venv/bin:$PATH"|' ]] && echo ok || echo "no:[$env_path_lines]" )"
    #    c) no empty image tag, no curl|bash (ENGINEERING_RULES 3)
    _check "$file: no empty image tag (FROM <image>:)" \
        bash -c '! grep -qE "^FROM [^:]+:$" "$1"' _ "$file"
    _check "$file: no curl|bash or curl|sh" \
        bash -c '! grep -qE "curl[^|]*\|[[:space:]]*(ba)?sh" "$1"' _ "$file"
    _check "$file: EXPOSE $want_expose present" \
        grep -q "^EXPOSE $want_expose\$" "$file"
    _check "$file: CMD present" \
        grep -q '^CMD ' "$file"
}

# =============================================================================
# Per-template generation + property assertions
# =============================================================================

test_template_node() {
    local dir="$WORK_ROOT/node"
    mkdir -p "$dir"
    (cd "$dir" && generate_dockerfile_node "20.19.2" >/dev/null 2>&1)
    echo "--- Dockerfile.node (P2-7) ---"
    _assert_properties "$dir/Dockerfile.node" "node" "3000"
}

test_template_python() {
    local dir="$WORK_ROOT/python"
    mkdir -p "$dir"
    (cd "$dir" && generate_dockerfile_python "3.12.11" >/dev/null 2>&1)
    echo "--- Dockerfile.python (P2-7) ---"
    _assert_properties "$dir/Dockerfile.python" "appuser" "8000"
}

test_template_go() {
    local dir="$WORK_ROOT/go"
    mkdir -p "$dir"
    (cd "$dir" && generate_dockerfile_go "1.23.4" >/dev/null 2>&1)
    echo "--- Dockerfile.go (P2-7) ---"
    _assert_properties "$dir/Dockerfile.go" "appuser" "8080"
}

test_template_rust() {
    local dir="$WORK_ROOT/rust"
    mkdir -p "$dir"
    (cd "$dir" && generate_dockerfile_rust "1.81.0" >/dev/null 2>&1)
    echo "--- Dockerfile.rust (P2-7) ---"
    _assert_properties "$dir/Dockerfile.rust" "appuser" "8000"
}

test_template_java() {
    local dir="$WORK_ROOT/java"
    mkdir -p "$dir"
    (cd "$dir" && generate_dockerfile_java "17.0.12" >/dev/null 2>&1)
    echo "--- Dockerfile.java (P2-7) ---"
    _assert_properties "$dir/Dockerfile.java" "appuser" "8080"
}

# Default-version path: no argument, no version pin files present — the
# generator must fall back to its built-in default, not emit an empty tag.
test_template_default_version() {
    local dir="$WORK_ROOT/default"
    mkdir -p "$dir"
    (cd "$dir" && generate_dockerfile_node >/dev/null 2>&1)
    echo "--- default-version fallback (node, no arg) ---"
    _check "default-version Dockerfile.node created" test -s "$dir/Dockerfile.node"
    _check "default-version resolves to a non-empty tag (node:<v>)" \
        grep -qE '^FROM node:[0-9]+\.[0-9]+\.[0-9]+' "$dir/Dockerfile.node"
    _check "default-version runtime stage present (node:<v>-slim)" \
        grep -qE '^FROM node:[0-9]+\.[0-9]+\.[0-9]+-slim AS runtime$' "$dir/Dockerfile.node"
}

# Explicit-version plumbing: the version argument must land in BOTH stages.
test_template_version_argument() {
    local dir="$WORK_ROOT/argversion"
    mkdir -p "$dir"
    (cd "$dir" && generate_dockerfile_node "22.14.0" >/dev/null 2>&1)
    echo "--- explicit-version plumbing (node, 22.14.0) ---"
    _check "explicit version used in builder stage" \
        grep -q '^FROM node:22.14.0 AS builder$' "$dir/Dockerfile.node"
    _check "explicit version used in runtime stage" \
        grep -q '^FROM node:22.14.0-slim AS runtime$' "$dir/Dockerfile.node"
}

echo "=== Docker Template Property Tests (P2-7) ==="
test_template_node
test_template_python
test_template_go
test_template_rust
test_template_java
test_template_default_version
test_template_version_argument

print_summary
rm -rf "$WORK_ROOT"
exit "$_TEST_FAIL_COUNT"
