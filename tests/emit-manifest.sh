#!/usr/bin/env bash
# =============================================================================
# Canonical Test Manifest Emitter (remediation directive M0 step 1, finding A1)
# =============================================================================
# Wraps tests/test_runner.sh so that every runner entry point — make, CI, and
# direct invocation — emits one machine-readable record per test file to a
# well-known path. Record fields: test_id, platform, status, exit_code,
# duration_s.
#
# The manifest is deterministic (no timestamps) so that gate parity is a byte
# comparison of normalized manifests, never console output (directive M0 GO).
#
# Usage:
#   ./tests/emit-manifest.sh               # both suites
#   ./tests/emit-manifest.sh unit          # unit suite only
#   ./tests/emit-manifest.sh integration   # integration suite only
#
# Output: test-results/manifest.json and test-results/manifest.tsv
# Exit:   0 iff every record is pass/skip and none is error; else nonzero.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$SCRIPT_DIR/test_runner.sh"
OUT_DIR="$ROOT_DIR/test-results"
PLATFORM="$(uname -s)-$(uname -m)"

case "${1:-}" in
    unit)        suite="unit" ;;
    integration) suite="integration" ;;
    "")          suite="all" ;;
    *)
        echo "usage: $0 [unit|integration]" >&2
        exit 2
        ;;
esac

if [[ ! -f "$RUNNER" ]]; then
    echo "emit-manifest: test runner not found at $RUNNER" >&2
    exit 2
fi

# Enumerate the same test files the runner discovers (sorted, one suite or both).
files=()
if [[ "$suite" == "all" || "$suite" == "unit" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(
        find "$SCRIPT_DIR/unit" -name 'test_*.sh' -type f 2>/dev/null | sort
    )
fi
if [[ "$suite" == "all" || "$suite" == "integration" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(
        find "$SCRIPT_DIR/integration" -name 'test_*.sh' -type f 2>/dev/null | sort
    )
fi

if [[ ${#files[@]} -eq 0 ]]; then
    echo "emit-manifest: no test files found for suite '$suite' — failing closed" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
tsv_tmp="$OUT_DIR/manifest.tsv.tmp"
json_tmp="$OUT_DIR/manifest.json.tmp"
: > "$tsv_tmp"

passed=0
failed=0
skipped=0
errored=0
progress=0
json_records=()

for f in "${files[@]}"; do
    name="$(basename "$f" .sh)"
    if [[ "$f" == */unit/* ]]; then rsuite="unit"; else rsuite="integration"; fi

    # B1.8: per-file progress before each invocation — without this line a
    # hung file is invisible in CI logs (the runner buffers per-file output).
    progress=$((progress + 1))
    echo "emit-manifest: [${progress}/${#files[@]}] running ${name}"

    # Per-file execution + duration: the runner filters by substring, and the
    # file basenames are unique per suite, so one filtered invocation per file
    # routes through the runner exactly as make does.
    SECONDS=0
    rc=0
    out="$(TEST_FILTER="$name" bash "$RUNNER" "$rsuite" 2>&1)" || rc=$?
    dur=$SECONDS

    plain="$(printf '%s\n' "$out" | sed $'s/\x1b\\[[0-9;]*m//g')"
    file_rc="$rc"
    if printf '%s\n' "$plain" | grep -Eq "✓ ${name}( |$)"; then
        status="pass"
        file_rc=0
        passed=$((passed + 1))
    elif printf '%s\n' "$plain" | grep -qF "✗ ${name} (exit"; then
        status="fail"
        failed=$((failed + 1))
        # The runner records the file's own exit code on its result line;
        # the invocation rc is the suite aggregate, so extract the per-file code.
        parsed="$(printf '%s\n' "$plain" | grep -F "✗ ${name} (exit" | tail -1 | sed -E 's/.*\(exit ([0-9]+)\).*/\1/')"
        [[ -n "$parsed" ]] && file_rc="$parsed"
        # Surface the failing file's own output — without this, CI logs show
        # only the manifest summary and a failing test is undiagnosable.
        printf '%s\n' "---- failed: ${name} (output tail) ----" >&2
        # Failing assertions first (they can scroll past the tail window when a
        # file has many passing lines after the failure), then the tail for context.
        _fail_lines="$(printf '%s\n' "$plain" | grep -nE '✗|FAIL(:|ED)?|✘' | grep -vE "✗ ${name} \(exit" | head -40 || true)"
        if [[ -n "$_fail_lines" ]]; then
            printf '%s\n' "  failing lines:" >&2
            printf '%s\n' "$_fail_lines" | sed 's/^/    /' >&2
        fi
        printf '%s\n' "$plain" | tail -40 >&2
        printf '%s\n' "--------------------------------" >&2
    elif printf '%s\n' "$plain" | grep -Eq "⊘ ${name}( |$)"; then
        status="skip"
        skipped=$((skipped + 1))
    else
        # The runner neither reported the file nor matched it — fail closed.
        status="error"
        errored=$((errored + 1))
        printf '%s\n' "$plain" | tail -5 | sed 's/^/    /' >&2
    fi

    json_records+=("{\"test_id\": \"${name}\", \"platform\": \"${PLATFORM}\", \"status\": \"${status}\", \"exit_code\": ${file_rc}, \"duration_s\": ${dur}}")
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$PLATFORM" "$status" "$file_rc" "$dur" >> "$tsv_tmp"
done

mv "$tsv_tmp" "$OUT_DIR/manifest.tsv"

total=${#files[@]}
{
    echo '{'
    echo "  \"platform\": \"${PLATFORM}\","
    echo "  \"suite\": \"${suite}\","
    echo '  "tests": ['
    for ((i = 0; i < ${#json_records[@]}; i++)); do
        if ((i + 1 < total)); then
            echo "    ${json_records[$i]},"
        else
            echo "    ${json_records[$i]}"
        fi
    done
    echo '  ],'
    echo "  \"summary\": {\"total\": ${total}, \"passed\": ${passed}, \"failed\": ${failed}, \"skipped\": ${skipped}, \"error\": ${errored}}"
    echo '}'
} > "$json_tmp"
mv "$json_tmp" "$OUT_DIR/manifest.json"

echo "manifest: ${total} record(s) -> ${OUT_DIR}/manifest.json (passed=${passed} failed=${failed} skipped=${skipped} error=${errored})"
if [[ "$status" == "fail" || "$status" == "error" || $failed -gt 0 || $errored -gt 0 ]]; then
    exit 1
fi
exit 0
