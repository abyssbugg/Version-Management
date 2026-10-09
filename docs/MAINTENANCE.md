# Maintenance Runbook

Maintenance procedures for the version-management-setup repository. This
runbook is for maintainers of the repository (CI, pins, releases). For
operating the suite on a workstation see [OPERATIONS.md](OPERATIONS.md); for
the security model and known gaps see [SECURITY.md](SECURITY.md). The
mutation inventory lives in
[governance/MUTATION_REGISTRY.md](governance/MUTATION_REGISTRY.md).

Every command in this document is taken from files that exist in the
repository (Makefile, `.buildkite/pipeline.yml`, the GitHub workflows, or
OPERATIONS.md) — nothing here is aspirational.

## 1. Pins and versions (review cadence)

The repository pins every third-party dependency by immutable reference with
a version comment (ENGINEERING_RULES §6.2; adjudication in
[MASTER_AUDIT.md §5.1](governance/MASTER_AUDIT.md)). Review all pins:

- **Recommended cadence:** verify the full pin set before tagging a release
  (the release freeze rule in [OPERATIONS.md](OPERATIONS.md), "Release
  path", applies while a milestone gate is open), and re-verify quarterly or
  whenever an upstream advisory lands. Pin changes to `release.yml` and
  `test.yml` are made together — the two workflows mirror each other's
  actions.

### 1.1 GitHub Actions pins (immutable commit SHAs)

All third-party actions are pinned to full commit SHAs with a `# vX.Y.Z`
version comment. Current set (verified against upstream via
`git ls-remote` on 2026-10-04, M5 lane R, for the original set; the
`sigstore/cosign-installer` row on 2026-10-09, lane L6 — evidence below):

| Action | Pin | Version | Used in |
|--------|-----|---------|---------|
| `actions/checkout` | `11bd71901bbe5b1630ceea73d27597364c9af683` | v4.2.2 | `release.yml`, `test.yml` |
| `actions/setup-python` | `a26af69be951a213d495a4c3e4e4022e16d87065` | v5.6.0 | `release.yml`, `test.yml` |
| `gitleaks/gitleaks-action` | `ff98106e4c7b2bc287b24eaf42907196329070c7` | v2.3.9 | `release.yml`, `test.yml` |
| `actions/upload-artifact` | `4cec3d8aa04e39d1a68397de0c4cd6fb9dce8ec1` | v4.6.1 | `release.yml` |
| `actions/download-artifact` | `cc203385981b70ca67e1cc392babf9cc229d5806` | v4.1.9 | `release.yml` |
| `softprops/action-gh-release` | `da05d552573ad5aba039eaac05058a918a7bf631` | v2.2.2 | `release.yml` |
| `sigstore/cosign-installer` | `7e8b541eb2e61bf99390e1afd4be13a184e9ebc5` | v3.10.1 | `release.yml` (`sign` job) |
| `actions/upload-artifact` | `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a` | v7.0.1 | `test.yml` |

cosign pin evidence (lane L6):

- `git ls-remote https://github.com/sigstore/cosign-installer 'refs/tags/v3.10.1*'`
  printed only `7e8b541eb2e61bf99390e1afd4be13a184e9ebc5 refs/tags/v3.10.1`
  — a lightweight tag (no `^{}` entry), so that SHA is the commit.
- The installer's `action.yml` at that commit declares the
  `cosign-release` input (default `v2.6.1`), downloads the bootstrap
  cosign `v2.6.1` and compares it with an sha256 embedded in the action
  itself, exiting early when `cosign-release` equals the bootstrap
  version. `release.yml` pins `cosign-release: 'v2.6.1'`, so the installed
  binary is exactly that inline-checksum-verified bootstrap (no runtime key
  fetch). Any other `cosign-release` would instead be verified by a
  detached `.sig` against cosign's release public key — re-check that path
  before changing the version.
- `git ls-remote https://github.com/sigstore/cosign 'refs/tags/v2.6.1' 'refs/tags/v2.6.1^{}'`
  printed `aaff551af285e58f7b6d60695be04af1b55f2684` (tag object) and
  `634fabe54f9fbbab55d821a83ba93b2d25bdba5f` (peeled commit).
- Bumping the installer changes its bootstrap version and inline digests:
  re-read its `action.yml` at the new SHA and keep `cosign-release` equal
  to the new bootstrap version (or re-verify the `.sig` path).

Note: the `actions/upload-artifact` major versions intentionally differ
(v4.6.1 in `release.yml`, v7.0.1 in `test.yml`, as inherited from each
workflow's prior state); aligning them is a deliberate, verified change, not
drive-by maintenance.

How to verify a pin against upstream before updating it (compare the
peeled commit with the pinned SHA):

```bash
git ls-remote https://github.com/actions/checkout \
  'refs/tags/v4.2.2' 'refs/tags/v4.2.2^{}'
```

The pinned SHA must equal the commit the tag peels to (`refs/tags/<tag>^{}`
for annotated tags). M5 lane R found and fixed two pre-existing pins whose
SHAs did not exist in the upstream history (`actions/download-artifact`,
`softprops/action-gh-release`) — such pins fail to resolve at runtime, which
is why this verification is mandatory for every new pin.

### 1.2 gitleaks versions

Two independent gitleaks channels must be reviewed together:

- **Buildkite** installs a pinned release binary:
  `gitleaks v8.28.0` (`.buildkite/pipeline.yml`, "Secret Scan (gitleaks)"
  step). Update the version string and download URL there.
- **GitHub Actions** uses the SHA-pinned
  `gitleaks/gitleaks-action` (v2.3.9, see table above) in both workflows.

Check current upstream releases at
`https://github.com/gitleaks/gitleaks/releases` and
`https://github.com/gitleaks/gitleaks-action/releases` before bumping.

### 1.3 NVM pin

`lib/nvm.sh` is the single source of truth for the NVM pin:

```bash
grep -n 'NVM_VERSION=' lib/nvm.sh
# lib/nvm.sh:24:  NVM_VERSION="${NVM_VERSION:-v0.39.7}"
```

The pin is env-overridable (`NVM_VERSION=...`) and consumed by
`nvm_install` (`lib/nvm.sh:96`). Known remainder: `setup-versions.sh:120`
still hardcodes `v0.39.7` in install-guidance text (MASTER_AUDIT P2-6
remainder; ROADMAP M5-GO remainder list) — it must be updated when the pin
changes or, better, made to consume `$NVM_VERSION`.

### 1.4 Other dependency surfaces

- **pre-commit hook revisions** (`.pre-commit-config.yaml`): shellcheck-py
  `v0.9.0.6`, pre-commit-shfmt `v3.7.0-4`, pre-commit-hooks `v4.5.0`,
  markdownlint-cli `v0.38.0`.
- **Bash contract:** the test suite and executables require bash >= 4.0
  (ENGINEERING_RULES §3.1); macOS `/bin/bash` 3.2 is not sufficient.

## 2. Where backups, the audit journal, and logs live

Facts below are from [OPERATIONS.md](OPERATIONS.md) (§"Backups,
transactions, and the audit journal"), which is authoritative:

| Location | Contents |
|----------|----------|
| `~/.config-backups/<file>.backup.<timestamp>` | Per-file backups; retention defaults to 10 per file / 30 days (`BACKUP_MAX_FILES`, `BACKUP_MAX_AGE`) |
| `~/.config-backups/transactions/<name>.XXXXXX/` | One directory per transaction (`metadata.json`, `files.tsv`, `new_files.txt`, `files/<NNNN>/data`) |
| `~/.config-backups/restore_points/<name>/` | Named restore points |
| `~/.config/version-manager/audit.log` | Audit journal (override: `TXN_AUDIT_LOG`) |
| `~/.local/share/version-manager/logs/` | Runtime logs, `version-manager-<date>.log` (override: `LOG_FILE`) |
| `~/.config/version-manager/trusted-projects` | Auto-activation trust registry (M3) |

Inspect a transaction's outcome via `metadata.json` `status` (`active`,
`committed`, `rolled_back`, or `rolled_back_with_errors` — the last means
the restore did NOT fully succeed; reconcile manually), and the journal:

```bash
tail -n 20 ~/.config/version-manager/audit.log
grep -c "rollback" ~/.config/version-manager/audit.log
```

## 3. Routine gates (make targets)

All of the following exist in the `Makefile` and are the standing gate set
(M0: every target is routed through `tests/test_runner.sh` via
`tests/emit-manifest.sh` and emits the canonical manifest):

| Target | Purpose |
|--------|---------|
| `make lint` | ShellCheck via `./scripts/lint-shell.sh` (gating) |
| `make syntax-check` | Fail-closed `bash -n` + `zsh -n` gate (`scripts/syntax-check.sh`) |
| `make test` | All tests; emits `test-results/manifest.json` |
| `make test-unit` | Unit tests only |
| `make test-integration` | Integration tests only (sandboxed HOME — safe to run) |
| `make validate` | Zero-tolerance quality gate (`./tools/validate-quality.sh`) |
| `make clean` | Scoped cleanup: `${TMPDIR:-/tmp}/version-management-setup/` + repo-local `test-results/` (B2.2) |
| `make coverage` | Intent-tracking coverage report (P1-11: not a real coverage engine) |

Local pre-commit equivalent (used by CI as well):

```bash
pre-commit run --all-files --show-diff-on-failure
```

## 4. CI flow (Buildkite)

- **Buildkite is the sole automatic CI engine** (`.buildkite/pipeline.yml`,
  hosted queues `linux-small` / `macos-medium`):
  - Group "Linting & Validation": ShellCheck lint, fail-closed syntax gate,
    pre-commit, gitleaks secret scan.
  - Group "Tests": Linux + macOS matrices, each emitting the canonical test
    manifest (`test-results/manifest.json`, `.tsv`) as a fail-closed
    artifact.
- **GitHub Actions `test.yml` is a manual-only fallback**
  (`workflow_dispatch`) so the two engines never double-fire.
- Test platform note: bash >= 4.0 (ENGINEERING_RULES §3.1).

## 5. Release flow

Trigger (unchanged): push a tag `v*.*.*` or run
`.github/workflows/release.yml` via `workflow_dispatch` with an explicit
version input. The release freeze is in effect whenever a milestone gate is
open — check [governance/ROADMAP.md](governance/ROADMAP.md) before tagging.

### 5.1 Gates (all before any artifact is built or published)

1. `validate` — version format check and `package.json` ↔ tag mismatch
   check (mismatch exits 1; P0-2).
2. `test` — `make syntax-check`, `make lint` (gating; P0-1), `make test`.
3. `secret-scan` — gitleaks (`gitleaks/gitleaks-action`, mirror of
   `test.yml`), gates the build job (M5 release-path clause).
4. `pre-commit` — `pre-commit run --all-files --show-diff-on-failure`,
   gates the build job (M5 release-path clause).

The `build` job declares
`needs: [attest-guard, validate, test, secret-scan, pre-commit]`
(`.github/workflows/release.yml`), so a tagged push can no longer bypass
the CI gate set.

Release-commit binding (REL-PROV): every job that checks out code checks
out `ref: needs.attest-guard.outputs.release_sha` (the release tag's
commit), never `github.ref` (the dispatching branch on a manual run), and
`build` asserts `HEAD == release_sha` with a clean tree before archiving
(docs/RELEASE_CHECKLIST.md, "Release-commit binding").

### 5.2 Artifacts

The `build`, `sbom`, and `sign` jobs produce, and the `release` job
publishes unchanged:

| Artifact | What it is |
|----------|------------|
| `version-manager-suite-<V>.tar.gz` / `.zip` | Source archives (include `FontPatcher/` with its bundled license files and `docs/`; exclude dev/CI dirs, `tmp_rovodev_*` scratch files, and local `coverage/`, `test-results/`, `patched-fonts/` outputs) |
| `ATTRIBUTION.md` | Copy of `FontPatcher/ATTRIBUTION.md` — the authoritative per-component glyph license table (P1-10) |
| `SECURITY.md` | Copy of `docs/SECURITY.md` — trust boundaries and reporting path |
| `sbom.spdx.txt` | Deterministic SPDX-lite SBOM (see 5.3) |
| `sbom-syft.spdx.json` | Syft SPDX-2.3 SBOM of the built artifacts (`sbom` job) |
| `checksums.txt` | SHA-256 of every other published artifact except the bundles below; finalized in the `sign` job |
| `checksums.txt.bundle` / `sbom.spdx.txt.bundle` / `sbom-syft.spdx.json.bundle` | Cosign keyless signature bundles (see 5.5); outside `checksums.txt` by design — they sign it |

### 5.3 SBOM

`scripts/release-sbom.sh` generates `sbom.spdx.txt` in the build job:

- Deterministic: no timestamps or randomness; the `GenerationCommand:` line
  inside the SBOM is the reproducibility contract. Rerunning the command in
  the same worktree yields byte-identical output.
- Font glyph-set components are mapped **mechanically** from
  `FontPatcher/ATTRIBUTION.md`'s "Component license table" (verbatim cell
  text). The two components whose licenses ATTRIBUTION.md could not resolve
  are flagged `UNRESOLVED` exactly as ATTRIBUTION.md flags them — never
  guessed. An unparsable table fails closed (no SBOM emitted).
- Also records: shell-script inventory counts (`git ls-files -- '*.sh'`)
  and the third-party action pins read from `.github/workflows/*.yml`.
- The SBOM is itself **signed**: `sbom.spdx.txt.bundle` is the cosign
  keyless signature published alongside it (see 5.5).

Local regeneration check (must be byte-identical):

```bash
./scripts/release-sbom.sh --version "$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' package.json | head -n 1)" > /tmp/sbom-1.txt
./scripts/release-sbom.sh --version "$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' package.json | head -n 1)" > /tmp/sbom-2.txt
sha256sum /tmp/sbom-1.txt /tmp/sbom-2.txt
```

### 5.4 How a consumer verifies a release

Download all release assets (including `checksums.txt` and the `.bundle`
files) into one directory. First authenticate `checksums.txt` with cosign
(5.5), then verify every artifact against it:

```bash
sha256sum -c checksums.txt          # Linux / GNU coreutils
shasum -a 256 -c checksums.txt      # macOS
```

Expected output: one `OK` line per artifact and exit code 0. `checksums.txt`
is generated inside the `dist/` directory over the published filenames, so
verification must run in the directory where the assets were downloaded.
This checksum verification checks each artifact's **integrity**; the cosign
signature (5.5) authenticates `checksums.txt` **itself**, so together the
two steps authenticate the whole release set.

### 5.5 Signing — cosign keyless (P1-6, implemented)

- **Mechanism:** the `sign` job signs `checksums.txt`, `sbom.spdx.txt`,
  and `sbom-syft.spdx.json` with `cosign sign-blob --yes --bundle`
  using the runner's GitHub OIDC token (keyless — no stored key). It is
  the only job with `id-token: write`; only the `release` job has
  `contents: write`; the workflow default is `contents: read`.
- **Fail-closed self-check:** the same job runs `cosign verify-blob` on
  every bundle with issuer `https://token.actions.githubusercontent.com`
  and identity regexp
  `^https://github\.com/<owner>/<repo>/\.github/workflows/release\.yml@`
  (derived from `github.repository`, dots escaped) before uploading the
  `release-signed` artifact the release job publishes.
- **Consumer commands and identity policy:**
  [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md), "Artifact signing".
- **Pins:** `sigstore/cosign-installer` v3.10.1 and `cosign-release`
  v2.6.1 — table and evidence in 1.1.
- **Live proof pending:** keyless signing cannot be exercised without a
  real release; the first tagged release after this change is the first
  end-to-end proof (OIDC, Fulcio, Rekor, certificate identity, consumer
  verification).

## 6. Known risks and gaps

- `docs/SECURITY.md` §"Known gaps" is the authoritative known-gap list;
  keep it in sync instead of duplicating entries here.
- **`lib/rustup.sh` network-installer path** (pre-existing, adjudicated
  scope): executes downloaded content after size + shebang checks only.
  This is a recorded, pre-existing adjudication (remediation directive
  §B item 8) — not re-adjudicated here; treat as a known supply-chain risk
  and do not weaken it further.
- **NVM pin duplication remainder:** `setup-versions.sh:120` guidance text
  hardcodes `v0.39.7` while the single pin lives in `lib/nvm.sh:24`
  (MASTER_AUDIT P2-6 remainder).
- Master tracking: [governance/ROADMAP.md](governance/ROADMAP.md) (M5-GO
  remainder) and [governance/MASTER_AUDIT.md](governance/MASTER_AUDIT.md).
