#!/usr/bin/env bash
# =============================================================================
# version-advanced.sh managed generation (AX-18, P3-1 / ROADMAP 3.4)
# =============================================================================
# Binding invariants for the Dockerfile / docker-compose / CI generators:
#   - --dry-run writes nothing: no project file, no directory, nothing under
#     HOME, no temp file left behind; the plan names every file.
#   - Apply publishes through a backup transaction: an existing (hand-edited)
#     file is backed up before it is replaced, its mode is kept, a symlinked
#     target stays a link, unchanged files are not rewritten (no mtime churn).
#   - A multi-file command is ONE rollback unit: a failure part-way restores
#     every file the run had already replaced, removes the files and the
#     directories it created, and exits non-zero.
#   - AX-1 parity: `register <path with spaces>` reaches the command intact.
#   - auto-switch/lazy-load delegate to THIS checkout's version-manager.sh,
#     never to a ./version-manager.sh in the caller's working directory.
#
# Safety: every case runs the real CLI under env -i with a mktemp -d HOME,
# TMPDIR and project directory created before anything runs.
# =============================================================================

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$ROOT/version-advanced.sh"
BASH_BIN="$(command -v bash)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/vms-va-managed.XXXXXX")"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
trap 'chmod -R u+w "$SANDBOX" 2>/dev/null; rm -rf -- "$SANDBOX"' EXIT

PASS=0
FAIL=0
check() {
    local label="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1))
        echo "  PASS: $label"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $label"
    fi
}
has() { [[ "$2" == *"$1"* ]]; }
lacks() { [[ "$2" != *"$1"* ]]; }
mtime_of() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1"; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

OUT="" RC=0
# new_case <name>: fresh HOME/TMPDIR/project (a git repository) — sets H T P
new_case() {
    echo "--- $1 ---"
    H="$SANDBOX/$1/home" T="$SANDBOX/$1/tmp" P="$SANDBOX/$1/proj"
    mkdir -p "$H" "$T" "$P"
    git -C "$P" init -q .
}
run_cli() {
    OUT=$(cd "$P" && /usr/bin/env -i HOME="$H" TMPDIR="$T" PATH=/usr/bin:/bin LC_ALL=C \
        "$BASH_BIN" "$CLI" "$@" </dev/null 2>&1)
    RC=$?
}
tree_of() { (cd "$1" && find . -path ./.git -prune -o -print | LC_ALL=C sort); }

DOCKER_FILES=(Dockerfile.node Dockerfile.python Dockerfile.go Dockerfile.rust Dockerfile.java docker-compose.yml)

# --- a) dry-run is zero-write ---------------------------------------------------
new_case dry_run
printf 'FROM scratch # mine\n' > "$P/Dockerfile.node"
before_proj=$(tree_of "$P")
before_node=$(cat "$P/Dockerfile.node")
run_cli docker --dry-run
check "dry-run docker exits 0" test "$RC" -eq 0
check "plan names a new file" has "[dry-run] would create: $P/Dockerfile.go" "$OUT"
check "plan names a replaced file" has "[dry-run] would replace: $P/Dockerfile.node" "$OUT"
check "project tree unchanged" test "$(tree_of "$P")" = "$before_proj"
check "existing file unchanged" test "$(cat "$P/Dockerfile.node")" = "$before_node"
check "nothing written under HOME" test -z "$(find "$H" -mindepth 1 -print -quit)"
check "no temp file left in TMPDIR" test -z "$(find "$T" -mindepth 1 -print -quit)"
run_cli ci-all --dry-run
check "dry-run ci-all exits 0" test "$RC" -eq 0
check "dry-run ci-all plans the workflow directory" has "[dry-run] would create directory: .github/workflows" "$OUT"
check "dry-run ci-all creates no directory" test ! -e "$P/.github"
check "dry-run ci-all writes nothing under HOME" test -z "$(find "$H" -mindepth 1 -print -quit)"

# --- b) apply, idempotent rerun -------------------------------------------------
new_case apply
run_cli docker
check "docker exits 0" test "$RC" -eq 0
for f in "${DOCKER_FILES[@]}"; do
    check "$f created" test -s "$P/$f"
done
check "new file mode is 644" test "$(mode_of "$P/Dockerfile.go")" = 644
touch -t 202001010000 "$P"/Dockerfile.* "$P/docker-compose.yml"
m_go=$(mtime_of "$P/Dockerfile.go")
run_cli docker
check "rerun exits 0" test "$RC" -eq 0
check "rerun reports unchanged files" has "Unchanged (already up to date): $P/Dockerfile.go" "$OUT"
check "rerun does not rewrite (mtime kept)" test "$(mtime_of "$P/Dockerfile.go")" = "$m_go"
check "no temp file left in TMPDIR" test -z "$(find "$T" -mindepth 1 -print -quit)"

# --- c) hand-edited file: backed up, replaced, mode kept; symlink kept ----------
new_case replace
printf 'FROM scratch\n# hand-edited, keep a copy\n' > "$P/Dockerfile.node"
chmod 600 "$P/Dockerfile.node"
mkdir -p "$SANDBOX/replace/shared"
printf 'FROM scratch # shared\n' > "$SANDBOX/replace/shared/Dockerfile.python"
ln -s "$SANDBOX/replace/shared/Dockerfile.python" "$P/Dockerfile.python"
run_cli docker
check "docker over existing files exits 0" test "$RC" -eq 0
check "hand-edited file replaced with the template" grep -q 'P2-7' "$P/Dockerfile.node"
check "replaced file keeps mode 600" test "$(mode_of "$P/Dockerfile.node")" = 600
backup_hits=$(grep -rl 'hand-edited, keep a copy' "$H" 2>/dev/null | wc -l | tr -d ' ')
check "original bytes kept in the transaction backup under HOME" test "$backup_hits" -ge 1
check "symlinked target is still a link" test -L "$P/Dockerfile.python"
check "link target string unchanged" test "$(readlink "$P/Dockerfile.python")" = "$SANDBOX/replace/shared/Dockerfile.python"
check "content updated through the link" grep -q 'P2-7' "$SANDBOX/replace/shared/Dockerfile.python"

# --- d) failure part-way rolls the whole command back ---------------------------
new_case rollback
printf 'FROM scratch # original node\n' > "$P/Dockerfile.node"
chmod 640 "$P/Dockerfile.node"
cp -p "$P/Dockerfile.node" "$SANDBOX/rollback/node.ref"
mkdir "$P/Dockerfile.rust"   # not a regular file: the 4th publish must fail
run_cli docker
check "failing docker run exits non-zero" test "$RC" -ne 0
check "failure is reported" has "Generation failed" "$OUT"
check "replaced file restored byte-identically" cmp -s "$P/Dockerfile.node" "$SANDBOX/rollback/node.ref"
check "restored file keeps mode 640" test "$(mode_of "$P/Dockerfile.node")" = 640
check "files created by the run are removed" test ! -e "$P/Dockerfile.python" -a ! -e "$P/Dockerfile.go"
check "later files never written" test ! -e "$P/Dockerfile.java" -a ! -e "$P/docker-compose.yml"
check "the blocking directory is untouched" test -d "$P/Dockerfile.rust"
check "no publish temp file left in the project" test -z "$(find "$P" -maxdepth 1 -name '.vms-mutation.*' -print -quit)"

new_case rollback_dirs
mkdir "$P/.gitlab-ci.yml"    # 2nd ci-all publish fails after the workflow dir was created
run_cli ci-all
check "failing ci-all exits non-zero" test "$RC" -ne 0
check "workflow written before the failure is removed" test ! -e "$P/.github/workflows/version-manager.yml"
check "directories created by the run are removed" test ! -e "$P/.github"
check "the blocking directory is untouched" test -d "$P/.gitlab-ci.yml"

# --- e) AX-1 parity + cwd-independent delegation --------------------------------
new_case cli
run_cli register "$SANDBOX/cli/my project"
check "register with a spaced path exits 0" test "$RC" -eq 0
check "spaced path registered intact" grep -qxF "$SANDBOX/cli/my project" "$H/.local/state/version-manager/projects.txt"
marker="$SANDBOX/cli/IMPOSTOR-RAN"
printf '#!/usr/bin/env bash\ntouch %q\n' "$marker" > "$P/version-manager.sh"
chmod +x "$P/version-manager.sh"
run_cli lazy-load --dry-run
check "lazy-load --dry-run exits 0" test "$RC" -eq 0
check "lazy-load delegates to this checkout's version-manager.sh" lacks "version-manager.sh not found" "$OUT"
run_cli lazy-load
check "lazy-load (apply, sandbox HOME) exits 0" test "$RC" -eq 0
check "a ./version-manager.sh in the project is never executed" test ! -e "$marker"
run_cli help
check "help documents --dry-run" has "--dry-run" "$OUT"

echo "version-advanced managed: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
