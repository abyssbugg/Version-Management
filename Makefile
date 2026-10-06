# Makefile for testing
# Professional Development Environment Automation Suite

.PHONY: test test-unit test-integration test-all coverage coverage-kcov lint help clean
.PHONY: test-env test-logger test-cache test-backup
.PHONY: test-gvm test-jenv test-rustup test-theme test-advanced

# Default target — routed through tests/test_runner.sh via the manifest
# emitter (A1: the previous for-loop's exit status was the last iteration
# only, masking every earlier failure). One invocation -> one manifest.
test:
	@echo "=== Running All Tests (via tests/test_runner.sh, emitting manifest) ==="
	@bash tests/emit-manifest.sh

# Run all unit tests
test-unit:
	@echo "=== Running Unit Tests (via tests/test_runner.sh) ==="
	@bash tests/emit-manifest.sh unit

# Run all integration tests
test-integration:
	@echo "=== Running Integration Tests (via tests/test_runner.sh) ==="
	@bash tests/emit-manifest.sh integration

# Run absolutely all tests
test-all: test

# ============================================================================
# Individual Unit Test Targets
# ============================================================================

# Core library tests
test-env:
	@echo "=== Testing lib/env.sh ==="
	@bash tests/unit/test_env.sh

test-logger:
	@echo "=== Testing lib/logger.sh ==="
	@bash tests/unit/test_logger.sh

test-cache:
	@echo "=== Testing lib/cache.sh ==="
	@bash tests/unit/test_cache.sh

test-backup:
	@echo "=== Testing lib/backup.sh ==="
	@bash tests/unit/test_backup.sh

# Version manager tests
test-gvm:
	@echo "=== Testing lib/gvm.sh (Go) ==="
	@bash tests/unit/test_gvm.sh

test-jenv:
	@echo "=== Testing lib/jenv.sh (Java) ==="
	@bash tests/unit/test_jenv.sh

test-rustup:
	@echo "=== Testing lib/rustup.sh (Rust) ==="
	@bash tests/unit/test_rustup.sh

# Theme and advanced tests
test-theme:
	@echo "=== Testing lib/theme-ops.sh ==="
	@bash tests/unit/test_theme_ops.sh

test-advanced:
	@echo "=== Testing version-advanced.sh ==="
	@bash tests/unit/test_version_advanced.sh

# ============================================================================
# Integration Test Targets
# ============================================================================

test-setup:
	@echo "=== Testing setup integration ==="
	@bash tests/integration/test_setup.sh

test-nvm-fixes:
	@echo "=== Testing NVM fixes integration ==="
	@bash tests/integration/test_nvm_fixes.sh

test-version-manager:
	@echo "=== Testing version manager integration ==="
	@bash tests/integration/test_version_manager.sh

# ============================================================================
# Coverage and Reporting
# ============================================================================

coverage: test
	@echo "=== Coverage Report ==="
	@if [ -f .coverage ]; then sort .coverage | uniq -c | sort -nr; else echo "No coverage data"; fi

# Real line coverage (ROADMAP 4.5 / P1-11 / B2.6): the unit suite runs under
# kcov with --include-path=lib, writing coverage/ (HTML + cobertura.xml).
# The `coverage` target above is INTENT TRACKING only (tests/helpers.sh
# manual function markers), never a line-coverage signal.
coverage-kcov:
	@command -v kcov >/dev/null 2>&1 || { \
		echo "coverage-kcov: kcov not found in PATH — failing closed." >&2; \
		echo "  Install kcov (apt-get install kcov / brew install kcov) or run the coverage-kcov Buildkite job." >&2; \
		exit 1; \
	}
	@rm -rf coverage
	@echo "=== Running Unit Suite under kcov (--include-path=lib) ==="
	@bash tests/test_runner.sh coverage
	@echo "=== kcov coverage written to coverage/ (index: coverage/index.html) ==="

# ============================================================================
# Quality Assurance
# ============================================================================

lint:
	@echo "=== Running ShellCheck ==="
	@./scripts/lint-shell.sh

validate:
	@echo "=== Validating All Scripts ==="
	@./tools/validate-quality.sh

syntax-check:
	@echo "=== Checking Syntax (fail-closed bash -n + zsh -n) ==="
	@bash scripts/syntax-check.sh

# ============================================================================
# Utility Targets
# ============================================================================

test-watch:
	@echo "Starting test watch mode. Install fswatch or inotifywait for this to work."
	@echo "Example: fswatch -o tests/ | xargs -n1 -I{} make test"

clean:
	@echo "=== Cleaning temporary files (scoped: project temp root + test-results/) ==="
	@rm -f .coverage
	# B2.2: no global wildcards. Clean ONLY this project's temp root
	# ($${TMPDIR:-/tmp}/version-management-setup/ — $$ makes the *shell*
	# expand TMPDIR; make would see an undefined variable) and the
	# repo-local test-results/ directory. Unrelated /tmp/test_* files
	# belonging to other software are never touched.
	@rm -rf "$${TMPDIR:-/tmp}/version-management-setup/" test-results/

# ============================================================================
# Help
# ============================================================================

help:
	@echo "Professional Development Environment Automation Suite - Test Targets"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Main targets:"
	@echo "  test              - Run all tests via test_runner.sh (emits test-results/manifest.json)"
	@echo "  test-unit         - Run unit tests via test_runner.sh"
	@echo "  test-integration  - Run integration tests via test_runner.sh"
	@echo "  test-all          - Alias for test"
	@echo ""
	@echo "Individual unit tests:"
	@echo "  test-env          - Test lib/env.sh"
	@echo "  test-logger       - Test lib/logger.sh"
	@echo "  test-cache        - Test lib/cache.sh"
	@echo "  test-backup       - Test lib/backup.sh"
	@echo "  test-gvm          - Test lib/gvm.sh (Go)"
	@echo "  test-jenv         - Test lib/jenv.sh (Java)"
	@echo "  test-rustup       - Test lib/rustup.sh (Rust)"
	@echo "  test-theme        - Test lib/theme-ops.sh"
	@echo "  test-advanced     - Test version-advanced.sh"
	@echo ""
	@echo "Integration tests:"
	@echo "  test-setup        - Test setup integration"
	@echo "  test-nvm-fixes    - Test NVM fixes integration"
	@echo "  test-version-manager - Test version manager integration"
	@echo ""
	@echo "Quality assurance:"
	@echo "  lint              - Run ShellCheck on all scripts"
	@echo "  validate          - Run quality validation"
	@echo "  syntax-check      - Check syntax of all scripts"
	@echo "  coverage          - Pseudo-coverage report (intent tracking, not line coverage)"
	@echo "  coverage-kcov     - Real line coverage via kcov over the unit suite (fails closed without kcov)"
	@echo ""
	@echo "Utilities:"
	@echo "  clean             - Remove this project's temp files (scoped, B2.2)"
	@echo "  help              - Show this help message"
