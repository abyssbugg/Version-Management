#!/usr/bin/env bash
# Verify the actual Buildkite command without network or host writes.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/tests/helpers.sh"
S=$(mktemp -d "${TMPDIR:-/tmp}/vms-attest-dispatch.XXXXXX")
trap 'rm -rf -- "$S"' EXIT
python3 - "$ROOT/.buildkite/pipeline.yml" "$S/command.sh" <<'PY'
import pathlib, sys
lines=pathlib.Path(sys.argv[1]).read_text().splitlines()
key=next(i for i,s in enumerate(lines) if s.strip()=='key: "release-attest"')
start=next(i for i in range(key,len(lines)) if lines[i].strip()=='command: |')+1
out=[]
for s in lines[start:]:
    if s and not s.startswith('          '): break
    out.append(s[10:])
assert out and any('required = ' in x and 'docker-build-check' in x for x in out)
pathlib.Path(sys.argv[2]).write_text('\n'.join(out)+'\n')
PY
mkdir "$S/bin" "$S/work"
cat > "$S/bin/curl" <<'SH'
#!/usr/bin/env bash
echo 'FAIL: unexpected network request' >&2
exit 99
SH
chmod +x "$S/bin/curl"
export PATH="$S/bin:$PATH"
cd "$S/work"
env -u RELEASE_ATTEST_SHA -u BUILDKITE_ACCESS_TOKEN bash "$S/command.sh" > "$S/inactive.log"
grep -q '^status=not_requested$' release-attestation/report.txt
grep -q 'NOT release proof' "$S/inactive.log"
[[ ! -f release-attestation/attested-sha.txt ]]
if env -u RELEASE_ATTEST_SHA RELEASE_ATTEST_TAG=v3.0.0 bash "$S/command.sh" > "$S/tag-only.log" 2>&1; then
    echo 'FAIL: tag-only request treated as inactive'; exit 1
fi
grep -q 'requires RELEASE_ATTEST_SHA' "$S/tag-only.log"
for sha in '' invalid 1234567; do
    if RELEASE_ATTEST_SHA="$sha" bash "$S/command.sh" > "$S/invalid.log" 2>&1; then
        echo 'FAIL: invalid explicit attestation accepted'; exit 1
    fi
    grep -q 'must be a full 40-hex' "$S/invalid.log"
done
if env -u BUILDKITE_ACCESS_TOKEN RELEASE_ATTEST_SHA=1111111111111111111111111111111111111111 bash "$S/command.sh" > "$S/missing-token.log" 2>&1; then
    echo 'FAIL: requested attestation accepted without token'; exit 1
fi
grep -q 'BUILDKITE_ACCESS_TOKEN not available' "$S/missing-token.log"
assert_equals not_requested "$(sed -n 's/^status=//p' release-attestation/report.txt)" 'inactive status is not a release attestation'
