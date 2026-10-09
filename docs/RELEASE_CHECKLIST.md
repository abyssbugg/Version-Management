# Release Checklist

Operational contract for cutting a release of **version-management-setup**.
This is the release-path half of the attestation-continuity requirement
(B2.3) and the SBOM/signing remainder (P1-6); policy lives in
[ENGINEERING_RULES.md](governance/ENGINEERING_RULES.md) §6 and the runbook
section [OPERATIONS.md](OPERATIONS.md) "Release path".

## What enforces what

| Check | Enforcer | Automatic |
| ----- | -------- | --------- |
| ShellCheck lint, fail-closed syntax, pre-commit, gitleaks, tests (Linux + macOS), kcov coverage | Buildkite on every push (`.buildkite/pipeline.yml`) | Yes |
| Version consistency (`package.json` ↔ release tag) | `release.yml` `validate` job | Yes |
| Release SHA attested before anything publishes | `release.yml` `attest-guard` job (first job; everything else `needs` it) | Yes, fail-closed |
| Every job tests, archives, signs, and publishes the release commit (`release_sha`) | `attest-guard` output `release_sha`; every checkout pins `ref:` to it; `build` asserts `HEAD == release_sha` and a clean tree before archiving | Yes, fail-closed |
| Full gate set green on the attested SHA | This procedure (step 2) + the Buildkite `release-attest` step (b) | Procedure + step |
| Release tag commit equals the attested SHA | `attest-guard` (dispatch path, strict equality) and `release-attest` step (c), post-publish | Yes, fail-closed |
| `checksums.txt` and both SBOMs signed (cosign keyless) and the signatures verify against this workflow's identity | `release.yml` `sign` job (self-verification before `release` may run) | Yes, fail-closed |

The GitHub Actions workflow is a release publisher, not a CI twin:
Buildkite remains the sole automatic CI engine. Nothing in `release.yml`
builds or publishes an artifact unless `attest-guard` passed.

## Release-commit binding (`release_sha`, REL-PROV)

`attest-guard` emits two outputs: `attested_sha` (the Buildkite-green
commit) and `release_sha` (the commit that is built and shipped):

- **Tag push:** `release_sha` is the tag's peeled commit; `attested_sha` is
  the ancestor named by the `.release-attested-<sha>` marker.
- **workflow_dispatch:** `release_sha` is the commit of tag `v<version>`,
  which `attest-guard` has already required to equal `attested_sha`.

`attest-guard` fails closed unless `release_sha` is a full 40-hex SHA.
Every other job that checks out code (`validate`, `test`, `secret-scan`,
`pre-commit`, `build`, `sbom`, `sign`, `release`) checks out
`ref: release_sha` — never `github.ref`, which on a dispatch is the
*branch* the workflow was started from. The `build` job then asserts
`git rev-parse HEAD` equals `release_sha` and that the working tree has no
modifications or untracked files before it creates any archive. The
release notes' changelog is computed from that same `HEAD`.

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
build for the commit, and confirm **all seven** steps green: ShellCheck Lint
(`lint`), Syntax Validation (`syntax`), Pre-commit Hooks (`pre-commit`),
Secret Scan (`secret-scan`), Tests Linux (`test-linux`), Tests macOS
(`test-macos`), Coverage kcov (`coverage-kcov`). This is the same set the
`release-attest` step (b) requires.

CLI (`bk build list --pipeline version-management`), verified one-liner:

```sh
bk build list --pipeline version-management | python3 -c '
import json, sys
sha = sys.argv[1]
required = {"lint", "syntax", "pre-commit", "secret-scan", "test-linux", "test-macos", "coverage-kcov"}
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
run shows `Release attested for SHA: <sha>` and
`Release commit (built, tested, signed, published): <tag commit>` before
treating the release as published.

### Fallback: workflow_dispatch (re-runs and exceptional releases)

If the automatic tag-push run needs a re-run (transient infra failure),
dispatch `release.yml` manually and supply:

- `version` — the release version (e.g. `1.2.3`);
- `attested_sha` — **required, fail-closed**: the full 40-hex commit SHA,
  which must equal the commit of tag `v$VERSION` exactly (strict
  equality; a mismatch or empty input refuses the release).

Repeat step 2 for the tag's commit before dispatching. The branch you
dispatch from only selects which `release.yml` definition runs; the code
that is tested, archived, signed, and published is the tag commit
(`release_sha`, see "Release-commit binding" above).

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

Download every release asset into one directory, then authenticate the
manifest and check every artifact against it (full commands and the
identity policy: "Artifact signing" below):

```sh
cosign verify-blob --bundle checksums.txt.bundle \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/abyssbugg/Version-Management/\.github/workflows/release\.yml@' \
  checksums.txt
sha256sum -c checksums.txt
```

`checksums.txt` covers every published asset except the signature
bundles (tarball, zip, attribution, security policy, both SBOMs); it is
finalized in the `sign` job after the Syft SBOM exists and before any
bundle is written, so the shipped — and signed — manifest is complete.

## SBOMs shipped with a release

- `sbom.spdx.txt` — deterministic source SBOM
  (`scripts/release-sbom.sh`); byte-identical across runs of the same
  tree.
- `sbom-syft.spdx.json` — SPDX-2.3 JSON of the **built artifacts**,
  generated by Syft v1.54.0 installed from a pinned release with an
  inline, independently verified sha256 (discipline per
  ENGINEERING_RULES §7.1).

Both are covered by `checksums.txt`, each is also signed individually
(`sbom.spdx.txt.bundle`, `sbom-syft.spdx.json.bundle`), and all four files
are attached to the release.

## Artifact signing (P1-6 — implemented: cosign keyless)

Owner decision: **cosign keyless signing via GitHub OIDC**. No signing key
exists anywhere — not in the repository, not in a GitHub secret, not in a
KMS. The `sign` job in `release.yml` is the only job with
`id-token: write`; it mints the runner's OIDC token, Fulcio issues a
short-lived certificate bound to the workflow identity, and Rekor (the
public transparency log) records each signature.

**What is signed.** Three files, one Sigstore bundle each (certificate +
signature + transparency-log proof in a single file):

| Signed file | Bundle published next to it |
| ----------- | --------------------------- |
| `checksums.txt` (transitively covers the tarball, zip, `ATTRIBUTION.md`, `SECURITY.md`, both SBOMs) | `checksums.txt.bundle` |
| `sbom.spdx.txt` | `sbom.spdx.txt.bundle` |
| `sbom-syft.spdx.json` | `sbom-syft.spdx.json.bundle` |

The bundles are deliberately **outside** `checksums.txt`: they sign it, so
listing them inside would be circular. They are verified with cosign, not
`sha256sum`.

**Ordering in `release.yml`.** `build` → `sbom` → `sign` (finalize
`checksums.txt` over the full set, sign the three files, self-verify,
upload the artifact `release-signed`) → `release` (downloads only
`release-signed`, publishes it unchanged including `dist/*.bundle`;
`contents: write` exists only here). `attest-guard` still gates
everything: signing extends the attestation chain, it does not replace it.

**Identity policy** (applied by the `sign` job's fail-closed self-check
and by consumers):

- OIDC issuer: exactly `https://token.actions.githubusercontent.com`.
- Certificate identity: matches
  `^https://github\.com/abyssbugg/Version-Management/\.github/workflows/release\.yml@`
  — i.e. this repository's `release.yml`, at any ref. A tag-push release
  carries `@refs/tags/v<version>`; a workflow_dispatch re-run carries the
  ref of the branch it was dispatched from (the *content* is still the tag
  commit — see "Release-commit binding"). In the workflow the regexp is
  derived from `github.repository` with dots escaped.

**Tooling pins.** `sigstore/cosign-installer` v3.10.1, pinned by commit
`7e8b541eb2e61bf99390e1afd4be13a184e9ebc5`; `cosign-release: v2.6.1`,
which is the installer's bootstrap version, so the binary is checked
against the inline sha256 embedded in the pinned action. Verification
evidence: [MAINTENANCE.md](MAINTENANCE.md) §1.1.

**Consumer verification** (cosign v2.x client, matching the v2.6.1
signer; other client versions are not verified by this repository). In
the directory holding all downloaded release assets:

```sh
ID_RE='^https://github\.com/abyssbugg/Version-Management/\.github/workflows/release\.yml@'
for f in checksums.txt sbom.spdx.txt sbom-syft.spdx.json; do
  cosign verify-blob \
    --bundle "$f.bundle" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity-regexp "$ID_RE" \
    "$f" || { echo "SIGNATURE FAILED: $f"; exit 1; }
done
sha256sum -c checksums.txt        # macOS: shasum -a 256 -c checksums.txt
```

For a tag-push release a consumer may tighten the identity to the exact
tag, e.g.
`--certificate-identity 'https://github.com/abyssbugg/Version-Management/.github/workflows/release.yml@refs/tags/v1.2.3'`.

**Not yet proven live.** The signing path cannot be exercised without
cutting a release: OIDC token minting, Fulcio issuance, Rekor upload, the
exact certificate SAN (including the repository-name casing in the
identity regexp), and consumer verification of published assets are
proven for the first time by the **first tagged release** after this
change. Treat that release's `sign` job log and a consumer-side run of
the commands above as the end-to-end acceptance evidence.
