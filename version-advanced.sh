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

# ============================================================================
# Color Definitions
# ============================================================================

if [[ "$ENABLE_COLORS" == "true" ]] && [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    WHITE='\033[0;37m'
    BOLD='\033[1m'
    RESET='\033[0m'
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

# Compatibility shim: allow callers that use log "LEVEL" "msg" directly
log() {
    local level="$1"; shift
    case "$level" in
        ERROR)   log_error "$*" ;;
        WARN)    log_warn  "$*" ;;
        INFO)    log_info  "$*" ;;
        SUCCESS) log_success "$*" ;;
        DEBUG)   log_debug "$*" ;;
        *)       log_info  "[$level] $*" ;;
    esac
}

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

# Check if command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Get OS type
get_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "macos" ;;
        CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
        *)       echo "unknown" ;;
    esac
}

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
    if [[ ! -d "$workflow_dir" ]]; then
        mkdir -p "$workflow_dir"
        log_info "Created GitHub Actions workflow directory"
    fi

    local workflow_file="$workflow_dir/version-manager.yml"

    cat > "$workflow_file" << 'EOF'
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

    log_success "GitHub Actions workflow generated at $workflow_file"
}

# Generate GitLab CI configuration
generate_gitlab_ci() {
    validate_project_dir || return 1

    local ci_file=".gitlab-ci.yml"

    cat > "$ci_file" << 'EOF'
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

    log_success "GitLab CI configuration generated at $ci_file"
}

# Generate CircleCI configuration
generate_circleci() {
    validate_project_dir || return 1

    local circleci_dir=".circleci"
    if [[ ! -d "$circleci_dir" ]]; then
        mkdir -p "$circleci_dir"
        log_info "Created CircleCI directory"
    fi

    local config_file="$circleci_dir/config.yml"

    cat > "$config_file" << 'EOF'
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

    log_success "CircleCI configuration generated at $config_file"
}

# Generate Docker CI job for GitHub Actions
generate_docker_ci() {
    validate_project_dir || return 1

    local workflow_dir=".github/workflows"
    if [[ ! -d "$workflow_dir" ]]; then
        mkdir -p "$workflow_dir"
        log_info "Created GitHub Actions workflow directory"
    fi

    local workflow_file="$workflow_dir/docker-build.yml"

    cat > "$workflow_file" << 'EOF'
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

    log_success "Docker CI workflow generated at $workflow_file"
}

# Generate all CI/CD templates
generate_all_ci() {
    log_info "Generating all CI/CD templates..."
    generate_github_actions
    generate_gitlab_ci
    generate_circleci
    generate_docker_ci
    log_success "All CI/CD templates generated successfully"
}

# ============================================================================
# Docker Functions
# ============================================================================

# Generate Dockerfile for Node.js projects
# shellcheck disable=SC2120  # optional args: callers may omit them (defaults apply)
generate_dockerfile_node() {
    local dockerfile="Dockerfile.node"
    local node_version="${1:-$(cat .nvmrc 2>/dev/null || echo '20.19.2')}"

    cat > "$dockerfile" << EOF
# Use Node.js version from .nvmrc or default
FROM node:$node_version

# Set working directory
WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm ci

# Copy application code
COPY . .

# Expose port (adjust as needed)
EXPOSE 3000

# Start command
CMD ["npm", "start"]
EOF

    log_success "Node.js Dockerfile generated at $dockerfile"
}

# Generate Dockerfile for Python projects
# shellcheck disable=SC2120  # optional args: callers may omit them (defaults apply)
generate_dockerfile_python() {
    local dockerfile="Dockerfile.python"
    local python_version="${1:-$(cat .python-version 2>/dev/null || echo '3.12.11')}"

    cat > "$dockerfile" << EOF
# Use Python version from .python-version or default
FROM python:$python_version

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Expose port (adjust as needed)
EXPOSE 8000

# Start command
CMD ["python", "app.py"]
EOF

    log_success "Python Dockerfile generated at $dockerfile"
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

    cat > "$compose_file" << EOF
version: '3.8'

services:
  node-app:
    build:
      context: .
      dockerfile: Dockerfile.node
    ports:
      - "3000:3000"
    volumes:
      - .:/app
      - /app/node_modules
    environment:
      - NODE_ENV=development

  python-app:
    build:
      context: .
      dockerfile: Dockerfile.python
    ports:
      - "8000:8000"
    volumes:
      - .:/app
    environment:
      - PYTHONPATH=/app

  go-app:
    build:
      context: .
      dockerfile: Dockerfile.go
    ports:
      - "8080:8080"
    volumes:
      - .:/app
    environment:
      - GIN_MODE=release

  rust-app:
    build:
      context: .
      dockerfile: Dockerfile.rust
    ports:
      - "8000:8000"
    volumes:
      - .:/app

  java-app:
    build:
      context: .
      dockerfile: Dockerfile.java
    ports:
      - "8080:8080"
    volumes:
      - .:/app
EOF

    log_success "docker-compose.yml generated at $compose_file"
}

# Generate Dockerfile for Go projects
# shellcheck disable=SC2120  # optional args: callers may omit them (defaults apply)
generate_dockerfile_go() {
    local dockerfile="Dockerfile.go"
    local go_version="${1:-$(cat .go-version 2>/dev/null || echo '1.23.4')}"

    cat > "$dockerfile" << EOF
# Use Go version from .go-version or default
FROM golang:$go_version

# Set working directory
WORKDIR /app

# Copy go mod and sum files
COPY go.mod go.sum ./

# Download all dependencies
RUN go mod download

# Copy source code
COPY . .

# Build the application
RUN go build -o main .

# Expose port (adjust as needed)
EXPOSE 8080

# Run the application
CMD ["./main"]
EOF

    log_success "Go Dockerfile generated at $dockerfile"
}

# Generate Dockerfile for Rust projects
# shellcheck disable=SC2120  # optional args: callers may omit them (defaults apply)
generate_dockerfile_rust() {
    local dockerfile="Dockerfile.rust"
    local rust_version="${1:-$(cat rust-toolchain 2>/dev/null || echo '1.81.0')}"

    cat > "$dockerfile" << EOF
# Use Rust version from rust-toolchain or default
FROM rust:$rust_version

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    cmake \
    pkg-config \
    libfreetype6-dev \
    libfontconfig1-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy source code
COPY . .

# Build the application
RUN cargo build --release

# Expose port (adjust as needed)
EXPOSE 8000

# Run the application
CMD ["cargo", "run", "--release"]
EOF

    log_success "Rust Dockerfile generated at $dockerfile"
}

# Generate Dockerfile for Java projects
# shellcheck disable=SC2120  # optional args: callers may omit them (defaults apply)
generate_dockerfile_java() {
    local dockerfile="Dockerfile.java"
    local java_version="${1:-$(cat .java-version 2>/dev/null || echo '17.0.12')}"

    cat > "$dockerfile" << EOF
# Use Java version from .java-version or default
FROM openjdk:$java_version

# Set working directory
WORKDIR /app

# Copy JAR file (adjust filename as needed)
COPY target/*.jar app.jar

# Expose port (adjust as needed)
EXPOSE 8080

# Run the application
CMD ["java", "-jar", "app.jar"]
EOF

    log_success "Java Dockerfile generated at $dockerfile"
}

# Generate all Docker configurations
generate_docker_configs() {
    log_info "Generating Docker configurations..."
    generate_dockerfile_node
    generate_dockerfile_python
    generate_dockerfile_go
    generate_dockerfile_rust
    generate_dockerfile_java
    generate_docker_compose
    log_success "Docker configurations generated successfully"
}

# ============================================================================
# Auto-switching Functions
# ============================================================================

# Configure auto-switching for version managers
configure_auto_switch() {
    log_info "Configuring auto-switching for version managers..."

    # This uses the existing version-manager.sh script for configuration
    if [[ -f "./version-manager.sh" ]]; then
        ./version-manager.sh auto-switch
        log_success "Auto-switching configured successfully"
    else
        log_error "version-manager.sh not found. Cannot configure auto-switching."
        return 1
    fi
}

# ============================================================================
# Lazy-loading Functions
# ============================================================================

# Configure lazy-loading for version managers
configure_lazy_load() {
    log_info "Configuring lazy-loading for version managers..."

    # This uses the existing version-manager.sh script for configuration
    if [[ -f "./version-manager.sh" ]]; then
        ./version-manager.sh lazy-load
        log_success "Lazy-loading configured successfully"
    else
        log_error "version-manager.sh not found. Cannot configure lazy-loading."
        return 1
    fi
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

    echo "$@"
}

# Main function
main() {
    # Initialize
    init_directories

    # Parse arguments
    local args
    mapfile -t args < <(parse_args "$@")
    local command="${args[0]:-help}"

    # Execute command
    case "$command" in
        init)
            log_info "Initializing advanced version management system..."
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
            echo "$path" >> "$STATE_DIR/projects.txt"
            log_success "Project directory registered: $path"
            ;;
        auto-switch)
            configure_auto_switch
            ;;
        lazy-load)
            configure_lazy_load
            ;;
        github-actions)
            generate_github_actions
            ;;
        gitlab-ci)
            generate_gitlab_ci
            ;;
        circleci)
            generate_circleci
            ;;
        ci-all)
            generate_all_ci
            ;;
        docker)
            generate_docker_configs
            ;;
        docker-go)
            generate_dockerfile_go
            ;;
        docker-rust)
            generate_dockerfile_rust
            ;;
        docker-java)
            generate_dockerfile_java
            ;;
        docker-compose)
            generate_docker_compose
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
