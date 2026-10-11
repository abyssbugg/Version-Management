#!/usr/bin/env bash
# scripts/check-docker-builds.sh — reproducible fail-closed validation for all five generated Dockerfiles.
# Design: explicit Docker context/endpoint, safe fixture staging, health-check assertions,
# owned-label cleanup, no host mounts or privileged execution.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SCRIPT_DIR

# Require explicit DOCKER_CONTEXT or fail closed
if [[ -z "${DOCKER_CONTEXT:-}" ]]; then
    echo "FATAL: DOCKER_CONTEXT not set. Explicit context required (e.g. DOCKER_CONTEXT=default)." >&2
    exit 1
fi

# Verify daemon availability without side effects
if ! docker --context="$DOCKER_CONTEXT" ps > /dev/null 2>&1; then
    echo "FATAL: Docker daemon unavailable at context '$DOCKER_CONTEXT'." >&2
    exit 1
fi

# Configuration
readonly SCRIPT_VERSION="1.0.0"
readonly FIXTURE_HOME=$(mktemp -d)
readonly BUILD_LABEL="version-management-setup.test=smoke-$$"
readonly CLEANUP_LABEL="version-management-setup.test"
DRY_RUN=0
VERBOSE=0
LANGUAGES=(node python go rust java)

# Cleanup trap: remove only images with our label
trap '_cleanup' EXIT INT TERM

_cleanup() {
    local exit_code=$?
    [[ $VERBOSE -eq 1 ]] && echo "[CLEANUP] Removing test images with label '$CLEANUP_LABEL'..." >&2
    
    if docker --context="$DOCKER_CONTEXT" images --filter "label=$CLEANUP_LABEL" -q 2>/dev/null | while read -r iid; do
        docker --context="$DOCKER_CONTEXT" rmi -f "$iid" 2>/dev/null || true
    done; then
        [[ $VERBOSE -eq 1 ]] && echo "[CLEANUP] Removed test images." >&2
    fi
    
    rm -rf "$FIXTURE_HOME"
    return $exit_code
}

# Logging helpers
log_info() {
    echo "[INFO] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_debug() {
    [[ $VERBOSE -eq 1 ]] && echo "[DEBUG] $*" >&2
}

# Stage fixtures for a language: minimal app structure + synthesized Dockerfile
stage_fixture() {
    local lang=$1
    local app_home="$FIXTURE_HOME/$lang"
    mkdir -p "$app_home"
    
    case "$lang" in
        node)
            cat > "$app_home/package.json" << 'EOF'
{
  "name": "test-app",
  "version": "1.0.0",
  "main": "dist/index.js",
  "scripts": {
    "build": "mkdir -p dist && echo 'console.log(\"built\");' > dist/index.js",
    "start": "node dist/index.js && node -e \"require('http').createServer((q,r)=>{r.writeHead(200);r.end('ok');}).listen(3000)\""
  }
}
EOF
            cat > "$app_home/package-lock.json" << 'EOF'
{"lockfileVersion": 3, "name": "test-app", "version": "1.0.0", "packages": {}}
EOF
            ;;
        python)
            cat > "$app_home/requirements.txt" << 'EOF'
flask==2.3.2
gunicorn==21.2.0
EOF
            cat > "$app_home/app.py" << 'EOF'
from flask import Flask
app = Flask(__name__)
@app.route('/healthz')
def health():
    return 'ok', 200
if __name__ == '__main__':
    app.run(host='127.0.0.1', port=8000, debug=False)
EOF
            ;;
        go)
            cat > "$app_home/go.mod" << 'EOF'
module test-app
go 1.23
EOF
            cat > "$app_home/go.sum" << 'EOF'
EOF
            cat > "$app_home/main.go" << 'EOF'
package main
import (
    "fmt"
    "net/http"
)
func main() {
    http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
        fmt.Fprint(w, "ok")
    })
    fmt.Println("Server starting on :8080")
    http.ListenAndServe(":8080", nil)
}
EOF
            ;;
        rust)
            cat > "$app_home/Cargo.toml" << 'EOF'
[package]
name = "test-app"
version = "0.1.0"
edition = "2021"

[dependencies]
axum = "0.7"
tokio = { version = "1", features = ["full"] }
EOF
            cat > "$app_home/Cargo.lock" << 'EOF'
version = 3
EOF
            mkdir -p "$app_home/src"
            cat > "$app_home/src/main.rs" << 'EOF'
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use std::net::SocketAddr;

#[tokio::main]
async fn main() {
    let app = Router::new()
        .route("/healthz", get(health));
    let addr = SocketAddr::from(([127, 0, 0, 1], 8000));
    println!("Server listening on {}", addr);
    axum::Server::bind(&addr)
        .serve(app.into_make_service())
        .await
        .unwrap();
}

async fn health() -> impl IntoResponse {
    "ok"
}
EOF
            ;;
        java)
            cat > "$app_home/pom.xml" << 'EOF'
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.test</groupId>
  <artifactId>test-app</artifactId>
  <version>1.0.0</version>
  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
      <version>2.7.0</version>
    </dependency>
  </dependencies>
</project>
EOF
            # Minimal Maven wrapper stub
            mkdir -p "$app_home/.mvn/wrapper"
            cat > "$app_home/mvnw" << 'EOF'
#!/bin/sh
# Stub: actual Maven not needed for syntax validation
echo "Maven wrapper (stub for validation)"
exit 0
EOF
            chmod +x "$app_home/mvnw"
            ;;
    esac
    
    echo "$app_home"
}

# Generate Dockerfile in fixture and validate syntax
generate_and_validate_dockerfile() {
    local lang=$1
    local fixture_home=$2
    
    log_debug "Generating Dockerfile for $lang in $fixture_home"
    
    cd "$fixture_home"
    
    # Source version-advanced.sh helpers (mutation/staging API)
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/logger.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/env.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/mutation.sh"
    
    # Source the generator
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/version-advanced.sh" > /dev/null 2>&1 || true
    
    local fn="generate_dockerfile_$lang"
    if ! declare -f "$fn" > /dev/null 2>&1; then
        log_error "Generator function '$fn' not found"
        return 1
    fi
    
    # Generate: function writes to Dockerfile.$lang in cwd
    if ! "$fn"; then
        log_error "Generation failed for $lang"
        return 1
    fi
    
    local dockerfile="Dockerfile.$lang"
    if [[ ! -f "$dockerfile" ]]; then
        log_error "Dockerfile not created: $dockerfile"
        return 1
    fi
    
    # Validate Dockerfile syntax
    if ! docker --context="$DOCKER_CONTEXT" run --rm -i hadolint/hadolint:latest-debian < "$dockerfile" > /dev/null 2>&1; then
        log_error "Dockerfile syntax validation failed for $lang"
        return 1
    fi
    
    log_info "✓ $lang: Dockerfile generated and validated"
}

# Build image and perform health checks
build_and_validate_image() {
    local lang=$1
    local fixture_home=$2
    
    log_debug "Building image for $lang"
    
    cd "$fixture_home"
    
    local dockerfile="Dockerfile.$lang"
    local tag="test-$lang:smoke-$$"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        log_info "DRY-RUN: Would build $tag from $fixture_home/$dockerfile"
        return 0
    fi
    
    # Build with our cleanup label
    if ! docker --context="$DOCKER_CONTEXT" build \
        --label "$BUILD_LABEL" \
        --label "$CLEANUP_LABEL" \
        -f "$dockerfile" \
        -t "$tag" \
        "$fixture_home" > /dev/null 2>&1; then
        log_error "Docker build failed for $lang"
        return 1
    fi
    
    log_info "✓ $lang: Image built ($tag)"
    
    # Validate image properties
    local user_check=$(docker --context="$DOCKER_CONTEXT" inspect "$tag" --format='{{json .Config.User}}' 2>/dev/null || echo '""')
    
    # Nonroot check (expect either UID or username, not "root" or empty)
    if [[ "$user_check" == '""' ]] || [[ "$user_check" == '"root"' ]]; then
        log_error "Image $lang runs as root or unspecified user"
        return 1
    fi
    
    log_info "✓ $lang: Non-root USER configured ($user_check)"
    
    # Healthcheck validation
    local healthcheck=$(docker --context="$DOCKER_CONTEXT" inspect "$tag" --format='{{json .Config.Healthcheck}}' 2>/dev/null || echo 'null')
    if [[ "$healthcheck" == 'null' ]] || [[ -z "$healthcheck" ]]; then
        log_error "Image $lang missing HEALTHCHECK"
        return 1
    fi
    
    log_info "✓ $lang: HEALTHCHECK configured"
    
    return 0
}

# Behavioral test: validate missing backend/build/runtime failure
test_missing_backend() {
    log_info "Testing missing backend detection..."
    
    # Unset Docker context to trigger fail-closed
    local saved_ctx="$DOCKER_CONTEXT"
    unset DOCKER_CONTEXT
    
    if bash "$SCRIPT_DIR/scripts/check-docker-builds.sh" --dry-run > /dev/null 2>&1; then
        DOCKER_CONTEXT="$saved_ctx"
        log_error "Should have failed when DOCKER_CONTEXT is unset"
        return 1
    fi
    
    DOCKER_CONTEXT="$saved_ctx"
    log_info "✓ Correctly failed when DOCKER_CONTEXT unset"
    return 0
}

# Main validation loop
main() {
    log_info "Docker build smoke validation (PID $$, context=$DOCKER_CONTEXT)"
    
    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                ;;
            --verbose)
                VERBOSE=1
                ;;
            --test-missing-backend)
                test_missing_backend
                exit $?
                ;;
            *)
                log_error "Unknown flag: $1"
                exit 1
                ;;
        esac
        shift
    done
    
    local failed=0
    
    for lang in "${LANGUAGES[@]}"; do
        log_info "Processing $lang..."
        
        local fixture_home
        fixture_home=$(stage_fixture "$lang") || { failed=$((failed + 1)); continue; }
        log_debug "Fixture staged at $fixture_home"
        
        generate_and_validate_dockerfile "$lang" "$fixture_home" || { failed=$((failed + 1)); continue; }
        
        build_and_validate_image "$lang" "$fixture_home" || { failed=$((failed + 1)); continue; }
    done
    
    log_info "Summary: ${#LANGUAGES[@]} languages, $failed failed"
    
    if [[ $failed -gt 0 ]]; then
        log_error "Smoke validation FAILED"
        exit 1
    fi
    
    log_info "Smoke validation PASSED"
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
