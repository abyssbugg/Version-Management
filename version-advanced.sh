#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # SC1091: dynamic source; SC2034: exported vars
# ============================================================================
# Advanced Version Management System
# ============================================================================
# A comprehensive system that provides:
# - CI/CD pipeline generation (GitHub Actions, GitLab CI, CircleCI)
# - Docker configuration helpers
# - Enhanced auto-switching and lazy-loading features
# ============================================================================

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Directories
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/version-manager}"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/version-manager}"
LOG_DIR="${LOG_DIR:-$HOME/.local/share/version-manager/logs}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/version-manager}"

# Files
CONFIG_FILE="$CONFIG_DIR/config.yaml"
STATE_FILE="$STATE_DIR/state.json"
LOG_FILE="$LOG_DIR/version-advanced-$(date +%Y%m%d).log"

# Settings
ENABLE_COLORS="${ENABLE_COLORS:-true}"
ENABLE_LOGGING="${ENABLE_LOGGING:-true}"
DEBUG_MODE="${DEBUG_MODE:-false}"
SILENT_MODE="${SILENT_MODE:-false}"

# Global flags and --dry-run (AX-1/AX-11 parity with version-manager.sh,
# AX-18). parse_args runs inside a process substitution, so its assignments
# never reached this shell and the documented global flags were no-ops.
# Leading flags are applied here, before colors and logging are configured,
# when the script is executed (a sourcing script's argv is ignored).
# --dry-run may appear anywhere: every generator then prints its plan and
# writes nothing (project files, HOME, logs).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _va_leading=1
    for _va_flag in "$@"; do
        if [[ "$_va_flag" == --dry-run ]]; then
            export TRANSACTION_DRY_RUN=1
            continue
        fi
        [[ "$_va_leading" == 1 ]] || continue
        case "$_va_flag" in
            --silent) SILENT_MODE=true ;;
            --debug) DEBUG_MODE=true ;;
            --no-color)
                ENABLE_COLORS=false
                export NO_COLOR=1
                ;;
            *) _va_leading=0 ;;
        esac
    done
    unset _va_flag _va_leading
fi
if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
    ENABLE_LOGGING=false
fi

# ============================================================================
# Color Definitions
# ============================================================================

if [[ "$ENABLE_COLORS" == "true" ]] && [[ -t 1 ]]; then
    # Real ESC bytes: show_usage prints these through a plain here-document,
    # where a '\033' literal is shown verbatim (AX-11 parity).
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    MAGENTA=$'\033[0;35m'
    CYAN=$'\033[0;36m'
    WHITE=$'\033[0;37m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''
    WHITE=''
    BOLD=''
    RESET=''
fi

# ============================================================================
# Logging — unified via lib/logger.sh
# ============================================================================
[[ "$ENABLE_LOGGING" == "true" ]] && export LOG_FILE || unset LOG_FILE 2>/dev/null
export SILENT_MODE
[[ "$DEBUG_MODE" == "true" ]] && export DEBUG=true || export DEBUG=false

# shellcheck source=lib/logger.sh
source "$SCRIPT_DIR/lib/logger.sh"

# Canonical platform API (P1-9): lib/env.sh is the single owner of get_os.
# This script's duplicated get_os body (reported "linux" under WSL) is
# deleted below — the sourced canonical implementation serves.
# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"

# log() and command_exists() are provided by lib/env.sh (ROADMAP 4.2 dedup);
# both are sourced above and guarded there so a caller override still wins.

# Generated project files are published through the transaction framework
# (AX-18): lib/mutation.sh brings lib/backup.sh and lib/validation.sh.
# shellcheck source=lib/mutation.sh
source "$SCRIPT_DIR/lib/mutation.sh"

# ============================================================================
# Utility Functions
# ============================================================================

# Create necessary directories
init_directories() {
    local dirs=("$CONFIG_DIR" "$CACHE_DIR" "$LOG_DIR" "$STATE_DIR")
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log_debug "Created directory: $dir"
        fi
    done
}

# command_exists() is provided by lib/env.sh (ROADMAP 4.2 dedup).

# ----------------------------------------------------------------------------
# Generated-file publication (AX-18, P3-1)
# ----------------------------------------------------------------------------
# Every generator renders into a private staging file and publishes it with
# mutation_file_publish: an existing (possibly hand-edited) file is backed up
# by the transaction before it is replaced, unchanged content is a no-op, the
# write is atomic, symlinks and modes are kept, and TRANSACTION_DRY_RUN=1
# plans without writing. A command that generates several files (docker,
# ci-all) runs as ONE transaction via _va_generate: any failure restores every
# file the run had already written. A generator called on its own (sourced
# use) opens a single-file transaction itself.

_VA_CREATED_DIRS=()

_va_stage() {
    mktemp "${TMPDIR:-/tmp}/vms-va-stage.XXXXXX"
}

# _va_report <what> [<file>]: success line, worded as a plan under dry-run.
_va_report() {
    local what="$1" file="${2:-}"
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] $what planned${file:+ for $file}; nothing written"
    else
        log_success "$what generated${file:+ at $file}"
    fi
}

# Create a generator's output directory; planned only under dry-run. Every
# directory this creates (including missing parents, outermost first) is
# recorded so a failed run can remove them again.
_va_ensure_dir() {
    local dir="$1" probe
    local -a va_new_dirs=()
    [[ -d "$dir" ]] && return 0
    if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] would create directory: $dir"
        return 0
    fi
    probe="$dir"
    while [[ -n "$probe" && "$probe" != "." && "$probe" != "/" && ! -d "$probe" ]]; do
        va_new_dirs=("$probe" ${va_new_dirs[@]+"${va_new_dirs[@]}"})
        probe=$(dirname -- "$probe")
    done
    mkdir -p -- "$dir" || { log_error "Cannot create directory: $dir"; return 1; }
    _VA_CREATED_DIRS+=(${va_new_dirs[@]+"${va_new_dirs[@]}"})
    log_info "Created directory: $dir"
}

# _va_publish <target> <staged>: publish, always remove the staged file.
_va_publish() {
    local target="$1" staged="$2" rc=0 own=0
    [[ "$target" == /* ]] || target="$PWD/$target"
    if ! transaction_is_active; then
        if ! transaction_start "version_advanced"; then
            rm -f -- "$staged"
            return 1
        fi
        own=1
    fi
    mutation_file_publish "$target" "$staged" || rc=1
    rm -f -- "$staged"
    if [[ "$own" == 1 ]]; then
        if [[ "$rc" == 0 ]]; then
            transaction_commit >/dev/null || rc=1
        else
            transaction_rollback >/dev/null 2>&1 || log_error "Rollback failed for $target — see the audit journal"
        fi
    fi
    return "$rc"
}

# _va_generate <transaction-name> <generator-fn>...: run the generators as one
# transaction; on any failure roll every written file back and remove the
# directories this run created (only if they are empty again).
_va_generate() {
    local name="$1" fn rc=0 i
    shift
    _VA_CREATED_DIRS=()
    transaction_start "$name" || return 1
    for fn in "$@"; do
        if ! "$fn"; then
            rc=1
            break
        fi
    done
    if [[ "$rc" == 0 ]]; then
        transaction_commit >/dev/null || rc=1
    fi
    if [[ "$rc" != 0 ]]; then
        if transaction_is_active; then
            transaction_rollback >/dev/null 2>&1 || log_error "Rollback failed — see the audit journal"
        fi
        for ((i = ${#_VA_CREATED_DIRS[@]} - 1; i >= 0; i--)); do
            rmdir -- "${_VA_CREATED_DIRS[i]}" 2>/dev/null || true
        done
        log_error "Generation failed — files written by this run were restored"
    fi
    _VA_CREATED_DIRS=()
    return "$rc"
}

# get_os: canonical implementation lives in lib/env.sh (sourced above, P1-9).
# WSL is reported as "wsl". This script has no get_os consumers today — the
# canonical function is exposed for any future caller.

# Validate project directory
validate_project_dir() {
    if [[ ! -d ".git" ]]; then
        log_error "Not in a git repository. Please run this command from the root of your project."
        return 1
    fi
    return 0
}

# ============================================================================
# CI/CD Template Functions
# ============================================================================

# Generate GitHub Actions workflow
generate_github_actions() {
    validate_project_dir || return 1

    local workflow_dir=".github/workflows"
    _va_ensure_dir "$workflow_dir" || return 1

    local workflow_file="$workflow_dir/version-manager.yml"

    local staged
    staged=$(_va_stage) || return 1
    cat > "$staged" << 'EOF' || { rm -f -- "$staged"; return 1; }
name: Version Manager CI

on:
  push:
    branches: [ main, master ]
  pull_request:
    branches: [ main, master ]

jobs:
  test:
    runs-on: ubuntu-latest

    strategy:
      matrix:
        node-version: [20.x, 22.x]
        python-version: [3.11, 3.12]
        go-version: [1.22.x, 1.23.x]
        rust-version: [1.80.0, 1.81.0]
        java-version: [17, 21]

    # B1.8: all actions are SHA-pinned with version comments (ENGINEERING_RULES;
    # supply-chain hardening). SHAs verified against the upstream release tags.
    steps:
    - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2

    - name: Setup Node.js
      uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020  # v4.4.0
      with:
        node-version: ${{ matrix.node-version }}
        cache: 'npm'

    - name: Setup Python
      uses: actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065  # v5.6.0
      with:
        python-version: ${{ matrix.python-version }}

    - name: Setup Go
      uses: actions/setup-go@40f1582b2485089dde7abd97c1529aa768e1baff  # v5.6.0
      with:
        go-version: ${{ matrix.go-version }}

    - name: Setup Rust
      run: |
        rustup toolchain install "${{ matrix.rust-version }}" --profile minimal
        rustup default "${{ matrix.rust-version }}"

    - name: Setup Java
      uses: actions/setup-java@cf277c60eb25467037889841efdb72551f06f6c3  # v4.9.1
      with:
        distribution: 'temurin'
        java-version: ${{ matrix.java-version }}

    - name: Install dependencies
      run: |
        npm ci
        pip install -r requirements.txt

    - name: Run version manager health check
      run: |
        ./version-manager.sh health-check

    - name: Run tests
      run: |
        npm test
EOF
    _va_publish "$workflow_file" "$staged" || return 1

    _va_report "GitHub Actions workflow" "$workflow_file"
}

# Generate GitLab CI configuration
generate_gitlab_ci() {
    validate_project_dir || return 1

    local ci_file=".gitlab-ci.yml"

    local staged
    staged=$(_va_stage) || return 1
    cat > "$staged" << 'EOF' || { rm -f -- "$staged"; return 1; }
stages:
  - test

variables:
  NODE_VERSION: "20.19.2"
  PYTHON_VERSION: "3.12.11"
  GO_VERSION: "1.23.4"
  RUST_VERSION: "1.81.0"
  JAVA_VERSION: "17.0.12"

before_script:
  - echo "Using official language images; pin image digests for stricter supply-chain control."

test-job:
  stage: test
  image: node:${NODE_VERSION}
  script:
    - ./version-manager.sh health-check
    - npm test

python-test:
  stage: test
  image: python:${PYTHON_VERSION}
  script:
    - python --version
    - if [ -f requirements.txt ]; then pip install -r requirements.txt; fi

go-test:
  stage: test
  image: golang:${GO_VERSION}
  script:
    - go version

rust-test:
  stage: test
  image: rust:${RUST_VERSION}
  script:
    - rustc --version

java-test:
  stage: test
  image: eclipse-temurin:${JAVA_VERSION}
  script:
    - java -version
EOF
    _va_publish "$ci_file" "$staged" || return 1

    _va_report "GitLab CI configuration" "$ci_file"
}

# Generate CircleCI configuration
generate_circleci() {
    validate_project_dir || return 1

    local circleci_dir=".circleci"
    _va_ensure_dir "$circleci_dir" || return 1

    local config_file="$circleci_dir/config.yml"

    local staged
    staged=$(_va_stage) || return 1
    cat > "$staged" << 'EOF' || { rm -f -- "$staged"; return 1; }
version: 2.1

jobs:
  test:
    parameters:
      node-version:
        type: string
        default: "20.19.2"
    docker:
      - image: "cimg/node:<< parameters.node-version >>"
    steps:
      - checkout
      - run:
          name: Install dependencies
          command: |
            npm ci
      - run:
          name: Run version manager health check
          command: |
            ./version-manager.sh health-check

      - run:
          name: Run tests
          command: |
            npm test

  python-test:
    parameters:
      python-version:
        type: string
        default: "3.12.11"
    docker:
      - image: "cimg/python:<< parameters.python-version >>"
    steps:
      - checkout
      - run:
          name: Check Python
          command: |
            python --version
            if [ -f requirements.txt ]; then pip install -r requirements.txt; fi

  go-test:
    parameters:
      go-version:
        type: string
        default: "1.23.4"
    docker:
      - image: "cimg/go:<< parameters.go-version >>"
    steps:
      - checkout
      - run:
          name: Check Go
          command: |
            go version

  rust-test:
    parameters:
      rust-version:
        type: string
        default: "1.81.0"
    docker:
      - image: "cimg/rust:<< parameters.rust-version >>"
    steps:
      - checkout
      - run:
          name: Check Rust
          command: |
            rustc --version

  java-test:
    parameters:
      java-version:
        type: string
        default: "17.0.12"
    docker:
      - image: "cimg/openjdk:<< parameters.java-version >>"
    steps:
      - checkout
      - run:
          name: Check Java
          command: |
            java -version

workflows:
  version-manager-test:
    jobs:
      - test
      - python-test
      - go-test
      - rust-test
      - java-test
EOF
    _va_publish "$config_file" "$staged" || return 1

    _va_report "CircleCI configuration" "$config_file"
}

# Generate Docker CI job for GitHub Actions
generate_docker_ci() {
    validate_project_dir || return 1

    local workflow_dir=".github/workflows"
    _va_ensure_dir "$workflow_dir" || return 1

    local workflow_file="$workflow_dir/docker-build.yml"

    local staged
    staged=$(_va_stage) || return 1
    cat > "$staged" << 'EOF' || { rm -f -- "$staged"; return 1; }
name: Docker Build

on:
  push:
    branches: [ main, master ]
  pull_request:
    branches: [ main, master ]

jobs:
  docker:
    runs-on: ubuntu-latest

    strategy:
      matrix:
        include:
          - name: node
            dockerfile: Dockerfile.node
          - name: python
            dockerfile: Dockerfile.python
          - name: go
            dockerfile: Dockerfile.go
          - name: rust
            dockerfile: Dockerfile.rust
          - name: java
            dockerfile: Dockerfile.java

    # B1.8: all actions are SHA-pinned with version comments.
    steps:
    - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@8d2750c68a42422c14e847fe6c8ac0403b4cbd6f  # v3.12.0

    - name: Build and push Docker images
      uses: docker/build-push-action@ca052bb54ab0790a636c9b5f226502c73d547a25  # v5.4.0
      with:
        context: .
        file: ${{ matrix.dockerfile }}
        push: false
        load: true
        tags: version-manager-${{ matrix.name }}:latest
EOF
    _va_publish "$workflow_file" "$staged" || return 1

    _va_report "Docker CI workflow" "$workflow_file"
}

# Generate all CI/CD templates
generate_all_ci() {
    log_info "Generating all CI/CD templates..."
    generate_github_actions || return 1
    generate_gitlab_ci || return 1
    generate_circleci || return 1
    generate_docker_ci || return 1
    _va_report "All CI/CD templates"
}

# ============================================================================
# Docker Functions
# ============================================================================

# Generate Dockerfile for Node.js projects
# P2-7: multi-stage (builder + distro-slim runtime), non-root USER,
# HEALTHCHECK, artifacts-only copies into the runtime stage.
# shellcheck disable=SC2120  # optional args: callers may omit them (defaults apply)
generate_dockerfile_node() {
    local dockerfile="Dockerfile.node"
    local node_version="${1:-$(cat .nvmrc 2>/dev/null || echo '20.19.2')}"

    local staged
    staged=$(_va_stage) || return 1
    cat > "$staged" << EOF || { rm -f -- "$staged"; return 1; }
# syntax=docker/dockerfile:1
# Node.js multi-stage image (P2-7): full-toolchain builder, distro-slim
# runtime, non-root USER, HEALTHCHECK, artifacts-only runtime copies.
# Adjust build/artifact paths to the project; pin base-image digests for
# stricter supply-chain control.

# ---- Stage 1: builder (full Node toolchain) ----
FROM node:$node_version AS builder
WORKDIR /build
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# ---- Stage 2: runtime (distro-slim, artifacts only) ----
FROM node:$node_version-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /build/package*.json ./
COPY --from=builder /build/node_modules ./node_modules
COPY --from=builder /build/dist ./dist
# P2-7: never run as root (node images ship a uid-1000 'node' user)
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD node -e "require('http').get('http://127.0.0.1:3000/healthz',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))" || exit 1
CMD ["npm", "start"]
EOF
    _va_publish "$dockerfile" "$staged" || return 1

    _va_report "Node.js Dockerfile" "$dockerfile"
}

# Generate Dockerfile for Python projects
# P2-7: multi-stage (builder venv + distro-slim runtime), non-root USER,
# HEALTHCHECK, artifacts-only copies into the runtime stage.
# shellcheck disable=SC2120  # optional args: callers may omit them (defaults apply)
generate_dockerfile_python() {
    local dockerfile="Dockerfile.python"
    local python_version="${1:-$(cat .python-version 2>/dev/null || echo '3.12.11')}"

    local staged
    staged=$(_va_stage) || return 1
    cat > "$staged" << EOF || { rm -f -- "$staged"; return 1; }
# syntax=docker/dockerfile:1
# Python multi-stage image (P2-7): dependencies resolve into a virtualenv
# in the builder, distro-slim runtime, non-root USER, HEALTHCHECK,
# artifacts-only runtime copies. Pin base-image digests for stricter
# supply-chain control.

# ---- Stage 1: builder (dependency resolution + app assembly) ----
FROM python:$python_version AS builder
WORKDIR /build
RUN python -m venv /opt/venv
ENV VIRTUAL_ENV=/opt/venv
ENV PATH="/opt/venv/bin:\$PATH"
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY . .

# ---- Stage 2: runtime (distro-slim, artifacts only) ----
FROM python:$python_version-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser
WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /build/app.py ./app.py
ENV VIRTUAL_ENV=/opt/venv
ENV PATH="/opt/venv/bin:\$PATH"
USER appuser
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD curl -fsS http://127.0.0.1:8000/healthz || exit 1
CMD ["python", "app.py"]
EOF
    _va_publish "$dockerfile" "$staged" || return 1

    _va_report "Python Dockerfile" "$dockerfile"
}

# Generate docker-compose.yml
# shellcheck disable=SC2120  # optional args: callers may omit them (defaults apply)
generate_docker_compose() {
    local compose_file="docker-compose.yml"
    local node_version="${1:-$(cat .nvmrc 2>/dev/null || echo '20.19.2')}"
    local python_version="${2:-$(cat .python-version 2>/dev/null || echo '3.12.11')}"
    local go_version="${3:-$(cat .go-version 2>/dev/null || echo '1.23.4')}"
    local rust_version="${4:-$(cat rust-toolchain 2>/dev/null || echo '1.81.0')}"
    local java_version="${5:-$(cat .java-version 2>/dev/null || echo '17.0.12')}"

    # Each service runs the image its hardened Dockerfile builds. No `.:/app`
    # bind mount (finding AX-16): every template's runtime stage puts its
    # artifact in /app (dist/, server, app.jar), so mounting the source tree
    # there hid it and the container could not start. Host ports are unique —
    # python/rust both listen on 8000 and go/java on 8080 inside the
    # container, and duplicate host ports made `docker compose up` fail.
    local staged
    staged=$(_va_stage) || return 1
    cat > "$staged" << EOF || { rm -f -- "$staged"; return 1; }
version: '3.8'

services:
  node-app:
    build:
      context: .
      dockerfile: Dockerfile.node
    ports:
      - "3000:3000"
    environment:
      - NODE_ENV=development

  python-app:
    build:
      context: .
      dockerfile: Dockerfile.python
    ports:
      - "8000:8000"
    environment:
      - PYTHONPATH=/app

  go-app:
    build:
      context: .
      dockerfile: Dockerfile.go
    ports:
      - "8080:8080"
    environment:
      - GIN_MODE=release

  rust-app:
    build:
      context: .
      dockerfile: Dockerfile.rust
    ports:
      - "8001:8000"

  java-app:
    build:
      context: .
      dockerfile: Dockerfile.java
    ports:
      - "8081:8080"
EOF
    _va_publish "$compose_file" "$staged" || return 1

    _va_report "docker-compose.yml" "$compose_file"
}

# Generate Dockerfile for Go projects
# P2-7: multi-stage (static build in the toolchain builder + distro-slim
# runtime), non-root USER, HEALTHCHECK, binary-only copy.
# shellcheck disable=SC2120  # optional args: callers may omit them (defaults apply)
generate_dockerfile_go() {
    local dockerfile="Dockerfile.go"
    local go_version="${1:-$(cat .go-version 2>/dev/null || echo '1.23.4')}"

    local staged
    staged=$(_va_stage) || return 1
    cat > "$staged" << EOF || { rm -f -- "$staged"; return 1; }
# syntax=docker/dockerfile:1
# Go multi-stage image (P2-7): static build in the Go toolchain builder,
# distro-slim runtime, non-root USER, HEALTHCHECK, binary-only copy.
# Pin base-image digests for stricter supply-chain control.

# ---- Stage 1: builder (Go toolchain) ----
FROM golang:$go_version AS builder
WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/server .

# ---- Stage 2: runtime (distro-slim, artifacts only) ----
FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser
WORKDIR /app
COPY --from=builder /out/server /app/server
USER appuser
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1
CMD ["/app/server"]
EOF
    _va_publish "$dockerfile" "$staged" || return 1

    _va_report "Go Dockerfile" "$dockerfile"
}

# Generate Dockerfile for Rust projects
# P2-7: multi-stage (release build in the toolchain builder + distro-slim
# runtime), non-root USER, HEALTHCHECK, binary-only copy.
# shellcheck disable=SC2120  # optional args: callers may omit them (defaults apply)
generate_dockerfile_rust() {
    local dockerfile="Dockerfile.rust"
    local rust_version="${1:-$(cat rust-toolchain 2>/dev/null || echo '1.81.0')}"

    local staged
    staged=$(_va_stage) || return 1
    cat > "$staged" << EOF || { rm -f -- "$staged"; return 1; }
# syntax=docker/dockerfile:1
# Rust multi-stage image (P2-7): release build in the Rust toolchain
# builder, distro-slim runtime, non-root USER, HEALTHCHECK, binary-only
# copy. Adjust the release binary path to your crate; pin base-image
# digests for stricter supply-chain control.

# ---- Stage 1: builder (Rust toolchain) ----
FROM rust:$rust_version AS builder
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release

# ---- Stage 2: runtime (distro-slim, artifacts only) ----
FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser
WORKDIR /app
COPY --from=builder /build/target/release/app /app/server
USER appuser
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD curl -fsS http://127.0.0.1:8000/healthz || exit 1
CMD ["/app/server"]
EOF
    _va_publish "$dockerfile" "$staged" || return 1

    _va_report "Rust Dockerfile" "$dockerfile"
}

# Generate Dockerfile for Java projects
# P2-7: multi-stage (JDK builder + JRE runtime), non-root USER, HEALTHCHECK,
# jar-only copy. Builder assumes a committed Maven wrapper (./mvnw).
# shellcheck disable=SC2120  # optional args: callers may omit them (defaults apply)
generate_dockerfile_java() {
    local dockerfile="Dockerfile.java"
    local java_version="${1:-$(cat .java-version 2>/dev/null || echo '17.0.12')}"

    local staged
    staged=$(_va_stage) || return 1
    cat > "$staged" << EOF || { rm -f -- "$staged"; return 1; }
# syntax=docker/dockerfile:1
# Java multi-stage image (P2-7): package in the JDK builder (assumes a
# committed Maven wrapper ./mvnw), JRE runtime, non-root USER, HEALTHCHECK,
# jar-only copy. Adjust for Gradle; pin base-image digests for stricter
# supply-chain control.

# ---- Stage 1: builder (JDK + Maven wrapper) ----
FROM eclipse-temurin:$java_version-jdk AS builder
WORKDIR /build
COPY . .
RUN ./mvnw -q -DskipTests package

# ---- Stage 2: runtime (JRE, artifacts only) ----
FROM eclipse-temurin:$java_version-jre AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser
WORKDIR /app
COPY --from=builder /build/target/*.jar app.jar
USER appuser
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD curl -fsS http://127.0.0.1:8080/actuator/health || exit 1
CMD ["java", "-jar", "app.jar"]
EOF
    _va_publish "$dockerfile" "$staged" || return 1

    _va_report "Java Dockerfile" "$dockerfile"
}

# Generate all Docker configurations
generate_docker_configs() {
    log_info "Generating Docker configurations..."
    generate_dockerfile_node || return 1
    generate_dockerfile_python || return 1
    generate_dockerfile_go || return 1
    generate_dockerfile_rust || return 1
    generate_dockerfile_java || return 1
    generate_docker_compose || return 1
    _va_report "Docker configurations"
}

# ============================================================================
# Auto-switching Functions
# ============================================================================

# Configure auto-switching for version managers
configure_auto_switch() {
    log_info "Configuring auto-switching for version managers..."

    # Delegates to THIS checkout's version-manager.sh (AX-18). The old
    # "./version-manager.sh" resolved against the caller's working directory:
    # it failed from any other directory and would execute an unrelated
    # version-manager.sh sitting in the current project.
    local vm="$SCRIPT_DIR/version-manager.sh"
    if [[ ! -f "$vm" ]]; then
        log_error "version-manager.sh not found next to $SCRIPT_NAME ($vm). Cannot configure auto-switching."
        return 1
    fi
    if ! bash "$vm" auto-switch; then
        log_error "Auto-switching configuration failed (see version-manager.sh output above)"
        return 1
    fi
    log_success "Auto-switching configured successfully"
}

# ============================================================================
# Lazy-loading Functions
# ============================================================================

# Configure lazy-loading for version managers
configure_lazy_load() {
    log_info "Configuring lazy-loading for version managers..."

    # Delegates to THIS checkout's version-manager.sh (AX-18). The old
    # "./version-manager.sh" resolved against the caller's working directory:
    # it failed from any other directory and would execute an unrelated
    # version-manager.sh sitting in the current project.
    local vm="$SCRIPT_DIR/version-manager.sh"
    if [[ ! -f "$vm" ]]; then
        log_error "version-manager.sh not found next to $SCRIPT_NAME ($vm). Cannot configure lazy-loading."
        return 1
    fi
    if ! bash "$vm" lazy-load; then
        log_error "Lazy-loading configuration failed (see version-manager.sh output above)"
        return 1
    fi
    log_success "Lazy-loading configured successfully"
}

# ============================================================================
# Main Command Handler
# ============================================================================

show_usage() {
    cat << EOF
${BOLD}Advanced Version Management System v${SCRIPT_VERSION}${RESET}

${BOLD}Usage:${RESET}
  $SCRIPT_NAME <command> [options]

${BOLD}Commands:${RESET}
  ${GREEN}init${RESET}                     Creates baseline configuration files
  ${GREEN}register${RESET} [path]          Registers a project directory
  ${GREEN}auto-switch${RESET}              Installs shell hook scripts for version managers
  ${GREEN}lazy-load${RESET}                Configures deferred initialization for faster shells
  ${GREEN}github-actions${RESET}           Generates GitHub Actions workflow
  ${GREEN}gitlab-ci${RESET}                Generates GitLab CI configuration
  ${GREEN}circleci${RESET}                 Generates CircleCI configuration
  ${GREEN}ci-all${RESET}                   Runs the full suite of CI/CD generators
  ${GREEN}docker${RESET}                   Emits Dockerfile configurations
  ${GREEN}docker-compose${RESET}           Generates docker-compose.yml
  ${GREEN}docker-go${RESET}                Generates Go Dockerfile
  ${GREEN}docker-rust${RESET}              Generates Rust Dockerfile
  ${GREEN}docker-java${RESET}              Generates Java Dockerfile
  ${GREEN}help${RESET}                     Show this help message

${BOLD}Options:${RESET}
  --silent                  Run in silent mode
  --debug                   Enable debug output
  --no-color                Disable colored output
  --dry-run                 Print what would be created/replaced; write nothing

Generated files are published through a backup transaction: an existing
file is backed up before it is replaced (restored if any later file of the
same command fails), unchanged files are left untouched.

${BOLD}Examples:${RESET}
  # Configure automatic version switching
  $SCRIPT_NAME auto-switch

  # Configure lazy loading for faster shell startup
  $SCRIPT_NAME lazy-load

  # Generate all CI/CD templates
  $SCRIPT_NAME ci-all

  # Generate Docker configurations
  $SCRIPT_NAME docker

  # Generate specific language Dockerfiles
  $SCRIPT_NAME docker-go
  $SCRIPT_NAME docker-rust
  $SCRIPT_NAME docker-java

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --silent)
                SILENT_MODE=true
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                shift
                ;;
            --no-color)
                ENABLE_COLORS=false
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    # One word per line (AX-1 parity): `echo "$@"` space-joined the words, so
    # `register <path>` arrived as the single unknown command "register <path>".
    # --dry-run was applied before sourcing (AX-18) and is not a command word.
    local word
    for word in "$@"; do
        [[ "$word" == --dry-run ]] && continue
        printf '%s\n' "$word"
    done
}

# Main function
main() {
    # Initialize (a --dry-run preview writes nothing, not even these dirs)
    if [[ "${TRANSACTION_DRY_RUN:-0}" != "1" ]]; then
        init_directories
    fi

    # Parse arguments
    local args
    mapfile -t args < <(parse_args "$@")
    local command="${args[0]:-help}"

    # Execute command
    case "$command" in
        init)
            log_info "Initializing advanced version management system..."
            if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
                if [[ -f "$CONFIG_FILE" ]]; then
                    log_info "[dry-run] $CONFIG_FILE exists; init would leave it unchanged"
                else
                    log_info "[dry-run] would create $CONFIG_FILE"
                fi
                return 0
            fi
            # Create config directory and basic config file
            mkdir -p "$CONFIG_DIR"
            if [[ ! -f "$CONFIG_FILE" ]]; then
                cat > "$CONFIG_FILE" << EOF
# Advanced Version Manager Configuration
lazy_load: true
auto_switch: true
ci_integration: true
docker_integration: true
EOF
                log_success "Configuration file created at $CONFIG_FILE"
            fi
            ;;
        register)
            log_info "Registering project directory..."
            local path="${args[1]:-.}"
            if [[ "${TRANSACTION_DRY_RUN:-0}" == "1" ]]; then
                log_info "[dry-run] would append $path to $STATE_DIR/projects.txt"
                return 0
            fi
            printf '%s\n' "$path" >> "$STATE_DIR/projects.txt"
            log_success "Project directory registered: $path"
            ;;
        auto-switch)
            configure_auto_switch
            ;;
        lazy-load)
            configure_lazy_load
            ;;
        github-actions)
            _va_generate version_advanced_github_actions generate_github_actions
            ;;
        gitlab-ci)
            _va_generate version_advanced_gitlab_ci generate_gitlab_ci
            ;;
        circleci)
            _va_generate version_advanced_circleci generate_circleci
            ;;
        ci-all)
            _va_generate version_advanced_ci_all generate_all_ci
            ;;
        docker)
            _va_generate version_advanced_docker generate_docker_configs
            ;;
        docker-go)
            _va_generate version_advanced_docker_go generate_dockerfile_go
            ;;
        docker-rust)
            _va_generate version_advanced_docker_rust generate_dockerfile_rust
            ;;
        docker-java)
            _va_generate version_advanced_docker_java generate_dockerfile_java
            ;;
        docker-compose)
            _va_generate version_advanced_docker_compose generate_docker_compose
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# ==============================================================================
# Script Entry Point
# ==============================================================================

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
