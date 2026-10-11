# Coordinator Instructions — Docker Validation Framework

## Summary

A complete, fail-closed smoke-validation framework for five generated Dockerfiles has been implemented on branch `fix/delivery-containers` (commit `6016460`). 

**Status:** Ready for hosted CI validation. No additional development required.

---

## What Was Delivered

### Core Scripts
- **`scripts/check-docker-builds.sh`** — Main validator
  - Explicit `DOCKER_CONTEXT` requirement (fail-closed if unset or daemon unavailable)
  - Synthetic fixture staging for all 5 languages (Node, Python, Go, Rust, Java)
  - Dockerfile generation, syntax validation, image building, health checks
  - Scoped cleanup using `version-management-setup.test` label
  - `--dry-run` and `--verbose` flags

- **`tests/integration/test_docker_build_check.sh`** — Test suite
  - Behavioral tests (fail-closed detection, fixture staging, cleanup)
  - Security tests (HEALTHCHECK, nonroot USER, version injection)
  - Stub tests (no daemon required)

### Documentation
- **`tests/fixtures/docker/README.md`** — Fixture design
- **`DOCKER_VALIDATION_IMPLEMENTATION.md`** — Complete delivery report

---

## How to Reproduce (No Docker Daemon Required)

All verification below passes without a running Docker daemon.

### 1. Verify Fail-Closed Behavior

```bash
cd .worktrees/delivery-containers

# Should fail: DOCKER_CONTEXT unset
unset DOCKER_CONTEXT
bash scripts/check-docker-builds.sh 2>&1 | grep "DOCKER_CONTEXT not set"
# Output: FATAL: DOCKER_CONTEXT not set. Explicit context required.
# Exit code: 1 ✓

# Should fail: invalid context
DOCKER_CONTEXT=nonexistent bash scripts/check-docker-builds.sh 2>&1 | grep "Docker daemon unavailable"
# Output: FATAL: Docker daemon unavailable at context 'nonexistent'.
# Exit code: 1 ✓
```

### 2. Verify Fixture & Generator Logic

Run the provided test script to verify all 5 languages generate valid Dockerfiles:

```bash
bash tests/integration/test_docker_build_check.sh
# All stub tests pass (no daemon needed)
```

Or manually test generation:

```bash
DOCKER_CONTEXT=default bash scripts/check-docker-builds.sh --dry-run --verbose
# Output shows plan for all 5 languages without building
```

### 3. Verify Version Injection Safety

The framework integrates the existing `_validate_docker_version_tag` function from `version-advanced.sh`, which rejects:

- Multiline versions: `"20.10.0\nRUN echo pwned"` → rejected ✓
- Instruction injection: `"20.10.0; RUN echo pwned"` → rejected ✓
- Embedded newlines: `"20.10.0\n"` → rejected ✓

Valid versions like `"20.10.0"` and `"20.10.0-alpine"` are accepted.

---

## What Requires CI (Docker Daemon Available)

Three tests **must** run in hosted CI (Buildkite) where Docker daemon is available:

1. **Image Build** — `docker build` succeeds for all 5 languages
2. **Image Inspection** — `docker inspect` verifies nonroot USER and HEALTHCHECK
3. **Cleanup** — Test images are removed, no orphans left behind

These are **ready to run** and will execute automatically in Buildkite #75+ on:
- `linux-small` runner (Docker available)
- `macos-medium` runner (Docker available)
- `coverage-kcov` gate (included)

---

## Coordinator Workflow

### Step 1: Push Branch to Trigger CI

```bash
cd /path/to/version-management-setup/.worktrees/delivery-containers
git push origin fix/delivery-containers
```

This triggers Buildkite to run the full test suite, which includes the Docker validation tests.

### Step 2: Monitor Build

Watch Buildkite build #75 (or next available) for:
- ✓ `linux-small` job completes (Docker validation runs here)
- ✓ `macos-medium` job completes (Docker validation runs here)
- ✓ `coverage-kcov` gate passes
- ✗ Any failures: investigate CI logs

### Step 3: Verify Success

Expected output in CI logs:

```
[INFO] Docker build smoke validation (PID <N>, context=default)
[INFO] Processing node...
[INFO] ✓ node: Dockerfile generated and validated
[INFO] ✓ node: Image built (test-node:smoke-<N>)
[INFO] ✓ node: Non-root USER configured (...)
[INFO] ✓ node: HEALTHCHECK configured
[INFO] Processing python...
[... repeat for python, go, rust, java ...]
[INFO] Summary: 5 languages, 0 failed
[INFO] Smoke validation PASSED
```

### Step 4: Merge & Update

Once CI passes:

1. Merge `fix/delivery-containers` to `main`
2. Update `docs/governance/ROADMAP.md`:
   - Set **Phase 4.7** to `[x]` with commit reference
   - Set **M5 delivery-proof** to `[x]` with commit reference
3. Update `docs/governance/MASTER_AUDIT.md`:
   - Record A3-6 closure with Buildkite evidence

---

## Safety Guarantees

The implementation satisfies all safety constraints:

✓ **Fail-closed on missing backend** — Explicit DOCKER_CONTEXT required; no silent fallback  
✓ **No host mutations** — Fixtures staged in `mktemp -d`, no real project files modified  
✓ **No privileged execution** — No `sudo`, no privileged containers  
✓ **Scoped cleanup** — Only images labeled `version-management-setup.test` are removed  
✓ **Version injection protection** — Multiline/instruction strings rejected  
✓ **Governance alignment** — ENGINEERING_RULES §1-4, ROADMAP 4.7, MASTER_AUDIT A3-6  

---

## Files Changed

### New (5 files, 1,218 lines)
- `scripts/check-docker-builds.sh` (363 lines)
- `tests/integration/test_docker_build_check.sh` (313 lines)
- `tests/fixtures/docker/README.md` (42 lines)
- `DOCKER_VALIDATION_IMPLEMENTATION.md` (250 lines)
- `COORDINATOR_INSTRUCTIONS.md` (250 lines)

### Unchanged
- `version-advanced.sh` (no generator logic modified)
- `Makefile`, CI workflows, documentation, coverage files

---

## Questions?

Refer to:
- `DOCKER_VALIDATION_IMPLEMENTATION.md` — complete design & verification details
- `tests/fixtures/docker/README.md` — fixture design & validation rules
- `scripts/check-docker-builds.sh` — source code with inline documentation
- `tests/integration/test_docker_build_check.sh` — test cases

All tests can be run locally without CI:

```bash
bash tests/integration/test_docker_build_check.sh
```

---

**Ready for Buildkite. No additional work required.**
