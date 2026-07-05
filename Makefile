# Makefile for testing
# Professional Development Environment Automation Suite

.PHONY: test test-unit test-integration test-all coverage lint help
.PHONY: test-env test-logger test-cache test-backup
.PHONY: test-gvm test-jenv test-rustup test-theme test-advanced

# Default target
test: test-unit test-integration

# Run all unit tests
test-unit:
	@echo "=== Running Unit Tests ==="
	@for f in tests/unit/*.sh; do (cd "$$(dirname "$$f")" && bash "$$(basename "$$f")"); done

# Run all integration tests
test-integration:
	@echo "=== Running Integration Tests ==="
	@for f in tests/integration/*.sh; do (cd "$$(dirname "$$f")" && bash "$$(basename "$$f")"); done

# Run absolutely all tests
test-all: test-unit test-integration
	@echo "=== All Tests Complete ==="

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
	@echo "=== Checking Syntax ==="
	@find . -name '*.sh' -not -path './backups/*' -exec bash -n {} \; -print

# ============================================================================
# Utility Targets
# ============================================================================

test-watch:
	@echo "Starting test watch mode. Install fswatch or inotifywait for this to work."
	@echo "Example: fswatch -o tests/ | xargs -n1 -I{} make test"

clean:
	@echo "=== Cleaning temporary files ==="
	@rm -f .coverage
	@rm -rf /tmp/test_*

# ============================================================================
# Help
# ============================================================================

help:
	@echo "Professional Development Environment Automation Suite - Test Targets"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Main targets:"
	@echo "  test              - Run all unit and integration tests"
	@echo "  test-unit         - Run all unit tests"
	@echo "  test-integration  - Run all integration tests"
	@echo "  test-all          - Run absolutely all tests"
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
	@echo "  coverage          - Generate coverage report"
	@echo ""
	@echo "Utilities:"
	@echo "  clean             - Remove temporary test files"
	@echo "  help              - Show this help message"
