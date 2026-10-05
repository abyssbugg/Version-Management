# Release Checklist

Operational contract for cutting a release of **version-management-setup**.
This is the release-path half of the attestation-continuity requirement
(B2.3) and the SBOM/signing remainder (P1-6); policy lives in
[ENGINEERING_RULES.md](governance/ENGINEERING_RULES.md) §6 and the runbook
section [OPERATIONS.md](OPERATIONS.md) "Release path".

## What enforces what

| Check | Enforcer | Automatic |
| ----- | -------- | --------- |
| ShellCheck lint, fail-closed syntax, pre-commit, gitleaks, tests (Linux + macOS) | Buildkite on every push (`.buildkite/pipeline.yml`) | Yes |
| Version consistency (`package.json` ↔ release tag) | `release.yml` `validate` job | Yes |
| Release SHA attested before anything publishes | `release.yml` `attest-guard` job (first job; everything else `needs` it) | Yes, fail-closed |
| Full gate set green on the attested SHA | This procedure (step 2) + the Buildkite `release-attest` step (b) | Procedure + step |
| Release tag commit equals the attested SHA | `attest-guard` (dispatch path, strict equality) and `release-attest` step (c), post-publish | Yes, fail-closed |

The GitHub Actions workflow is a release publisher, not a CI twin:
Buildkite remains the sole automatic CI engine. Nothing in `release.yml`
builds or publishes an artifact unless `attest-guard` passed.

## Prerequisites

- `bk` CLI authenticated against the Buildkite org
  (`bk auth login`; builds visible at `abyssbugg/version-management`).
- Git push access to the GitHub repository.
- The release-prep commits (including any `package.json` version bump —
  `validate` enforces the tag match) already pushed to `main`.

## Attestation flow (end to end)

### 1. Record the exact release SHA

```sh
SHA="$(git rev-parse origin/main)"
echo "Release SHA: $SHA"
```

### 2. Assert the full gate set ran green on that SHA in Buildkite

Web: open `https://buildkite.com/abyssbugg/version-management`, find the
build for the commit, and confirm **all six** steps green: ShellCheck Lint
(`lint`), Syntax Validation (`syntax`), Pre-commit Hooks (`pre-commit`),
Secret Scan (`secret-scan`), Tests Linux (`test-linux`), Tests macOS
(`test-macos`).

CLI (`bk build list --pipeline version-management`), verified one-liner:

```sh
bk build list --pipeline version-management | python3 -c '
import json, sys
sha = sys.argv[1]
required = {"lint", "syntax", "pre-commit", "secret-scan", "test-linux", "test-macos"}
for b in json.load(sys.stdin):
    if b.get("commit") != sha or b.get("state") != "passed":
        continue
    passed = {j.get("step_key") for j in b.get("jobs", [])
              if j.get("state") == "passed" and j.get("step_key")}
    if required <= passed:
        print("GATES GREEN:", b["web_url"])
        sys.exit(0)
print("NOT ATTESTED: no green full-gate build for", sha)
sys.exit(1)
' "$SHA"
```

A marker may not be recorded until this prints `GATES GREEN`.

### 3. Record the attestation marker (primary tag-push path)

The marker names the attested commit — a self-referential marker for the
tag commit itself is impossible (committing the file changes the SHA it
would name), so the marker always names the release-prep commit and the
tag is cut on the marker commit:

```sh
printf '%s\n' "$SHA" > ".release-attested-$SHA"
git add ".release-attested-$SHA"
git commit -m "attest: release SHA $SHA [B2.3]"
git push origin main
```

Wait for the Buildkite build of this marker commit to pass (marker-only
diff). Markers accumulate in the repository root as an attestation ledger.

### 4. Tag and publish

```sh
git tag "v$VERSION"   # at the marker commit (HEAD of main)
git push origin "v$VERSION"
```

The tag push fires `release.yml`; the `attest-guard` job accepts only if
the tag's tree contains a `.release-attested-<sha>` marker whose content
equals `<sha>` and whose sha is an ancestor of the tag commit. Confirm the
run shows `Release attested for SHA: <sha>` before treating the release as
published.

### Fallback: workflow_dispatch (re-runs and exceptional releases)

If the automatic tag-push run needs a re-run (transient infra failure),
dispatch `release.yml` manually and supply:

- `version` — the release version (e.g. `1.2.3`);
- `attested_sha` — **required, fail-closed**: the full 40-hex commit SHA,
  which must equal the commit of tag `v$VERSION` exactly (strict
  equality; a mismatch or empty input refuses the release).

Repeat step 2 for the tag's commit before dispatching.

### 5. Post-publish: verify release ↔ SHA continuity

After the GitHub release publishes, trigger the Buildkite
`release-attest` step (dormant unless `RELEASE_ATTEST_SHA` is set):

```sh
TAG_COMMIT="$(git ls-remote origin "refs/tags/v$VERSION^{}" | awk 'NR==1{print $1}')"
bk build create \
  -p version-management -b main \
  -m "release-attest: v$VERSION" \
  -e "RELEASE_ATTEST_SHA=$TAG_COMMIT" \
  -e "RELEASE_ATTEST_TAG=v$VERSION"
```

The step then (a) records the attested SHA as a build artifact,
(b) asserts the full gate set ran green on that SHA in this pipeline
(Buildkite REST API; fails closed without `BUILDKITE_ACCESS_TOKEN`), and
(c) asserts the release tag's commit on origin equals the attested SHA.
Artifacts land under `release-attestation/` on the build page.

Manual equivalent of (c):

```sh
git ls-remote origin "refs/tags/v$VERSION^{}"   # must print the attested SHA
```

### 6. Consumer verification

```sh
sha256sum -c checksums.txt
```

`checksums.txt` covers every published asset (tarball, zip, attribution,
security policy, both SBOMs); it is finalized in the release job after the
Syft SBOM exists, so the shipped manifest is complete.

## SBOMs shipped with a release

- `sbom.spdx.txt` — deterministic source SBOM
  (`scripts/release-sbom.sh`); byte-identical across runs of the same
  tree.
- `sbom-syft.spdx.json` — SPDX-2.3 JSON of the **built artifacts**,
  generated by Syft v1.54.0 installed from a pinned release with an
  inline, independently verified sha256 (discipline per
  ENGINEERING_RULES §7.1).

Both are covered by `checksums.txt` and attached to the release.

## Artifact signing (owner decision)

The `signing` job in `release.yml` is **structure only and hard-disabled**
(`if: false`); every step body is an inert, commented cosign template.
Signing itself requires owner decisions and MUST NOT be enabled before
they are made. Prerequisites:

1. **Signer model.** Cosign keyless (Sigstore OIDC — runner needs
   `permissions: { id-token: write }`, no stored key material) vs.
   key-based (requires a KMS/HSM or an encrypted key in a GitHub secret;
   never a key file in the repository).
2. **Signing scope.** Which artifacts to sign (tarball, zip, and
   `checksums.txt`; signing `checksums.txt` alone is the weaker option)
   and whether to attach `sbom-syft.spdx.json` as a signed cosign
   attestation (`cosign attest --type spdxjson`).
3. **Build provenance.** Whether to add GitHub artifact attestations
   (`actions/attest-build-provenance`, SHA-pinned) alongside cosign.
4. **Consumer verification.** Publish `.sig`/`.pem` sidecars in the
   release files list and document `cosign verify-blob` here.
5. **Ordering.** Keep `attest-guard` gating the release; signing extends
   the chain, it does not replace it.

To enable: install a pinned cosign release (inline sha256, same pattern
as the `sbom` job's Syft install), uncomment the templates in the
`signing` job, remove the `if: false` guard, and update this section plus
the OPERATIONS.md release path.
