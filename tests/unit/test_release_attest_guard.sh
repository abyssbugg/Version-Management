#!/usr/bin/env bash
# =============================================================================
# F4 (re-audit 2026-10-10): the release attestation guard (B2.3, REL-PROV)
# =============================================================================
# scripts/release-attest-guard.sh is the first job of release.yml. The tag
# push path accepted ANY `.release-attested-<sha>` marker whose sha was an
# ancestor of the tag — so once one marker existed, every later commit was
# "attested", including code that never ran through the gate set. A marker is
# now accepted only when the commits since the attested sha change nothing
# but marker files.
#
# Every case builds a throwaway git repository under ${TMPDIR} with an
# isolated git configuration (no global/system config, no signing).
# ATTEST_GUARD_UNDER_TEST may point at another guard implementation (used to
# reproduce the RED state against the old inline logic).
# =============================================================================
set -uo pipefail
source "${BASH_SOURCE[0]%/*}/../helpers.sh" || { echo "FATAL: cannot source helpers.sh — run via tests/test_runner.sh (P0-3: unsandboxed HOME writes forbidden)" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="${ATTEST_GUARD_UNDER_TEST:-$ROOT/scripts/release-attest-guard.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vms-attest.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=vms GIT_AUTHOR_EMAIL=vms@test GIT_COMMITTER_NAME=vms GIT_COMMITTER_EMAIL=vms@test
failures=0

pass() { printf 'PASS: %s\n' "$1"; }
fail_case() {
    printf 'FAIL: %s\n' "$1"
    [[ -f "$REPO/guard.log" ]] && sed 's/^/    /' "$REPO/guard.log"
    failures=$((failures + 1))
}

REPO=""
new_repo() {  # fresh repo with one code commit; sets REPO and BASE
    REPO="$WORK/$1"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    printf 'echo v1\n' >"$REPO/code.sh"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm base
    BASE=$(git -C "$REPO" rev-parse HEAD)
}
commit_code() {  # <content> — a non-marker change
    printf '%s\n' "$1" >"$REPO/code.sh"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm "code: $1"
}
commit_marker() {  # <sha> [content] — records .release-attested-<sha>
    printf '%s\n' "${2:-$1}" >"$REPO/.release-attested-$1"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm "attest: $1"
}
tag_head() { git -C "$REPO" tag "$1"; }

# Run the guard like release.yml: cwd = checkout root, env as passed by the
# workflow. Sets RC and OUT (the GITHUB_OUTPUT file content).
run_guard() {  # <event> <ref> [input_version] [input_sha]
    : >"$REPO/gh_output"
    (cd "$REPO" && GH_EVENT_NAME="$1" GH_REF="$2" GH_INPUT_VERSION="${3:-}" \
        GH_INPUT_ATTESTED_SHA="${4:-}" GITHUB_OUTPUT="$REPO/gh_output" \
        bash "$GUARD" </dev/null >"$REPO/guard.log" 2>&1)
    RC=$?
    OUT=$(cat "$REPO/gh_output")
}
expect_accept() {  # <label> <attested> <release>
    local want
    want=$(printf 'attested_sha=%s\nrelease_sha=%s' "$2" "$3")
    if [[ "$RC" == 0 && "$OUT" == "$want" ]]; then pass "$1"; else fail_case "$1 (rc=$RC out=[$OUT])"; fi
}
expect_refuse() {  # <label>
    if [[ "$RC" != 0 ]] && ! grep -q '^release_sha=' <<<"$OUT"; then pass "$1"; else fail_case "$1 (rc=$RC out=[$OUT])"; fi
}

# 1. Marker-only commit on top of the attested commit: accepted.
new_repo accept
commit_marker "$BASE"
tag_head v1.0.0
MARK=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q v1.0.0
run_guard push refs/tags/v1.0.0
expect_accept "marker-only delta since the attested commit is accepted" "$BASE" "$MARK"

# 2. F4: a later code change under an old marker is refused.
new_repo stale
commit_marker "$BASE"
commit_code "echo v2-unattested"
tag_head v1.0.1
git -C "$REPO" checkout -q v1.0.1
run_guard push refs/tags/v1.0.1
expect_refuse "old marker cannot attest a later code change (F4)"
if grep -q 'change more than marker files' "$REPO/guard.log"; then
    pass "refusal names the stale-marker reason"
else
    fail_case "refusal names the stale-marker reason"
fi

# 3. Ledger: a stale marker plus the current one — the current one is used.
new_repo ledger
commit_marker "$BASE"
commit_code "echo v2"
SECOND=$(git -C "$REPO" rev-parse HEAD)
commit_marker "$SECOND"
tag_head v2.0.0
MARK=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q v2.0.0
run_guard push refs/tags/v2.0.0
expect_accept "current marker accepted alongside a stale ledger entry" "$SECOND" "$MARK"

# 4. A marker commit that also changes code is refused.
new_repo mixed
printf '%s\n' "$BASE" >"$REPO/.release-attested-$BASE"
printf 'echo smuggled\n' >"$REPO/code.sh"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "attest + smuggled code"
tag_head v1.0.0
git -C "$REPO" checkout -q v1.0.0
run_guard push refs/tags/v1.0.0
expect_refuse "marker commit carrying a code change is refused"

# 5. Deleting a file or renaming it into a marker-looking name is refused.
new_repo rename
git -C "$REPO" mv code.sh ".release-attested-$BASE"
git -C "$REPO" commit -qm "rename code into marker name"
printf '%s\n' "$BASE" >"$REPO/.release-attested-$BASE"
git -C "$REPO" commit -qam "fill marker"
tag_head v1.0.0
git -C "$REPO" checkout -q v1.0.0
run_guard push refs/tags/v1.0.0
expect_refuse "a code file removed/renamed since the attested commit is refused"

# 6. Retiring an old marker in the new marker commit is still marker-only.
new_repo retire
commit_marker "$BASE"
commit_code "echo v2"
SECOND=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" rm -q ".release-attested-$BASE"
printf '%s\n' "$SECOND" >"$REPO/.release-attested-$SECOND"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "attest second, retire first"
tag_head v2.0.0
MARK=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q v2.0.0
run_guard push refs/tags/v2.0.0
expect_accept "retiring an old marker keeps the delta marker-only" "$SECOND" "$MARK"

# 7. Content mismatch and non-ancestor markers are refused.
new_repo content
commit_marker "$BASE" "0000000000000000000000000000000000000000"
tag_head v1.0.0
git -C "$REPO" checkout -q v1.0.0
run_guard push refs/tags/v1.0.0
expect_refuse "marker whose content differs from its name is refused"

new_repo foreign
git -C "$REPO" checkout -q -b side
commit_code "echo side"
SIDE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q -
commit_marker "$SIDE"
tag_head v1.0.0
git -C "$REPO" checkout -q v1.0.0
run_guard push refs/tags/v1.0.0
expect_refuse "marker naming a non-ancestor commit is refused"

# 8. The checkout must be the tag's commit.
new_repo moved
commit_marker "$BASE"
tag_head v1.0.0
git -C "$REPO" checkout -q "$BASE"
run_guard push refs/tags/v1.0.0
expect_refuse "checkout HEAD different from the tag commit is refused"

# 9. workflow_dispatch: required input, strict equality.
new_repo dispatch
tag_head v3.0.0
run_guard workflow_dispatch refs/heads/main 3.0.0 ""
expect_refuse "dispatch without attested_sha is refused"
run_guard workflow_dispatch refs/heads/main 3.0.0 "abc123"
expect_refuse "dispatch with a non-40-hex attested_sha is refused"
run_guard workflow_dispatch refs/heads/main 3.0.0 "0000000000000000000000000000000000000000"
expect_refuse "dispatch with a mismatching attested_sha is refused"
run_guard workflow_dispatch refs/heads/main 9.9.9 "$BASE"
expect_refuse "dispatch for a missing tag is refused"
run_guard workflow_dispatch refs/heads/main 3.0.0 "$BASE"
expect_accept "dispatch with attested_sha == tag commit is accepted" "$BASE" "$BASE"

# 10. Missing GITHUB_OUTPUT fails closed.
(cd "$REPO" && GH_EVENT_NAME=workflow_dispatch GH_INPUT_VERSION=3.0.0 GH_INPUT_ATTESTED_SHA="$BASE" \
    GH_REF=refs/heads/main GITHUB_OUTPUT='' bash "$GUARD" </dev/null >/dev/null 2>&1) && RC=0 || RC=$?
if [[ "$RC" != 0 ]]; then pass "missing GITHUB_OUTPUT fails closed"; else fail_case "missing GITHUB_OUTPUT fails closed"; fi

# 11. The workflow runs this script, not an inline copy.
if grep -q 'run: \./scripts/release-attest-guard\.sh' "$ROOT/.github/workflows/release.yml"; then
    pass "release.yml attest-guard runs scripts/release-attest-guard.sh"
else
    fail_case "release.yml attest-guard runs scripts/release-attest-guard.sh"
fi

printf 'release-attest-guard (F4): %s failure(s)\n' "$failures"
[[ "$failures" -eq 0 ]]
