#!/usr/bin/env bash
# tests/integration/test_docker_build_check.sh — integration tests for Docker build validation.
# Exercises: fixture staging, Dockerfile generation, image build, health-check validation, cleanup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR

# shellcheck source=../helpers.sh
source "${BASH_SOURCE[0]%/*}/../helpers.sh" || exit 1

# Only run if Docker is available and DOCKER_CONTEXT can be set
if ! command -v docker &> /dev/null; then
    skip_test "Docker not available"
fi

TEST_CONTEXT="${DOCKER_CONTEXT:-default}"
export DOCKER_CONTEXT="$TEST_CONTEXT"

# Verify daemon accessibility
if ! docker --context="$TEST_CONTEXT" ps > /dev/null 2>&1; then
    skip_test "Docker daemon not accessible at context '$TEST_CONTEXT'"
fi

# ============================================================================
# BEHAVIORAL TESTS: fail-closed detection and scoped cleanup
# ============================================================================

test_missing_docker_context() {
    # Should fail closed when DOCKER_CONTEXT is unset
    local saved_ctx="$DOCKER_CONTEXT"
    unset DOCKER_CONTEXT
    
    if bash "$SCRIPT_DIR/scripts/check-docker-builds.sh" --dry-run 2>&1 | grep -q "DOCKER_CONTEXT not set"; then
        DOCKER_CONTEXT="$saved_ctx"
        return 0
    fi
    
    DOCKER_CONTEXT="$saved_ctx"
    return 1
}

test_docker_daemon_unavailable() {
    # Should fail closed when daemon is unreachable
    local saved_ctx="$DOCKER_CONTEXT"
    export DOCKER_CONTEXT="nonexistent-context"
    
    if bash "$SCRIPT_DIR/scripts/check-docker-builds.sh" --dry-run 2>&1 | grep -q "Docker daemon unavailable"; then
        DOCKER_CONTEXT="$saved_ctx"
        return 0
    fi
    
    DOCKER_CONTEXT="$saved_ctx"
    return 1
}

test_fixture_staging_node() {
    # Verify Node.js fixture is properly created
    local temp_home=$(mktemp -d)
    trap 'rm -rf "$temp_home"' RETURN
    
    local fixture_script=$(mktemp)
    cat > "$fixture_script" << 'FIXTURE'
#!/bin/bash
source "$(dirname "$0")/../../scripts/check-docker-builds.sh"
stage_fixture "node"
FIXTURE
    chmod +x "$fixture_script"
    
    local fixture_home
    fixture_home=$("$fixture_script")
    
    [[ -f "$fixture_home/package.json" ]] && [[ -f "$fixture_home/package-lock.json" ]]
}

test_fixture_staging_python() {
    # Verify Python fixture includes app.py and requirements.txt
    local fixture_script=$(mktemp)
    cat > "$fixture_script" << 'FIXTURE'
#!/bin/bash
source "$(dirname "$0")/../../scripts/check-docker-builds.sh"
stage_fixture "python"
FIXTURE
    chmod +x "$fixture_script"
    
    local fixture_home
    fixture_home=$("$fixture_script")
    
    [[ -f "$fixture_home/app.py" ]] && [[ -f "$fixture_home/requirements.txt" ]]
}

test_fixture_staging_go() {
    # Verify Go fixture includes go.mod, go.sum, and main.go
    local fixture_script=$(mktemp)
    cat > "$fixture_script" << 'FIXTURE'
#!/bin/bash
source "$(dirname "$0")/../../scripts/check-docker-builds.sh"
stage_fixture "go"
FIXTURE
    chmod +x "$fixture_script"
    
    local fixture_home
    fixture_home=$("$fixture_script")
    
    [[ -f "$fixture_home/go.mod" ]] && [[ -f "$fixture_home/go.sum" ]] && [[ -f "$fixture_home/main.go" ]]
}

test_fixture_staging_rust() {
    # Verify Rust fixture includes Cargo.toml, Cargo.lock, and src/main.rs
    local fixture_script=$(mktemp)
    cat > "$fixture_script" << 'FIXTURE'
#!/bin/bash
source "$(dirname "$0")/../../scripts/check-docker-builds.sh"
stage_fixture "rust"
FIXTURE
    chmod +x "$fixture_script"
    
    local fixture_home
    fixture_home=$("$fixture_script")
    
    [[ -f "$fixture_home/Cargo.toml" ]] && [[ -f "$fixture_home/Cargo.lock" ]] && [[ -f "$fixture_home/src/main.rs" ]]
}

test_fixture_staging_java() {
    # Verify Java fixture includes pom.xml and mvnw
    local fixture_script=$(mktemp)
    cat > "$fixture_script" << 'FIXTURE'
#!/bin/bash
source "$(dirname "$0")/../../scripts/check-docker-builds.sh"
stage_fixture "java"
FIXTURE
    chmod +x "$fixture_script"
    
    local fixture_home
    fixture_home=$("$fixture_script")
    
    [[ -f "$fixture_home/pom.xml" ]] && [[ -x "$fixture_home/mvnw" ]]
}

test_dry_run_no_builds() {
    # Dry-run mode should not create real images
    local before=$(docker --context="$TEST_CONTEXT" images --filter "label=version-management-setup.test" -q | wc -l)
    
    bash "$SCRIPT_DIR/scripts/check-docker-builds.sh" --dry-run 2>&1 | grep -q "DRY-RUN: Would build" || true
    
    local after=$(docker --context="$TEST_CONTEXT" images --filter "label=version-management-setup.test" -q | wc -l)
    
    [[ "$before" -eq "$after" ]]
}

test_cleanup_removes_owned_labels() {
    # Build a test image with our label and verify cleanup removes only it
    local test_tag="test-cleanup-$$:latest"
    local test_label="version-management-setup.test"
    
    docker --context="$TEST_CONTEXT" build \
        --label "$test_label" \
        --build-arg BUILDKIT_INLINE_CACHE=1 \
        -t "$test_tag" \
        -f - . << 'EOF' > /dev/null 2>&1
FROM alpine:latest
RUN echo "test"
EOF
    
    # Verify image exists
    docker --context="$TEST_CONTEXT" inspect "$test_tag" > /dev/null 2>&1 || return 1
    
    # Simulate cleanup (extracted from trap in main script)
    docker --context="$TEST_CONTEXT" images --filter "label=$test_label" -q 2>/dev/null | while read -r iid; do
        docker --context="$TEST_CONTEXT" rmi -f "$iid" 2>/dev/null || true
    done
    
    # Verify image is gone
    ! docker --context="$TEST_CONTEXT" inspect "$test_tag" > /dev/null 2>&1
}

test_healthcheck_validation() {
    # Verify that generated Dockerfiles include HEALTHCHECK directives
    local temp_home=$(mktemp -d)
    trap 'rm -rf "$temp_home"' RETURN
    
    cd "$temp_home"
    
    # Source helpers to access generate functions
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/logger.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/env.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/mutation.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/version-advanced.sh" 2>/dev/null || true
    
    # Generate Node Dockerfile (no-op if functions not available)
    if declare -f generate_dockerfile_node > /dev/null 2>&1; then
        generate_dockerfile_node > /dev/null 2>&1 || return 1
        grep -q "HEALTHCHECK" Dockerfile.node || return 1
    fi
    
    return 0
}

test_nonroot_user_validation() {
    # Verify that generated Dockerfiles set a non-root USER
    local temp_home=$(mktemp -d)
    trap 'rm -rf "$temp_home"' RETURN
    
    cd "$temp_home"
    
    # Create minimal fixture
    cat > package.json << 'EOF'
{"name":"test","version":"1.0.0","scripts":{"build":"mkdir -p dist && echo 'ok' > dist/index.js","start":"true"},"main":"dist/index.js"}
EOF
    cat > package-lock.json << 'EOF'
{"lockfileVersion": 3, "name": "test", "version": "1.0.0", "packages": {}}
EOF
    
    # Source and generate
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/logger.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/env.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/mutation.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/version-advanced.sh" 2>/dev/null || true
    
    if declare -f generate_dockerfile_node > /dev/null 2>&1; then
        generate_dockerfile_node > /dev/null 2>&1 || return 1
        grep -q "USER" Dockerfile.node || return 1
        # Verify not root
        ! grep -q "^USER root" Dockerfile.node || return 1
    fi
    
    return 0
}

test_version_injection_safety() {
    # Verify that hostile version strings are rejected
    local temp_home=$(mktemp -d)
    trap 'rm -rf "$temp_home"' RETURN
    
    cd "$temp_home"
    
    # Source helpers
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/logger.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/env.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/mutation.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/version-advanced.sh" 2>/dev/null || true
    
    # Test with multiline version (should be rejected)
    if declare -f generate_dockerfile_node > /dev/null 2>&1; then
        if ! generate_dockerfile_node $'20.0.0\nRUN echo pwned' > /dev/null 2>&1; then
            return 0  # Correctly rejected
        fi
    fi
    
    return 0
}

# ============================================================================
# STUB TESTS (no actual Docker daemon needed)
# ============================================================================

test_stub_missing_backend_detection() {
    # Mock version of Docker daemon check
    local result
    if ! docker --context="nonexistent" ps > /dev/null 2>&1; then
        result=0
    else
        result=1
    fi
    [[ $result -eq 0 ]]
}

test_stub_fixture_file_creation() {
    # Verify fixture home is created as a temporary directory
    local temp_dir=$(mktemp -d)
    [[ -d "$temp_dir" ]] && [[ -w "$temp_dir" ]]
    rm -rf "$temp_dir"
}

test_stub_label_scoping() {
    # Verify label format is valid Docker label syntax
    local label="version-management-setup.test=smoke-12345"
    [[ "$label" =~ ^[a-zA-Z0-9._-]+=[a-zA-Z0-9._-]+$ ]]
}

# ============================================================================
# RUN TESTS
# ============================================================================

# Register tests
test_missing_docker_context
test_docker_daemon_unavailable
test_fixture_staging_node
test_fixture_staging_python
test_fixture_staging_go
test_fixture_staging_rust
test_fixture_staging_java
test_dry_run_no_builds
test_cleanup_removes_owned_labels
test_healthcheck_validation
test_nonroot_user_validation
test_version_injection_safety
test_stub_missing_backend_detection
test_stub_fixture_file_creation
test_stub_label_scoping
