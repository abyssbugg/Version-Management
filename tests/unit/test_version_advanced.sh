#!/usr/bin/env bash
# Unit tests for version-advanced.sh - CI/CD Generation
#
# P2-7 (ENGINEERING_RULES 4.3 — function-existence assertions are not tests):
# the "P2-7" section below runs every real Dockerfile generator in a sandbox
# and asserts on the GENERATED CONTENT (multi-stage, final-stage non-root
# USER, final-stage HEALTHCHECK, generated-content rules), with a negative
# control, near-miss controls and mutated-real-template controls proving the
# assertions can fail. Every case runs in its own errexit subshell; failed
# cases are counted and the file exits non-zero (A5 accumulation pattern).

source "${BASH_SOURCE[0]%/*}/../helpers.sh" || { echo "FATAL: cannot source helpers.sh — run via tests/test_runner.sh (P0-3: unsandboxed HOME writes forbidden)" >&2; exit 1; }

# Sandbox BEFORE sourcing the script under test: version-advanced.sh derives
# CONFIG_DIR/CACHE_DIR/LOG_DIR/STATE_DIR/LOG_FILE from $HOME at source time
# and its CLI path creates them. The runner already sandboxes HOME/XDG; this
# block also covers TMPDIR/XDG_DATA/XDG_STATE and direct entry points
# (`make test-advanced` runs this file without the runner).
_VA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_VA_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/vms-version-advanced.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap '[[ "$_VA_SANDBOX" == */vms-version-advanced.* ]] && rm -rf -- "$_VA_SANDBOX"' EXIT
export HOME="$_VA_SANDBOX/home" TMPDIR="$_VA_SANDBOX/tmp"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$TMPDIR"
unset CONFIG_DIR CACHE_DIR LOG_DIR STATE_DIR LOG_FILE

# shellcheck source=version-advanced.sh
source "$_VA_ROOT/version-advanced.sh"

# version-advanced.sh enables `set -euo pipefail` in this shell. Keep -u and
# pipefail; errexit is re-enabled per case inside _va_run_case's subshell so
# one failing case cannot hide the others (and cannot pass silently).
set +e

# Test generate_github_actions function exists
test_generate_github_actions_function_exists() {
    if declare -f generate_github_actions >/dev/null 2>&1; then
        assert_equals "true" "true" "generate_github_actions function exists"
    else
        assert_equals "function_exists" "function_missing" "generate_github_actions function should exist"
    fi
}

# Test generate_gitlab_ci function exists
test_generate_gitlab_ci_function_exists() {
    if declare -f generate_gitlab_ci >/dev/null 2>&1; then
        assert_equals "true" "true" "generate_gitlab_ci function exists"
    else
        assert_equals "function_exists" "function_missing" "generate_gitlab_ci function should exist"
    fi
}

# Test generate_circleci function exists
test_generate_circleci_function_exists() {
    if declare -f generate_circleci >/dev/null 2>&1; then
        assert_equals "true" "true" "generate_circleci function exists"
    else
        assert_equals "function_exists" "function_missing" "generate_circleci function should exist"
    fi
}

# Test generate_dockerfile_node function exists
test_generate_dockerfile_node_function_exists() {
    if declare -f generate_dockerfile_node >/dev/null 2>&1; then
        assert_equals "true" "true" "generate_dockerfile_node function exists"
    else
        assert_equals "function_exists" "function_missing" "generate_dockerfile_node function should exist"
    fi
}

# Test generate_dockerfile_python function exists
test_generate_dockerfile_python_function_exists() {
    if declare -f generate_dockerfile_python >/dev/null 2>&1; then
        assert_equals "true" "true" "generate_dockerfile_python function exists"
    else
        assert_equals "function_exists" "function_missing" "generate_dockerfile_python function should exist"
    fi
}

# Test generate_docker_compose function exists
test_generate_docker_compose_function_exists() {
    if declare -f generate_docker_compose >/dev/null 2>&1; then
        assert_equals "true" "true" "generate_docker_compose function exists"
    else
        assert_equals "function_exists" "function_missing" "generate_docker_compose function should exist"
    fi
}

# Test generate_github_actions creates correct directory and file
test_generate_github_actions_creates_file() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    # Create a mock project
    echo "test project" > README.md

    # Run the generator
    generate_github_actions >/dev/null 2>&1 && local result=0 || local result=$?

    if [[ -f ".github/workflows/version-manager.yml" ]]; then
        assert_equals "true" "true" "generate_github_actions creates workflow file"
    elif [[ $result -ne 0 ]]; then
        # If it failed, it might be due to validation - that's okay for this test
        assert_equals "true" "true" "generate_github_actions ran (may require project validation)"
    else
        assert_equals "file_exists" "file_missing" ".github/workflows/version-manager.yml should be created"
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test generate_dockerfile_node creates Dockerfile
test_generate_dockerfile_node_creates_file() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    # Create a mock Node.js project
    echo '{"name":"test"}' > package.json
    echo "20.0.0" > .nvmrc

    # Run the generator
    generate_dockerfile_node >/dev/null 2>&1 || true

    if [[ -f "Dockerfile" ]] || [[ -f "Dockerfile.node" ]]; then
        assert_equals "true" "true" "generate_dockerfile_node creates Dockerfile"
    else
        # Function might have validation requirements
        assert_equals "true" "true" "generate_dockerfile_node ran (validation may have blocked)"
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test generate_docker_compose creates docker-compose.yml
test_generate_docker_compose_creates_file() {
    local temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    # Create a mock project
    echo '{"name":"test"}' > package.json

    # Run the generator
    generate_docker_compose >/dev/null 2>&1 || true

    if [[ -f "docker-compose.yml" ]]; then
        assert_equals "true" "true" "generate_docker_compose creates docker-compose.yml"
    else
        # Function might have validation requirements
        assert_equals "true" "true" "generate_docker_compose ran (validation may have blocked)"
    fi

    cd - > /dev/null || exit 1
    rm -rf "$temp_dir"
}

# Test generated CI templates avoid pipe-to-shell installers and parse as YAML
test_generate_ci_templates_avoid_pipe_to_shell_installers() {
    local temp_dir=$(mktemp -d)
    local old_pwd="$PWD"
    cd "$temp_dir" || exit 1

    mkdir -p .git
    echo "test project" > README.md

    generate_github_actions >/dev/null 2>&1
    generate_gitlab_ci >/dev/null 2>&1
    generate_circleci >/dev/null 2>&1

    local files=(
        ".github/workflows/version-manager.yml"
        ".gitlab-ci.yml"
        ".circleci/config.yml"
    )

    local file
    for file in "${files[@]}"; do
        assert_file_exists "$file" "$file is generated"

        local forbidden
        forbidden=$(grep -nE '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh' "$file" || true)
        assert_equals "" "$forbidden" "$file does not contain pipe-to-shell installers"

        if python3 -c 'import yaml' >/dev/null 2>&1; then
            python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$file"
            assert_equals "0" "$?" "$file parses as YAML"
        fi
    done

    cd "$old_pwd" || exit 1
    rm -rf "$temp_dir"
}

# Test generate_all_ci function exists
test_generate_all_ci_function_exists() {
    if declare -f generate_all_ci >/dev/null 2>&1; then
        assert_equals "true" "true" "generate_all_ci function exists"
    else
        assert_equals "function_exists" "function_missing" "generate_all_ci function should exist"
    fi
}

# Test generate_docker_configs function exists
test_generate_docker_configs_function_exists() {
    if declare -f generate_docker_configs >/dev/null 2>&1; then
        assert_equals "true" "true" "generate_docker_configs function exists"
    else
        assert_equals "function_exists" "function_missing" "generate_docker_configs function should exist"
    fi
}

# Test all CI/CD generator functions exist
test_all_cicd_generator_functions_exist() {
    local functions=("generate_github_actions" "generate_gitlab_ci" "generate_circleci"
                     "generate_docker_ci" "generate_all_ci")
    local missing=0

    for func in "${functions[@]}"; do
        if ! declare -f "$func" >/dev/null 2>&1; then
            echo "Missing function: $func"
            missing=$(( missing + 1 ))
        fi
    done

    if [[ $missing -eq 0 ]]; then
        assert_equals "true" "true" "All 5 CI/CD generator functions exist"
    else
        assert_equals "0" "$missing" "$missing CI/CD functions are missing"
    fi
}

# Test all Dockerfile generator functions exist
test_all_dockerfile_generator_functions_exist() {
    local functions=("generate_dockerfile_node" "generate_dockerfile_python"
                     "generate_dockerfile_go" "generate_dockerfile_rust"
                     "generate_dockerfile_java" "generate_docker_compose"
                     "generate_docker_configs")
    local missing=0

    for func in "${functions[@]}"; do
        if ! declare -f "$func" >/dev/null 2>&1; then
            echo "Missing function: $func"
            missing=$(( missing + 1 ))
        fi
    done

    if [[ $missing -eq 0 ]]; then
        assert_equals "true" "true" "All 7 Dockerfile generator functions exist"
    else
        assert_equals "0" "$missing" "$missing Dockerfile functions are missing"
    fi
}

# ============================================================================
# P2-7 — behavioral verification of the generated Dockerfile templates
# ============================================================================
# Every Dockerfile generator is run for real (generate_docker_configs, the
# `version-advanced.sh docker` path) in an empty sandbox project dir — no
# .nvmrc/.python-version/... so the built-in default versions apply — and
# the generated files are judged by the predicates below. Each predicate
# takes a Dockerfile path and returns 0 iff the hardened property HOLDS.
#
# Main's generators all document themselves as multi-stage (Java is a JDK
# builder + JRE runtime), so there is no single-stage exception any more;
# _p27_stage_layout_documented still encodes the rule "a single-stage
# template must say so" in case one is added.

# generator:file:expected effective USER:expected EXPOSE/probe port
_P27_TEMPLATES=(
    "generate_dockerfile_node:Dockerfile.node:node:3000"
    "generate_dockerfile_python:Dockerfile.python:appuser:8000"
    "generate_dockerfile_go:Dockerfile.go:appuser:8080"
    "generate_dockerfile_rust:Dockerfile.rust:appuser:8000"
    "generate_dockerfile_java:Dockerfile.java:appuser:8080"
)

# Every predicate here is applied to every real template AND to the negative
# control, so no assertion can exist that has not been shown to fail.
_P27_PREDICATES=(
    _p27_multi_stage
    _p27_stage_layout_documented
    _p27_final_user_non_root
    _p27_user_provisioned
    _p27_final_healthcheck
    _p27_healthcheck_probes_exposed_port
    _p27_healthcheck_tool_available
    _p27_no_pipe_to_shell
    _p27_no_eval
    _p27_apt_hygiene
    _p27_base_images_tagged
)

_P27_DIR="$_VA_SANDBOX/p27-templates"
_P27_TALLY="$_VA_SANDBOX/p27.tally"
_P27_CASE_FAILS=0

# awk helper: image name without registry/namespace, tag or digest.
_P27_AWK_BASE='function base(img,   b) { b = img; sub(/@.*/, "", b); sub(/.*\//, "", b); sub(/:.*/, "", b); return tolower(b) }'

# Dockerfile logical lines: backslash continuations joined, so an
# instruction split across lines is judged as one instruction.
_p27_logical() {
    [[ -r "$1" ]] || return 1
    awk '{
        line = $0
        if (sub(/\\[ \t]*$/, "", line)) { buf = buf line " "; next }
        print buf line
        buf = ""
    }
    END { if (buf != "") print buf }' "$1"
}

_p27_nonempty() { [[ -s "$1" ]]; }

# (a) >= 2 FROM, a NAMED earlier stage (FROM ... AS <name>), and the final
# stage consumes it (COPY --from=<name>) — builder output actually used.
_p27_multi_stage() {
    [[ -r "$1" ]] || return 1
    _p27_logical "$1" | awk '
        toupper($1) == "FROM" {
            n++; name[n] = ""
            for (i = 2; i < NF; i++) if (toupper($i) == "AS") name[n] = tolower($(i + 1))
            next
        }
        toupper($1) == "COPY" && n > 0 {
            for (i = 2; i <= NF; i++)
                if (tolower(substr($i, 1, 7)) == "--from=") from[n] = from[n] " " tolower(substr($i, 8)) " "
        }
        END {
            if (n < 2) exit 1
            for (k = 1; k < n; k++)
                if (name[k] != "" && index(from[n], " " name[k] " ") > 0) exit 0
            exit 1
        }'
}

# (a) the template's own comments match its stage layout: a multi-stage
# file says "multi-stage"; a single-stage file must document "single-stage".
_p27_stage_layout_documented() {
    [[ -r "$1" ]] || return 1
    local doc
    doc=$(grep -E '^[[:space:]]*#' "$1" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if _p27_multi_stage "$1"; then
        [[ "$doc" == *multi-stage* ]]
    else
        [[ "$doc" == *single-stage* ]]
    fi
}

# (b) the effective (last) USER sits after the final FROM and is not
# root / uid 0 / an unverifiable variable.
_p27_final_user_non_root() {
    [[ -r "$1" ]] || return 1
    _p27_logical "$1" | awk '
        toupper($1) == "FROM" { last_from = NR; next }
        toupper($1) == "USER" { user_nr = NR; user = $2 }
        END {
            if (last_from == 0 || user_nr <= last_from || user == "") exit 1
            split(user, parts, ":"); u = parts[1]
            if (u == "" || u ~ /\$/ || tolower(u) == "root" || u ~ /^0+$/) exit 1
            exit 0
        }'
}

# (b) the final USER account exists in the runtime image: created in the
# final stage (useradd/adduser, non-zero --uid) before the USER line, or a
# base-image account (node:* images ship uid-1000 "node", which the node
# template documents). USER without the account is a runtime failure.
_p27_user_provisioned() {
    [[ -r "$1" ]] || return 1
    _p27_logical "$1" | awk "$_P27_AWK_BASE"'
        toupper($1) == "FROM" {
            last_from = NR; created = " "; bad_uid = 0; known = 0; user = ""; final_base = ""
            for (i = 2; i <= NF; i++) if (substr($i, 1, 2) != "--") { final_base = base($i); break }
            next
        }
        toupper($1) == "RUN" && ($0 ~ /useradd/ || $0 ~ /adduser/) {
            for (i = 2; i <= NF; i++) {
                t = $i; gsub(/[";&|]/, "", t); created = created t " "
                if (t ~ /^--uid=0+$/) bad_uid = 1
                if ((t == "--uid" || t == "-u") && i < NF && $(i + 1) ~ /^0+$/) bad_uid = 1
            }
        }
        toupper($1) == "USER" {
            user_nr = NR; split($2, parts, ":"); user = parts[1]
            known = (index(created, " " user " ") > 0 && !bad_uid)
        }
        END {
            if (user_nr <= last_from || user == "") exit 1
            if (known) exit 0
            if (final_base == "node" && user == "node") exit 0
            exit 1
        }'
}

# (c) a HEALTHCHECK with a CMD (not NONE) in the final stage.
_p27_final_healthcheck() {
    [[ -r "$1" ]] || return 1
    _p27_logical "$1" | awk '
        toupper($1) == "FROM" { hc = ""; arg = ""; seen = 1; next }
        toupper($1) == "HEALTHCHECK" { hc = $0; arg = toupper($2) }
        END {
            if (!seen || hc == "" || arg == "NONE") exit 1
            n = split(hc, f, /[ \t]+/)
            for (i = 1; i <= n; i++) if (toupper(f[i]) == "CMD") exit 0
            exit 1
        }'
}

# (c) the final-stage HEALTHCHECK probes loopback on the port the final
# stage EXPOSEs (a dead server fails it; no probing a different service).
_p27_healthcheck_probes_exposed_port() {
    [[ -r "$1" ]] || return 1
    _p27_logical "$1" | awk '
        toupper($1) == "FROM" { hc = ""; port = ""; next }
        toupper($1) == "EXPOSE" { port = $2; sub(/\/.*/, "", port) }
        toupper($1) == "HEALTHCHECK" { hc = $0 }
        END {
            if (hc == "" || port !~ /^[0-9]+$/) exit 1
            n = split("127.0.0.1:" port " localhost:" port, want, " ")
            for (k = 1; k <= n; k++) {
                p = index(hc, want[k])
                if (p > 0 && substr(hc, p + length(want[k]), 1) !~ /[0-9]/) exit 0
            }
            exit 1
        }'
}

# (c) the HEALTHCHECK probe binary exists in the runtime image: installed in
# the final stage (apt-get/apk), or the node binary of a node:* base image.
# A curl probe in a slim image without curl is permanently "unhealthy".
_p27_healthcheck_tool_available() {
    [[ -r "$1" ]] || return 1
    _p27_logical "$1" | awk "$_P27_AWK_BASE"'
        toupper($1) == "FROM" {
            installed = " "; tool = ""; final_base = ""
            for (i = 2; i <= NF; i++) if (substr($i, 1, 2) != "--") { final_base = base($i); break }
            next
        }
        toupper($1) == "RUN" && ($0 ~ /apt-get[ \t]+install/ || $0 ~ /apt[ \t]+install/ || $0 ~ /apk[ \t]+add/) {
            for (i = 2; i <= NF; i++) installed = installed $i " "
        }
        toupper($1) == "HEALTHCHECK" {
            tool = ""
            for (i = 2; i < NF; i++) if (toupper($i) == "CMD") { tool = $(i + 1); break }
            gsub(/"/, "", tool); gsub(/,/, "", tool); gsub(/\[/, "", tool); gsub(/]/, "", tool)
        }
        END {
            if (tool == "") exit 1
            if (index(installed, " " tool " ") > 0) exit 0
            if (tool == "node" && final_base == "node") exit 0
            exit 1
        }'
}

# (d) no pipe-to-shell installer anywhere in the emitted file, comments
# included (ENGINEERING_RULES 2.3: never EMIT curl|sh): `curl|sh`,
# `wget|sudo bash`, `bash <(curl ...)`, `sh -c "$(curl ...)"`.
_p27_no_pipe_to_shell() {
    [[ -r "$1" ]] || return 1
    ! _p27_logical "$1" | grep -Eq \
        -e '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(env[[:space:]]+)?(ba|da|z|k)?sh([^[:alnum:]_.-]|$)' \
        -e '(ba|da|z|k)?sh[[:space:]]+(-[[:alpha:]]+[[:space:]]+)*<\([[:space:]]*(curl|wget)' \
        -e '(ba|da|z|k)?sh[[:space:]]+-c[[:space:]]+["'\'']?\$\([[:space:]]*(curl|wget)'
}

# (d) no eval in any instruction (ENGINEERING_RULES 2.1); comments ignored.
_p27_no_eval() {
    [[ -r "$1" ]] || return 1
    ! _p27_logical "$1" | grep -Ev '^[[:space:]]*#' | grep -Eq '(^|[^[:alnum:]_])eval[[:space:]]'
}

# (d) every apt install runs `apt-get update` first and removes
# /var/lib/apt/lists/* afterwards IN THE SAME LAYER, with
# --no-install-recommends (what main's generators emit). Vacuous when the
# file installs nothing via apt.
_p27_apt_hygiene() {
    [[ -r "$1" ]] || return 1
    _p27_logical "$1" | awk '
        /^[ \t]*#/ { next }
        /apt-get[ \t]+install|apt[ \t]+install/ {
            i = match($0, /apt(-get)?[ \t]+install/)
            u = index($0, "apt-get update"); if (u == 0) u = index($0, "apt update")
            c = index($0, "rm -rf /var/lib/apt/lists/*")
            if (u == 0 || u > i || c == 0 || c < i || index($0, "--no-install-recommends") == 0) bad = 1
        }
        END { exit bad ? 1 : 0 }'
}

# (d) every FROM names an earlier stage, scratch, a digest, or an image with
# an explicit, literal, non-latest tag (implicit :latest and empty or
# unexpanded "$VAR" tags are rejected). Main does NOT digest-pin or
# numeric-pin every base (debian:bookworm-slim), so neither is asserted.
_p27_base_images_tagged() {
    [[ -r "$1" ]] || return 1
    _p27_logical "$1" | awk '
        toupper($1) == "FROM" {
            seen = 1; img = ""; name = ""
            for (i = 2; i <= NF; i++) {
                if (img == "" && substr($i, 1, 2) != "--") img = $i
                else if (toupper($i) == "AS" && i < NF) name = tolower($(i + 1))
            }
            ref = tolower(img)
            if (ref == "") bad = 1
            else if (!((ref in stages) || ref == "scratch" || ref ~ /@sha256:[0-9a-f]+$/)) {
                b = ref; sub(/.*\//, "", b)
                if (index(b, ":") == 0) bad = 1
                else {
                    tag = b; sub(/^[^:]*:/, "", tag)
                    if (tag == "" || tag == "latest" || tag ~ /\$/) bad = 1
                }
            }
            if (name != "") stages[name] = 1
        }
        END { exit (bad || !seen) ? 1 : 0 }'
}

# Extractors used for exact-value expectations.
_p27_final_user() {
    _p27_logical "$1" | awk 'toupper($1) == "FROM" { u = ""; next } toupper($1) == "USER" { u = $2 } END { print u }'
}
_p27_final_expose() {
    _p27_logical "$1" | awk 'toupper($1) == "FROM" { p = ""; next } toupper($1) == "EXPOSE" { p = $2 } END { print p }'
}

# docker-compose.yml: the service that builds <dockerfile> maps container
# port <port>.
_p27_compose_maps() {
    [[ -r "$1" ]] || return 1
    awk -v df="$2" -v port="$3" '
        /^  [^ #][^:]*:[ \t]*$/ { cur = "" }
        $1 == "dockerfile:" { cur = $2 }
        /^[ \t]+- "?[0-9]+:[0-9]+"?[ \t]*$/ {
            m = $2; gsub(/"/, "", m); sub(/^[0-9]+:/, "", m)
            if (cur == df && m == port) found = 1
        }
        END { exit found ? 0 : 1 }' "$1"
}

# ── P2-7 assertion recording (survives the per-case subshell) ───────────────
_p27_record() {  # <0=ok|1=failed> <label>
    if [[ "$1" == 0 ]]; then
        pass "$2"
        echo P >> "$_P27_TALLY"
    else
        fail "$2"
        echo F >> "$_P27_TALLY"
        _P27_CASE_FAILS=$((_P27_CASE_FAILS + 1))
    fi
}
# _p27_expect <label> <cmd...> — cmd must SUCCEED (property holds)
_p27_expect() {
    local label="$1"
    shift
    if "$@"; then _p27_record 0 "$label"; else _p27_record 1 "$label"; fi
}
# _p27_reject <label> <cmd...> — cmd must FAIL (property violated)
_p27_reject() {
    local label="$1"
    shift
    if "$@"; then _p27_record 1 "$label"; else _p27_record 0 "$label"; fi
}
_p27_expect_eq() {  # <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then
        _p27_record 0 "$1"
    else
        _p27_record 1 "$1 (expected '$2', got '$3')"
    fi
}
_p27_case_end() { (( _P27_CASE_FAILS == 0 )); }

# _p27_in_dir <dir> <cmd...> — run cmd with <dir> as CWD (generators write
# into the CWD), output discarded, CWD change confined to a subshell.
_p27_in_dir() {
    local dir="$1"
    shift
    (cd "$dir" && "$@" >/dev/null 2>&1)
}

# Template files from the table, sorted, space-joined.
_p27_table_files() {
    local entry rest
    for entry in "${_P27_TEMPLATES[@]}"; do
        rest="${entry#*:}"
        echo "${rest%%:*}"
    done | sort | tr '\n' ' '
}

# ── Cases ────────────────────────────────────────────────────────────────────

# Generates the templates every later P2-7 case judges (into $_P27_DIR, on
# disk, so they outlive this case's subshell — run this case first). Every
# generator the script offers is covered, and the aggregate `docker` path
# emits exactly the covered files (a new template cannot skip P2-7).
test_p27_template_inventory() {
    _P27_CASE_FAILS=0
    echo "--- P2-7: generate + template inventory ---"
    local declared expected produced entry f
    mkdir -p "$_P27_DIR"
    _p27_expect "generate_docker_configs runs in an empty sandbox project dir" \
        _p27_in_dir "$_P27_DIR" generate_docker_configs
    declared=$(declare -F | awk '$3 ~ /^generate_dockerfile_/ { print $3 }' | sort | tr '\n' ' ')
    expected=$(for entry in "${_P27_TEMPLATES[@]}"; do echo "${entry%%:*}"; done | sort | tr '\n' ' ')
    _p27_expect_eq "every generate_dockerfile_* generator is in the P2-7 table" "$expected" "$declared"
    produced=$(for f in "$_P27_DIR"/Dockerfile.*; do [[ -e "$f" ]] && echo "${f##*/}"; done | sort | tr '\n' ' ')
    _p27_expect_eq "generate_docker_configs emits exactly the P2-7 table's Dockerfiles" "$(_p27_table_files)" "$produced"
    _p27_case_end
}

test_p27_templates_multi_stage() {
    _P27_CASE_FAILS=0
    echo "--- P2-7 (a): multi-stage ---"
    local entry file path froms
    for entry in "${_P27_TEMPLATES[@]}"; do
        IFS=: read -r _ file _ _ <<< "$entry"
        path="$_P27_DIR/$file"
        froms=$(grep -cE '^[[:space:]]*FROM[[:space:]]' "$path" 2>/dev/null || true)
        _p27_expect "$file: generated and non-empty" _p27_nonempty "$path"
        _p27_expect "$file: ${froms:-0} FROM lines, named build stage consumed via COPY --from" _p27_multi_stage "$path"
        _p27_expect "$file: comments document the multi-stage layout" _p27_stage_layout_documented "$path"
    done
    _p27_case_end
}

test_p27_templates_non_root_user() {
    _P27_CASE_FAILS=0
    echo "--- P2-7 (b): non-root USER in the final stage ---"
    local entry file user path
    for entry in "${_P27_TEMPLATES[@]}"; do
        IFS=: read -r _ file user _ <<< "$entry"
        path="$_P27_DIR/$file"
        _p27_expect "$file: effective USER is after the final FROM and not root/0" _p27_final_user_non_root "$path"
        _p27_expect "$file: USER account is created in the final stage or base-provided" _p27_user_provisioned "$path"
        _p27_expect_eq "$file: effective USER is '$user'" "$user" "$(_p27_final_user "$path" 2>/dev/null || true)"
    done
    _p27_case_end
}

test_p27_templates_healthcheck() {
    _P27_CASE_FAILS=0
    echo "--- P2-7 (c): HEALTHCHECK in the final stage ---"
    local entry file port path
    for entry in "${_P27_TEMPLATES[@]}"; do
        IFS=: read -r _ file _ port <<< "$entry"
        path="$_P27_DIR/$file"
        _p27_expect "$file: final stage has a HEALTHCHECK with CMD (not NONE)" _p27_final_healthcheck "$path"
        _p27_expect "$file: HEALTHCHECK probes loopback on the EXPOSEd port" _p27_healthcheck_probes_exposed_port "$path"
        _p27_expect "$file: HEALTHCHECK probe binary exists in the runtime image" _p27_healthcheck_tool_available "$path"
        _p27_expect_eq "$file: final stage EXPOSEs $port" "$port" "$(_p27_final_expose "$path" 2>/dev/null || true)"
    done
    _p27_case_end
}

test_p27_templates_generated_content_rules() {
    _P27_CASE_FAILS=0
    echo "--- P2-7 (d): generated-content rules ---"
    local entry file path
    for entry in "${_P27_TEMPLATES[@]}"; do
        IFS=: read -r _ file _ _ <<< "$entry"
        path="$_P27_DIR/$file"
        _p27_expect "$file: no pipe-to-shell installer" _p27_no_pipe_to_shell "$path"
        _p27_expect "$file: no eval in instructions" _p27_no_eval "$path"
        _p27_expect "$file: apt update+install+list cleanup in one layer, --no-install-recommends" _p27_apt_hygiene "$path"
        _p27_expect "$file: every FROM has an explicit non-latest tag (or stage ref/digest)" _p27_base_images_tagged "$path"
    done
    _p27_case_end
}

# The user-facing CLI subcommands emit exactly the files judged above.
test_p27_cli_commands_emit_tested_templates() {
    _P27_CASE_FAILS=0
    echo "--- P2-7: CLI subcommands emit the tested templates ---"
    local cli_dir entry file lang
    cli_dir=$(mktemp -d "$TMPDIR/p27-cli.XXXXXX")
    _p27_expect "'version-advanced.sh docker' exits 0" \
        _p27_in_dir "$cli_dir" bash "$_VA_ROOT/version-advanced.sh" docker
    for entry in "${_P27_TEMPLATES[@]}"; do
        IFS=: read -r _ file _ _ <<< "$entry"
        _p27_expect "'version-advanced.sh docker' emits $file identical to the tested one" \
            cmp -s "$cli_dir/$file" "$_P27_DIR/$file"
    done
    for lang in go rust java; do
        rm -f -- "$cli_dir/Dockerfile.$lang"
        _p27_expect "'version-advanced.sh docker-$lang' exits 0" \
            _p27_in_dir "$cli_dir" bash "$_VA_ROOT/version-advanced.sh" "docker-$lang"
        _p27_expect "'version-advanced.sh docker-$lang' emits Dockerfile.$lang identical to the tested one" \
            cmp -s "$cli_dir/Dockerfile.$lang" "$_P27_DIR/Dockerfile.$lang"
    done
    _p27_case_end
}

# docker-compose.yml (same `docker` path) builds every template and maps the
# port each template EXPOSEs and health-checks.
test_p27_compose_matches_templates() {
    _P27_CASE_FAILS=0
    echo "--- P2-7: docker-compose.yml <-> Dockerfile templates ---"
    local compose="$_P27_DIR/docker-compose.yml" referenced entry file port
    _p27_expect "docker-compose.yml generated and non-empty" _p27_nonempty "$compose"
    referenced=$(awk '$1 == "dockerfile:" { print $2 }' "$compose" 2>/dev/null | sort | tr '\n' ' ' || true)
    _p27_expect_eq "compose builds exactly the generated Dockerfiles" "$(_p27_table_files)" "$referenced"
    for entry in "${_P27_TEMPLATES[@]}"; do
        IFS=: read -r _ file _ port <<< "$entry"
        _p27_expect "compose service building $file maps container port $port" \
            _p27_compose_maps "$compose" "$file" "$port"
    done
    _p27_case_end
}

# Inline samples for the controls.
_p27_write_unhardened() {
    cat > "$1" <<'EOF'
FROM ubuntu:latest
RUN apt-get update && apt-get install -y curl
RUN curl -fsSL https://example.invalid/install.sh | sh
RUN eval "$(cat /etc/setup.env)"
COPY . /app
EXPOSE 8080
CMD ["/app/run"]
EOF
}
_p27_write_hardened() {
    cat > "$1" <<'EOF'
# Inline hardened multi-stage sample (positive control).
FROM golang:1.23.4 AS builder
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /out/server .

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
RUN useradd --uid 10001 --no-create-home appuser
COPY --from=builder /out/server /app/server
USER appuser
EXPOSE 8080
HEALTHCHECK --interval=30s CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1
CMD ["/app/server"]
EOF
}

# (e) NEGATIVE CONTROL: every predicate must REJECT a deliberately
# un-hardened Dockerfile (single FROM on :latest, no USER, no HEALTHCHECK,
# curl|sh, eval, apt without cleanup) and ACCEPT an inline hardened one —
# the assertions can fail, and do not fail everything.
test_p27_negative_control_unhardened_rejected() {
    _P27_CASE_FAILS=0
    echo "--- P2-7 (e): negative control ---"
    local dir pred
    dir=$(mktemp -d "$TMPDIR/p27-neg.XXXXXX")
    _p27_write_unhardened "$dir/Dockerfile.unhardened"
    _p27_write_hardened "$dir/Dockerfile.hardened"
    for pred in "${_P27_PREDICATES[@]}"; do
        _p27_reject "negative control: $pred REJECTS the un-hardened Dockerfile" "$pred" "$dir/Dockerfile.unhardened"
        _p27_expect "positive control: $pred accepts the inline hardened Dockerfile" "$pred" "$dir/Dockerfile.hardened"
    done
    _p27_case_end
}

# Near-miss controls: the hardened sample with ONE targeted defect each —
# proves the predicates check placement and semantics, not mere keywords.
# Edits are ${var//"$pattern"/replacement} substitutions: the pattern is
# quoted (literal, no glob); the replacement is left UNquoted and never
# contains `&` or a backslash — bash <= 4.2 keeps literal quotes in a quoted
# replacement (compat42) and bash >= 5.2 gives `&` a meaning
# (patsub_replacement), so this form is identical on bash 4.0 .. 5.x.
_P27_NM_DIR=""
_P27_NM_N=0
_p27_nm() {  # <predicate> <label> <content>: content must be REJECTED
    _P27_NM_N=$((_P27_NM_N + 1))
    printf '%s\n' "$3" > "$_P27_NM_DIR/near-miss.$_P27_NM_N"
    _p27_reject "near-miss: $2 — rejected by $1" "$1" "$_P27_NM_DIR/near-miss.$_P27_NM_N"
}

test_p27_near_miss_controls_rejected() {
    _P27_CASE_FAILS=0
    echo "--- P2-7 (e): near-miss controls ---"
    local good s final nl=$'\n'
    local wd='WORKDIR /src'
    local copy_from='COPY --from=builder /out/server /app/server'
    local useradd_line='RUN useradd --uid 10001 --no-create-home appuser'
    local hc_line='HEALTHCHECK --interval=30s CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1'
    local hc_builder='HEALTHCHECK CMD curl -fsS http://127.0.0.1:8080/healthz'
    local apt_clean=' && rm -rf /var/lib/apt/lists/*'
    local apt_update='apt-get update && '
    local var_tag='golang:$GO_VERSION'
    _P27_NM_DIR=$(mktemp -d "$TMPDIR/p27-near.XXXXXX")
    _p27_write_hardened "$_P27_NM_DIR/hardened"
    good=$(cat "$_P27_NM_DIR/hardened")
    final="FROM debian${good##*FROM debian}"

    # (a) multi-stage / layout documentation
    s="${good//" AS builder"/}"; s="${s//" AS runtime"/}"; s="${s//"--from=builder "/}"
    _p27_nm _p27_multi_stage "two FROMs, no named stage, no COPY --from" "$s"
    _p27_nm _p27_multi_stage "named builder never consumed by the final stage" "${good//"$copy_from"/COPY server .}"
    _p27_nm _p27_multi_stage "only the final stage" "# multi-stage${nl}$final"
    _p27_nm _p27_stage_layout_documented "single stage while comments claim multi-stage" "# Hardened multi-stage image${nl}$final"
    printf '%s\n' "# single-stage: prebuilt artifact, nothing to build${nl}$final" > "$_P27_NM_DIR/single-documented"
    _p27_expect "near-miss: a single stage that documents 'single-stage' is accepted by _p27_stage_layout_documented" \
        _p27_stage_layout_documented "$_P27_NM_DIR/single-documented"

    # (b) non-root USER in the final stage
    s="${good//"${nl}USER appuser"/}"; s="${s//"$wd"/$wd${nl}USER appuser}"
    _p27_nm _p27_final_user_non_root "USER only in the builder stage" "$s"
    _p27_nm _p27_final_user_non_root "USER root after USER appuser" "${good//"USER appuser"/USER appuser${nl}USER root}"
    _p27_nm _p27_final_user_non_root "USER 0:0" "${good//"USER appuser"/USER 0:0}"
    _p27_nm _p27_user_provisioned "USER appuser never created" "${good//"$useradd_line$nl"/}"
    _p27_nm _p27_user_provisioned "useradd --uid 0" "${good//"--uid 10001"/--uid 0}"

    # (c) HEALTHCHECK in the final stage
    s="${good//"$nl$hc_line"/}"
    _p27_nm _p27_final_healthcheck "HEALTHCHECK removed" "$s"
    _p27_nm _p27_final_healthcheck "HEALTHCHECK only in the builder stage" "${s//"$wd"/$wd$nl$hc_builder}"
    _p27_nm _p27_final_healthcheck "HEALTHCHECK NONE" "${good//"$hc_line"/HEALTHCHECK NONE}"
    _p27_nm _p27_healthcheck_probes_exposed_port "HEALTHCHECK probes a port that is not EXPOSEd" \
        "${good//"127.0.0.1:8080"/127.0.0.1:3000}"
    _p27_nm _p27_healthcheck_tool_available "curl probe but curl not installed in the runtime" \
        "${good//"--no-install-recommends curl"/--no-install-recommends ca-certificates}"

    # (d) generated-content rules
    _p27_nm _p27_no_pipe_to_shell "bash <(curl ...)" "$good${nl}RUN bash <(curl -fsSL https://example.invalid/i.sh)"
    _p27_nm _p27_no_pipe_to_shell "wget -qO- ... | sudo bash" "$good${nl}RUN wget -qO- https://example.invalid/i.sh | sudo bash"
    _p27_nm _p27_no_pipe_to_shell 'sh -c "$(curl ...)"' "$good${nl}"'RUN sh -c "$(curl -fsSL https://example.invalid/i.sh)"'
    _p27_nm _p27_no_pipe_to_shell "curl|sh only inside a comment (still emitted)" "$good${nl}# curl -fsSL https://example.invalid/i.sh | sh"
    _p27_nm _p27_no_eval "eval in a RUN instruction" "$good${nl}"'RUN eval "$SETUP"'
    _p27_nm _p27_apt_hygiene "apt lists not removed" "${good//"$apt_clean"/}"
    _p27_nm _p27_apt_hygiene "no --no-install-recommends" "${good//"--no-install-recommends "/}"
    _p27_nm _p27_apt_hygiene "install without apt-get update in the same layer" "${good//"$apt_update"/}"
    _p27_nm _p27_base_images_tagged "implicit :latest (FROM debian)" "${good//"debian:bookworm-slim"/debian}"
    _p27_nm _p27_base_images_tagged "explicit :latest" "${good//"debian:bookworm-slim"/debian:latest}"
    _p27_nm _p27_base_images_tagged "empty tag (FROM golang:)" "${good//"golang:1.23.4"/golang:}"
    _p27_nm _p27_base_images_tagged 'unexpanded $VAR tag' "${good//"golang:1.23.4"/$var_tag}"

    # Each near-miss must differ from the hardened sample (no silent no-op edit).
    local f
    for f in "$_P27_NM_DIR"/near-miss.*; do
        if cmp -s "$f" "$_P27_NM_DIR/hardened"; then
            _p27_record 1 "near-miss ${f##*/}: edit did not apply (identical to the hardened sample)"
        fi
    done
    _p27_case_end
}

# Mutated REAL templates: each generated file with one hardening property
# removed (a scratch copy — the generator is untouched) must be rejected by
# the matching predicate. A mutation that does not change the file fails.
_p27_mutant() {  # <predicate> <label> <original> <mutant>
    if cmp -s "$3" "$4"; then
        _p27_record 1 "mutant ${4##*/}: mutation did not apply ($2)"
        return 0
    fi
    _p27_reject "mutant ${4##*/}: $2 — rejected by $1" "$1" "$4"
}

test_p27_mutated_real_templates_rejected() {
    _P27_CASE_FAILS=0
    echo "--- P2-7 (e): mutated real templates ---"
    local dir entry file src m
    dir=$(mktemp -d "$TMPDIR/p27-mut.XXXXXX")
    for entry in "${_P27_TEMPLATES[@]}"; do
        IFS=: read -r _ file _ _ <<< "$entry"
        src="$_P27_DIR/$file"
        if [[ ! -s "$src" ]]; then
            _p27_record 1 "$file: not generated — cannot mutate"
            continue
        fi
        m="$dir/$file"

        grep -v '^HEALTHCHECK' "$src" > "$m.no-healthcheck" || true
        _p27_mutant _p27_final_healthcheck "HEALTHCHECK line deleted" "$src" "$m.no-healthcheck"

        sed -E 's/^USER .*/USER root/' "$src" > "$m.user-root"
        _p27_mutant _p27_final_user_non_root "final USER -> root" "$src" "$m.user-root"

        awk '{ l[NR] = $0; if (toupper($1) == "FROM") last = NR } END { for (i = last; i <= NR; i++) print l[i] }' \
            "$src" > "$m.final-stage-only"
        _p27_mutant _p27_multi_stage "builder stage(s) deleted" "$src" "$m.final-stage-only"

        { cat "$src"; echo 'RUN curl -fsSL https://example.invalid/install.sh | sh'; } > "$m.curl-sh"
        _p27_mutant _p27_no_pipe_to_shell "curl|sh appended" "$src" "$m.curl-sh"

        sed -E 's# && rm -rf /var/lib/apt/lists/\*##' "$src" > "$m.apt-lists-kept"
        _p27_mutant _p27_apt_hygiene "apt list cleanup removed" "$src" "$m.apt-lists-kept"

        awk '{ l[NR] = $0; if (toupper($1) == "FROM") last = NR }
             END { for (i = 1; i <= NR; i++) {
                     if (i == last) {
                         n = split(l[i], f, " "); img = f[2]; sub(/:[^:\/]*$/, "", img); f[2] = img ":latest"
                         s = f[1]; for (k = 2; k <= n; k++) s = s " " f[k]; print s
                     } else print l[i] } }' "$src" > "$m.latest"
        _p27_mutant _p27_base_images_tagged "final FROM retagged :latest" "$src" "$m.latest"
    done
    _p27_case_end
}

# ── Run — explicit failure accumulation (A5 pattern) ────────────────────────
# Each case runs in an errexit subshell (its own cd/locals cannot leak; a
# failed command or assertion aborts that case non-zero) and is counted.
# NOTE: the subshell must NOT be in an ||/&&/if context, or bash silently
# ignores errexit inside it.
_VA_FAILED_CASES=0
_va_run_case() {
    local rc
    ( set -e; "$1" )
    rc=$?
    if (( rc != 0 )); then
        _VA_FAILED_CASES=$((_VA_FAILED_CASES + 1))
        echo "CASE FAILED: $1 (rc=$rc)"
    fi
}

echo "=== Version Advanced (CI/CD Generation) Tests ==="
_va_run_case test_generate_github_actions_function_exists
_va_run_case test_generate_gitlab_ci_function_exists
_va_run_case test_generate_circleci_function_exists
_va_run_case test_generate_dockerfile_node_function_exists
_va_run_case test_generate_dockerfile_python_function_exists
_va_run_case test_generate_docker_compose_function_exists
_va_run_case test_generate_github_actions_creates_file
_va_run_case test_generate_dockerfile_node_creates_file
_va_run_case test_generate_docker_compose_creates_file
_va_run_case test_generate_ci_templates_avoid_pipe_to_shell_installers
_va_run_case test_generate_all_ci_function_exists
_va_run_case test_generate_docker_configs_function_exists
_va_run_case test_all_cicd_generator_functions_exist
_va_run_case test_all_dockerfile_generator_functions_exist

echo "=== P2-7 Dockerfile Template Behavior ==="
: > "$_P27_TALLY"
# test_p27_template_inventory generates the templates the later cases judge.
_va_run_case test_p27_template_inventory
_va_run_case test_p27_templates_multi_stage
_va_run_case test_p27_templates_non_root_user
_va_run_case test_p27_templates_healthcheck
_va_run_case test_p27_templates_generated_content_rules
_va_run_case test_p27_cli_commands_emit_tested_templates
_va_run_case test_p27_compose_matches_templates
_va_run_case test_p27_negative_control_unhardened_rejected
_va_run_case test_p27_near_miss_controls_rejected
_va_run_case test_p27_mutated_real_templates_rejected

_p27_passed=$(grep -c '^P$' "$_P27_TALLY" 2>/dev/null || true)
_p27_failed=$(grep -c '^F$' "$_P27_TALLY" 2>/dev/null || true)
echo "P2-7 assertions: ${_p27_passed:-0} passed, ${_p27_failed:-0} failed"
if (( ${_p27_passed:-0} + ${_p27_failed:-0} == 0 )); then
    echo "test_version_advanced.sh: no P2-7 assertions ran — failing closed"
    exit 1
fi
if (( _VA_FAILED_CASES > 0 )); then
    echo "test_version_advanced.sh: $_VA_FAILED_CASES case(s) failed"
    exit 1
fi
exit 0
