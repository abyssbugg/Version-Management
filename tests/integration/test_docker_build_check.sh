#!/usr/bin/env bash
# Exercise build/run failure propagation and exact-owner cleanup without Docker.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/tests/helpers.sh"
S=$(mktemp -d "${TMPDIR:-/tmp}/vms-docker-contract.XXXXXX")
trap 'rm -rf -- "$S"' EXIT
mkdir -p "$S/bin" "$S/state"
export DOCKER_FAKE_STATE="$S/state" DOCKER_CONTEXT=fixture-only PATH="$S/bin:$PATH"
cat > "$S/bin/docker" <<'FAKE'
#!/usr/bin/env python3
import json, os, pathlib, sys
root=pathlib.Path(os.environ['DOCKER_FAKE_STATE'])
a=sys.argv[1:]
with (root/'calls').open('a') as f: f.write(json.dumps(a)+'\n')
assert a[:2]==['--context','fixture-only'], a
a=a[2:]; case=os.environ.get('DOCKER_CASE','pass')
def value(flag): return a[a.index(flag)+1]
def save(name):
    (root/name.replace(':','_')).write_text(value('--label').split('=',1)[1])
def owner(name):
    p=root/name.replace(':','_')
    if not p.exists(): sys.exit(1)
    return p.read_text()
if a==['info']: sys.exit(3 if case=='unavailable' else 0)
if a[0]=='build':
    assert pathlib.Path(a[-1]).name in ('node','python','go','rust','java')
    assert pathlib.Path(value('--file')).is_file()
    if case=='build': sys.exit(7)
    save(value('--tag')); sys.exit(0)
if a[:2]==['image','inspect']:
    fmt=value('--format')
    if 'Labels' in fmt: print('another-run' if case=='foreign' else owner(a[-1]))
    elif 'User' in fmt: print('0' if case=='root' else 'appuser')
    else: print('null' if case=='healthcheck' else '["CMD-SHELL","fixture"]')
    sys.exit(0)
if a[0]=='run':
    assert value('--network')=='none' and value('--cap-drop')=='ALL'
    assert value('--security-opt')=='no-new-privileges'
    assert not any(x in a for x in ('--privileged','-v','--volume','--publish','-p'))
    if case=='run': sys.exit(8)
    save(value('--name')); print('fixture-container-id'); sys.exit(0)
if a[0]=='inspect':
    if 'Labels' in value('--format'): print('another-run' if case=='foreign' else owner(a[-1]))
    else: print('running unhealthy' if case=='unhealthy' else 'running healthy')
    sys.exit(0)
if a[0]=='exec': print('0' if case=='uid' else '10001'); sys.exit(0)
if a[0]=='logs': print('synthetic application logs'); sys.exit(0)
if a[0]=='rm' or a[:2]==['image','rm']:
    assert a[-1].startswith('vms-check-'), a
    owner(a[-1]); sys.exit(0)
raise AssertionError(a)
FAKE
chmod +x "$S/bin/docker"
failures=0
if env -u DOCKER_CONTEXT bash "$ROOT/scripts/check-docker-builds.sh" >"$S/missing.log" 2>&1; then failures=$((failures+1)); fi
for case in unavailable build root healthcheck run unhealthy uid; do
    if DOCKER_CASE="$case" bash "$ROOT/scripts/check-docker-builds.sh" >"$S/$case.log" 2>&1; then
        printf 'FAIL: accepted %s failure\n' "$case"; failures=$((failures+1))
    fi
done
: > "$S/state/calls"
DOCKER_CASE=pass bash "$ROOT/scripts/check-docker-builds.sh" >"$S/pass.log" 2>&1 || { cat "$S/pass.log"; exit 1; }
python3 - "$S/state/calls" <<'CHECK'
import json,sys
calls=[json.loads(x)[2:] for x in open(sys.argv[1])]
assert len([a for a in calls if a[0]=='build'])==5
assert len([a for a in calls if a[0]=='run'])==5
assert len([a for a in calls if a[0]=='rm'])==5
assert len([a for a in calls if a[:2]==['image','rm']])==5
assert not any('prune' in a or '--filter' in a for a in calls)
CHECK
: > "$S/state/calls"
if DOCKER_CASE=foreign bash "$ROOT/scripts/check-docker-builds.sh" >"$S/foreign.log" 2>&1; then
    echo 'FAIL: reported success after refusing foreign cleanup'; exit 1
fi
python3 - "$S/state/calls" <<'CHECK'
import json,sys
calls=[json.loads(x)[2:] for x in open(sys.argv[1])]
assert not any(a[0]=='rm' or a[:2]==['image','rm'] for a in calls)
CHECK
assert_equals 0 "$failures" 'build/runtime failures are propagated'
exit "$failures"
