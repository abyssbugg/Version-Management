#!/usr/bin/env bash
# =============================================================================
# release-attest-guard.sh — release attestation guard (B2.3, REL-PROV, F4)
# =============================================================================
# Run by the first job of .github/workflows/release.yml from the root of a
# full-history checkout of the release commit. Nothing in the workflow may
# build or publish until this script exits 0. Fail-closed throughout.
#
# Admission paths:
#   1. workflow_dispatch: the attested_sha input is REQUIRED and must equal
#      the commit of tag v<version> (strict equality).
#   2. tag push: the tag's tree must contain a marker `.release-attested-<sha>`
#      whose content equals <sha>, whose <sha> is an ancestor of the tag
#      commit, AND (F4, re-audit 2026-10-10) whose commit differs from the
#      tag commit ONLY in `.release-attested-*` marker files. Without that
#      last rule any old marker in the tree attested every later commit,
#      including code changes that never ran through the gate set.
#
# Inputs (environment, as passed by release.yml):
#   GH_EVENT_NAME          github.event_name
#   GH_INPUT_VERSION       workflow_dispatch input `version`
#   GH_INPUT_ATTESTED_SHA  workflow_dispatch input `attested_sha`
#   GH_REF                 github.ref (tag push: refs/tags/vX.Y.Z)
#   GITHUB_OUTPUT          step-output file (attested_sha=, release_sha=)
#
# Exit codes: 0 = attested (outputs written); 1 = refused.
# =============================================================================
set -euo pipefail

fail() {
    printf '::error::%s\n' "$1"
    exit 1
}

is_sha() {
    [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

# The commit range <attested>..<release> may change nothing but marker files.
# Rename detection is off so a renamed code file shows both of its paths, and
# quotePath is on so an unusual path is quoted and can never match.
marker_only_delta() {
    local base="$1" head="$2" paths path
    paths=$(git -c core.quotePath=true diff --no-renames --name-only "$base" "$head") || return 1
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        [[ "$path" =~ ^\.release-attested-[0-9a-f]{40}$ ]] || return 1
    done <<<"$paths"
    return 0
}

main() {
    local event="${GH_EVENT_NAME:-}"
    local input_version="${GH_INPUT_VERSION:-}"
    local input_sha="${GH_INPUT_ATTESTED_SHA:-}"
    local ref="${GH_REF:-}"
    local output="${GITHUB_OUTPUT:-}"
    local attested="" release_sha=""

    [[ -n "$output" ]] || fail "GITHUB_OUTPUT is not set; cannot publish the guard's outputs. Release refused."

    local top
    top=$(git rev-parse --show-toplevel 2>/dev/null) || fail "Not inside a git checkout. Release refused."
    cd "$top"

    if [[ "$event" == "workflow_dispatch" ]]; then
        # Path 1: explicit attestation input, strict equality with the release
        # tag's commit. Absent input fails closed.
        if [[ -z "$input_sha" ]]; then
            fail "attested_sha input is required for a manual release dispatch (docs/RELEASE_CHECKLIST.md: record the Buildkite-green SHA and pass it here)."
        fi
        is_sha "$input_sha" \
            || fail "attested_sha must be a full 40-hex commit SHA (got: '$input_sha')."
        git rev-parse --verify --quiet "v${input_version}^{commit}" >/dev/null \
            || fail "Tag v${input_version} does not exist; tag the attested commit first (docs/RELEASE_CHECKLIST.md)."
        local tag_sha
        tag_sha=$(git rev-parse "v${input_version}^{commit}")
        if [[ "$tag_sha" != "$input_sha" ]]; then
            fail "Attestation mismatch: tag v${input_version} points at ${tag_sha} but attested_sha is ${input_sha}. Release refused."
        fi
        attested="$input_sha"
        # REL-PROV: the release commit is the tag commit (== attested). On a
        # dispatch github.ref is the dispatching BRANCH and must not be built.
        release_sha="$tag_sha"
    else
        # Path 2: tag push.
        [[ -n "$ref" ]] || fail "GH_REF is empty on a tag push. Release refused."
        release_sha=$(git rev-parse --verify --quiet "${ref}^{commit}") \
            || fail "Cannot resolve ${ref} to a commit. Release refused."
        # The marker scan reads the working tree, so it must be the tag's tree
        # (fails closed if the tag moved after the push).
        local head
        head=$(git rev-parse HEAD)
        [[ "$head" == "$release_sha" ]] \
            || fail "Checkout HEAD ${head} is not the commit of ${ref} (${release_sha}). Release refused."

        local f name content stale=()
        for f in .release-attested-*; do
            [[ -f "$f" ]] || continue
            name="${f#.release-attested-}"
            is_sha "$name" || continue
            content=$(tr -d '[:space:]' <"$f")
            [[ "$name" == "$content" ]] || continue
            git merge-base --is-ancestor "$name" HEAD 2>/dev/null || continue
            if marker_only_delta "$name" HEAD; then
                attested="$name"
                break
            fi
            stale+=("$name")
        done
        if [[ -z "$attested" ]]; then
            if ((${#stale[@]} > 0)); then
                fail "No current attestation: the marker(s) in tag ${ref} (commit ${release_sha}) name ancestor(s) ${stale[*]}, but commits since then change more than marker files — that code never ran through the gate set. Attest the release-prep commit and tag its marker commit (docs/RELEASE_CHECKLIST.md). Release refused."
            fi
            fail "No attestation marker: tag ${ref} (commit ${release_sha}) contains no .release-attested-<sha> marker naming an ancestor commit. Release refused — follow docs/RELEASE_CHECKLIST.md."
        fi
    fi

    echo "attested_sha=$attested" >>"$output"
    echo "Release attested for SHA: $attested"

    # REL-PROV: emit the release commit for every downstream checkout.
    is_sha "$release_sha" \
        || fail "release_sha is empty or not a full 40-hex commit SHA (got: '$release_sha'). Release refused."
    echo "release_sha=$release_sha" >>"$output"
    echo "Release commit (built, tested, signed, published): $release_sha"
}

main "$@"
