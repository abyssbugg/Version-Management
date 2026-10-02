#!/usr/bin/env bash
# =============================================================================
# Seeded-Failure Meta-Tests (remediation directive Rule 5 / M0 step 4)
# =============================================================================
# "Every gate must fail closed under a seeded failure. A gate that has never
# been observed red is not a gate."
#
# Each case clones the COMMITTED tree (HEAD) into a throwaway directory,
# injects a deliberate failure, and asserts the real gate exits nonzero —
# plus a green positive control where cheap. Clones test exactly what CI
# sees; uncommitted working-tree state is deliberately out of scope.
#
# Failure accounting: every assertion inside a case feeds that case's local
# counter and the case returns it — a mid-case failure can never be masked by
# later passing assertions (the false-green this file itself once shipped;
# caught by a standalone container probe).
#
# Cases:
#   1. A1 routing  — failing test file in a NON-FINAL position turns the
#                    manifest-emitting test gate red, with the file's own
#                    exit code recorded (the old for-loop masked this)
#   2. B1.4 bash   — invalid Bash file turns the syntax gate red
#   3. B1.4 zsh    — invalid Zsh file turns the syntax gate red (and a
#                    missing zsh binary fails closed as well)
#   4. B1.7        — a ShellCheck finding turns the zero-tolerance quality
#                    gate red
#   5. Comparator  — identical manifests pass; a mismatched or malformed
#                    manifest fails the parity check (the comparator itself
#                    must be able to fail)
# =============================================================================

source ../helpers.sh

# Own posture: accumulate failures across all meta-cases; never abort early
# (a skipped later case would hide whether its gate also fails closed).
set +e

ROOT_DIR="$(cd "$(pwd)/../.." && pwd)"

_new_clone() {
    local clone
    clone="$(mktemp -d "${TMPDIR:-/tmp}/vms-meta-clone.XXXXXX")" || return 1
    if ! git clone -q "$ROOT_DIR" "$clone" 2>/dev/null; then
        echo "meta-test: git clone failed — git available and HEAD committable?" >&2
        rm -rf "$clone"
        return 1
    fi
    printf '%s' "$clone"
}

_assert_red() {
    local rc="$1"
    local message="$2"
    if [[ "$rc" -ne 0 ]]; then
        assert_equals "red" "red" "$message"
    else
        assert_equals "red" "green" "$message (gate did NOT fail — false-green vector)"
    fi
}

# ── 1. A1: non-final failing test file turns the routed test gate red ───────
test_meta_routing_red() {
    local f=0
    local clone rc
    clone="$(_new_clone)" || { assert_equals "clone" "ok" "meta: clone for routing case (git source unavailable)"; return 1; }
    rm -f "$clone"/tests/unit/test_*.sh
    printf '#!/usr/bin/env bash\nexit 3\n' > "$clone/tests/unit/test_aa_meta_fail.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$clone/tests/unit/test_zz_meta_pass.sh"

    ( cd "$clone" && bash tests/emit-manifest.sh unit ) >/dev/null 2>&1
    rc=$?
    _assert_red "$rc" "A1: make-routed test gate red on non-final failing file" || f=$((f + 1))

    python3 - "$clone/test-results/manifest.json" <<'PY'
import json
import sys
manifest = json.load(open(sys.argv[1]))
records = {t["test_id"]: (t["status"], t["exit_code"]) for t in manifest["tests"]}
ok = (
    records.get("test_aa_meta_fail") == ("fail", 3)
    and records.get("test_zz_meta_pass") == ("pass", 0)
)
sys.exit(0 if ok else 1)
PY
    assert_exit_code 0 "$?" "A1: manifest records seeded file as fail with its own exit code (3), canary as pass" || f=$((f + 1))

    # Positive control: with only the passing file, the gate is green.
    rm -f "$clone"/tests/unit/test_aa_meta_fail.sh
    ( cd "$clone" && bash tests/emit-manifest.sh unit ) >/dev/null 2>&1
    assert_exit_code 0 "$?" "A1: positive control — gate green when all files pass" || f=$((f + 1))
    rm -rf "$clone"
    return "$f"
}

# ── 2. B1.4: invalid Bash file turns the syntax gate red ────────────────────
test_meta_syntax_bash_red() {
    local f=0
    local clone rc
    clone="$(_new_clone)" || { assert_equals "clone" "ok" "meta: clone for bash-syntax case (git source unavailable)"; return 1; }
    printf 'if then fi\n' > "$clone/scripts/__meta_invalid_bash__.sh"
    ( cd "$clone" && make syntax-check ) >/dev/null 2>&1
    rc=$?
    _assert_red "$rc" "B1.4: syntax gate red on invalid Bash file" || f=$((f + 1))
    rm -rf "$clone"
    return "$f"
}

# ── 3. B1.4: invalid Zsh file turns the syntax gate red ─────────────────────
test_meta_syntax_zsh_red() {
    local f=0
    local clone rc
    clone="$(_new_clone)" || { assert_equals "clone" "ok" "meta: clone for zsh-syntax case (git source unavailable)"; return 1; }
    printf '}\n}\n' > "$clone/config/__meta_invalid_zsh__.zsh"
    ( cd "$clone" && make syntax-check ) >/dev/null 2>&1
    rc=$?
    # Holds in BOTH worlds: with zsh present the file fails zsh -n; without
    # zsh the gate itself fails closed. Either way the gate is red.
    _assert_red "$rc" "B1.4: syntax gate red on invalid Zsh file (or fail-closed without zsh)" || f=$((f + 1))
    rm -rf "$clone"
    return "$f"
}

# ── 4. B1.7: a ShellCheck finding turns the quality gate red ────────────────
test_meta_quality_red() {
    local f=0
    local clone rc
    clone="$(_new_clone)" || { assert_equals "clone" "ok" "meta: clone for quality case (git source unavailable)"; return 1; }
    # SC2086 (unquoted variable) — not in .shellcheckrc's disable list.
    printf '#!/usr/bin/env bash\nrm $UNQUOTED_META_VAR\n' > "$clone/scripts/__meta_lint__.sh"
    meta_out="$( cd "$clone" && make validate 2>&1 )"
    rc=$?
    _assert_red "$rc" "B1.7: zero-tolerance quality gate red on a ShellCheck finding" || f=$((f + 1))
    # Red is not enough: the gate must fail BECAUSE OF the seeded finding.
    # A fail-closed "shellcheck missing" would also be red — that is not a
    # pass for this case (needed on hosted CI agents: builds #4–#5).
    # CI diagnosability: show what the gate actually did (builds #4-#6).
    printf '%s\n' "---- B1.7 gate output (tail) ----" >&2
    printf '%s\n' "$meta_out" | tail -12 >&2
    printf '%s\n' "shellcheck-in-clone: $( cd "$clone" && command -v shellcheck || echo MISSING )" >&2
    if printf '%s' "$meta_out" | grep -q "SC2086"; then
        assert_equals "seeded" "found" "B1.7: gate output cites the seeded SC2086 finding (red for the right reason)" || f=$((f + 1))
    else
        assert_equals "seeded" "missing" "B1.7: gate output must cite the seeded SC2086 finding — fail-closed masking is not a pass" || f=$((f + 1))
    fi
    rm -rf "$clone"
    return "$f"
}

# ── 5. Comparator: identical manifests pass, mismatched/malformed fail ──────
test_meta_comparator() {
    local f=0
    local fixtures rc
    fixtures="$(mktemp -d "${TMPDIR:-/tmp}/vms-meta-fixtures.XXXXXX")"

    python3 - "$fixtures" <<'PY'
import json
import sys
import pathlib

fixtures = pathlib.Path(sys.argv[1])


def manifest(records_status="pass"):
    return {
        "platform": "Darwin-arm64",
        "suite": "unit",
        "tests": [
            {"test_id": "test_a", "platform": "Darwin-arm64", "status": records_status, "exit_code": 0 if records_status == "pass" else 9, "duration_s": 1},
            {"test_id": "test_b", "platform": "Darwin-arm64", "status": "pass", "exit_code": 0, "duration_s": 2},
        ],
        "summary": {"total": 2, "passed": 2 if records_status == "pass" else 1, "failed": 0 if records_status == "pass" else 1, "skipped": 0, "error": 0},
    }


(fixtures / "a.json").write_text(json.dumps(manifest(), indent=2))
(fixtures / "b.json").write_text(json.dumps(manifest(), indent=2))
mismatched = manifest()
mismatched["tests"][0]["status"] = "fail"
mismatched["summary"]["passed"] = 1
mismatched["summary"]["failed"] = 1
(fixtures / "c.json").write_text(json.dumps(mismatched, indent=2))
malformed = manifest()
del malformed["tests"][0]["exit_code"]
(fixtures / "d.json").write_text(json.dumps(malformed, indent=2))
PY

    bash "$ROOT_DIR/tests/compare-manifests.sh" "$fixtures/a.json" "$fixtures/b.json" >/dev/null 2>&1
    rc=$?
    assert_exit_code 0 "$rc" "comparator: identical manifests pass" || f=$((f + 1))

    bash "$ROOT_DIR/tests/compare-manifests.sh" "$fixtures/a.json" "$fixtures/c.json" >/dev/null 2>&1
    _assert_red "$?" "comparator: mismatched manifest FAILS the parity check" || f=$((f + 1))

    bash "$ROOT_DIR/tests/compare-manifests.sh" "$fixtures/a.json" "$fixtures/d.json" >/dev/null 2>&1
    _assert_red "$?" "comparator: schema-gap manifest FAILS (fail-closed)" || f=$((f + 1))
    rm -rf "$fixtures"
    return "$f"
}

# ── Run — explicit failure accumulation (A5) ─────────────────────────────────
failures=0
test_meta_routing_red || failures=$((failures + 1))
test_meta_syntax_bash_red || failures=$((failures + 1))
test_meta_syntax_zsh_red || failures=$((failures + 1))
test_meta_quality_red || failures=$((failures + 1))
test_meta_comparator || failures=$((failures + 1))

if [[ "$failures" -gt 0 ]]; then
    echo "test_gate_meta.sh: $failures meta-test(s) failed"
    exit 1
fi
