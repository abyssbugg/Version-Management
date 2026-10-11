#!/usr/bin/env bash
# Build and run synthetic apps against all generated Dockerfiles. Never sends
# the caller's project or HOME as build context; never mounts host directories.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
: "${DOCKER_CONTEXT:?Set an explicit Docker context for this opt-in check}"
command -v docker >/dev/null
command -v python3 >/dev/null

# Bound every Docker client operation, including cleanup and daemon probes.
docker_call() {
    local seconds=$1
    shift
    python3 - "$seconds" "$DOCKER_CONTEXT" "$@" <<'PY'
import os, signal, subprocess, sys
p = subprocess.Popen(['docker', '--context', sys.argv[2], *sys.argv[3:]], start_new_session=True)
def interrupted(signum, frame):
    try:
        os.killpg(p.pid, signal.SIGTERM)
        p.wait(timeout=2)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
    except ProcessLookupError:
        pass
    raise SystemExit(128 + signum)
for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, interrupted)
try:
    raise SystemExit(p.wait(timeout=int(sys.argv[1])))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
    print('Docker operation timed out', file=sys.stderr)
    raise SystemExit(124)
PY
}
docker_call 15 info >/dev/null
scratch=$(mktemp -d "${TMPDIR:-/tmp}/vms-docker-check.XXXXXX")
token="vms-check-$(basename "$scratch" | tr '[:upper:]' '[:lower:]')-$$"
label="org.version-management.check=$token"
images=()
containers=()
cleanup() {
    local rc=$? item owner
    trap - EXIT INT TERM HUP
    for item in "${containers[@]-}"; do
        [[ -n "$item" ]] || continue
        owner=$(docker_call 10 inspect --format '{{index .Config.Labels "org.version-management.check"}}' "$item" 2>/dev/null) || { rc=1; continue; }
        if [[ "$owner" == "$token" ]]; then
            docker_call 15 rm -f "$item" >/dev/null || rc=1
        else
            echo "Refusing cleanup of foreign container: $item" >&2
            rc=1
        fi
    done
    for item in "${images[@]-}"; do
        [[ -n "$item" ]] || continue
        owner=$(docker_call 10 image inspect --format '{{index .Config.Labels "org.version-management.check"}}' "$item" 2>/dev/null) || { rc=1; continue; }
        if [[ "$owner" == "$token" ]]; then
            docker_call 15 image rm "$item" >/dev/null || rc=1
        else
            echo "Refusing cleanup of foreign image: $item" >&2
            rc=1
        fi
    done
    [[ "$scratch" == */vms-docker-check.* ]] && rm -rf -- "$scratch"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
mkdir -p "$scratch/home" "$scratch/tmp"
for lang in node python go rust java; do
    app="$scratch/$lang"
    mkdir "$app"
    cp -R "$ROOT/tests/fixtures/docker/$lang/." "$app/"
    # Generation is sandboxed independently from Docker client credentials.
    (
        export HOME="$scratch/home" TMPDIR="$scratch/tmp"
        export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
        cd "$app"
        # shellcheck source=../version-advanced.sh
        source "$ROOT/version-advanced.sh"
        "generate_dockerfile_$lang"
    )
    image="$token:$lang"
    container="$token-$lang"
    images+=("$image")
    docker_call 900 build --label "$label" --tag "$image" --file "$app/Dockerfile.$lang" "$app"
    user=$(docker_call 15 image inspect --format '{{.Config.User}}' "$image")
    case "$user" in ''|0|root|0:*|root:*) echo "FAIL $lang: image runs as root" >&2; exit 1;; esac
    health=$(docker_call 15 image inspect --format '{{json .Config.Healthcheck.Test}}' "$image")
    [[ "$health" != null && "$health" != '[]' && "$health" != '["NONE"]' ]] || { echo "FAIL $lang: no healthcheck" >&2; exit 1; }
    containers+=("$container")
    docker_call 30 run --detach --name "$container" --label "$label" \
        --network none --cap-drop ALL --security-opt no-new-privileges \
        --pids-limit 128 --memory 512m --cpus 1 \
        --health-interval 1s --health-start-period 2s --health-retries 5 "$image" >/dev/null
    healthy=false
    for ((attempt=0; attempt<45; attempt++)); do
        state=$(docker_call 10 inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container")
        case "$state" in
            'running healthy') healthy=true; break;;
            *unhealthy*|exited*|dead*) break;;
        esac
        sleep 1
    done
    if [[ "$healthy" != true ]]; then
        docker_call 10 logs "$container" >&2 || true
        echo "FAIL $lang: runtime not healthy ($state)" >&2
        exit 1
    fi
    uid=$(docker_call 10 exec "$container" id -u)
    [[ "$uid" =~ ^[0-9]+$ && "$uid" != 0 ]] || { echo "FAIL $lang: invalid runtime uid $uid" >&2; exit 1; }
    echo "PASS $lang: built, healthy, non-root uid=$uid"
done
