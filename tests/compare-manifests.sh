#!/usr/bin/env bash
# =============================================================================
# Canonical Test Manifest Comparator (remediation directive M0, finding A1)
# =============================================================================
# Gate-parity check: Make, CI, and the direct runner must agree on the
# canonical test manifest. Comparison is over NORMALIZED records —
# `test_id|status|exit_code`, sorted by test_id — never console output.
#
#   duration_s  excluded: nondeterministic across runs by nature
#   platform    excluded: cross-OS comparisons (M0.5 Linux+macOS) differ by
#               design; the field's PRESENCE is still enforced (schema check)
#
# Fail-closed: malformed JSON, schema gaps, suite mismatches, or any record/
# summary difference exit nonzero. A comparator that cannot fail is itself a
# false-green vector (directive: "a seeded manifest mismatch must fail the
# parity check").
#
# Usage: ./tests/compare-manifests.sh manifest1.json manifest2.json [...]
# =============================================================================

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <manifest.json> <manifest.json> [...]" >&2
    exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "compare-manifests: python3 not found — cannot compare manifests (fail-closed)" >&2
    exit 1
fi

for f in "$@"; do
    if [[ ! -f "$f" ]]; then
        echo "compare-manifests: manifest not found: $f" >&2
        exit 1
    fi
done

python3 - "$@" <<'PY'
import json
import sys

paths = sys.argv[1:]
REQUIRED = ("test_id", "platform", "status", "exit_code", "duration_s")


def normalize(path):
    try:
        with open(path) as fh:
            manifest = json.load(fh)
    except (OSError, ValueError) as exc:
        sys.exit(f"compare-manifests: FAIL {path}: unreadable/invalid JSON: {exc}")

    tests = manifest.get("tests")
    if not isinstance(tests, list) or not tests:
        sys.exit(f"compare-manifests: FAIL {path}: no test records")

    records = []
    for entry in tests:
        missing = [k for k in REQUIRED if k not in entry]
        if missing:
            sys.exit(
                f"compare-manifests: FAIL {path}: record missing fields {missing}"
            )
        records.append(
            f"{entry['test_id']}|{entry['status']}|{entry['exit_code']}"
        )
    records.sort()

    summary = manifest.get("summary")
    if not isinstance(summary, dict) or "total" not in summary:
        sys.exit(f"compare-manifests: FAIL {path}: missing/invalid summary")
    suite = manifest.get("suite")
    if not isinstance(suite, str) or not suite:
        sys.exit(f"compare-manifests: FAIL {path}: missing/invalid suite")

    return suite, records, summary


base_path = paths[0]
base_suite, base_records, base_summary = normalize(base_path)

for path in paths[1:]:
    suite, records, summary = normalize(path)
    if suite != base_suite:
        sys.exit(
            f"compare-manifests: FAIL {path}: suite '{suite}' != '{base_suite}'"
        )
    if records != base_records:
        base_set, this_set = set(base_records), set(records)
        only_base = sorted(base_set - this_set)
        only_this = sorted(this_set - base_set)
        sys.exit(
            f"compare-manifests: FAIL {path}: record mismatch\n"
            f"  only in {base_path}: {only_base}\n"
            f"  only in {path}: {only_this}"
        )
    if summary != base_summary:
        sys.exit(
            f"compare-manifests: FAIL {path}: summary mismatch "
            f"{summary} != {base_summary}"
        )

print(
    f"compare-manifests: PARITY OK across {len(paths)} manifests "
    f"({len(base_records)} records, suite='{base_suite}', summary={base_summary})"
)
PY
