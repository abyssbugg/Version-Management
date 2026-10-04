#!/usr/bin/env bash
# =============================================================================
# release-sbom.sh — deterministic SPDX-lite SBOM (ROADMAP M5; P1-6 remainder)
# =============================================================================
# Generates a byte-deterministic SBOM text for the release artifact set:
#
#   * repo name/version — read from package.json (--version overrides, as
#     the release workflow passes the tag-derived version)
#   * the generation command — recorded instead of a timestamp; the script
#     emits NO timestamps, NO randomness, NO network access. Determinism
#     contract: same worktree + same arguments => byte-identical output
#     (asserted in CI by design and checked locally by running it twice).
#   * per-component entries for the bundled FontPatcher glyph sets —
#     licenses are mapped MECHANICALLY from the "Component license table"
#     in FontPatcher/ATTRIBUTION.md (verbatim cells). The two components
#     whose licenses ATTRIBUTION.md could not resolve are flagged exactly
#     as ATTRIBUTION.md flags them ("Not stated in the bundled files") —
#     never guessed. If the table cannot be parsed, the script FAILS
#     CLOSED instead of emitting an SBOM without licenses.
#   * shell-script inventory counts (git-tracked *.sh, LC_ALL=C-sorted)
#   * third-party action dependency pins read from .github/workflows/*.yml
#
# Signing is intentionally NOT part of this script: the current release
# integrity mechanism is the published checksums.txt (SHA-256). Keyless
# signing is a documented follow-up decision for the owner — see
# docs/MAINTENANCE.md.
#
# Exit codes: 0 = SBOM emitted; 1 = fail-closed (missing inputs, unparsable
# license table, empty required fields).
# =============================================================================

set -euo pipefail
export LC_ALL=C

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ATTRIBUTION_FILE="FontPatcher/ATTRIBUTION.md"
PACKAGE_JSON="package.json"

usage() {
    cat <<'USAGE'
Usage: scripts/release-sbom.sh [--version X.Y.Z] [--output FILE]

  --version   SBOM document version. Default: package.json "version".
              The release workflow passes the tag-derived version.
  --output    Write the SBOM to FILE (atomically: tmp + mv).
              Default: stdout.

Determinism: output depends only on the worktree contents and the two
arguments above. No timestamps, no randomness, no network.
USAGE
}

version=""
output=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            version="${2:?--version requires a value}"
            shift 2
            ;;
        --output)
            output="${2:?--output requires a value}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'release-sbom: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

fail() {
    printf 'release-sbom: FAIL: %s\n' "$*" >&2
    exit 1
}

# ---- Fail-closed input checks ----------------------------------------------
[[ -f "$ATTRIBUTION_FILE" ]] || fail "missing $ATTRIBUTION_FILE (mechanical license source)"
[[ -f "$PACKAGE_JSON" ]] || fail "missing $PACKAGE_JSON"

if [[ -z "$version" ]]; then
    version="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$PACKAGE_JSON" | head -n 1)"
    [[ -n "$version" ]] || fail "could not read \"version\" from $PACKAGE_JSON"
fi
[[ "$version" =~ ^[A-Za-z0-9._-]+$ ]] || fail "version '$version' contains characters outside [A-Za-z0-9._-]"

if [[ -n "$output" ]]; then
    [[ "$output" != */ ]] || fail "--output must name a file, not a directory: $output"
fi

name="$(sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' "$PACKAGE_JSON" | head -n 1)"
[[ -n "$name" ]] || fail "could not read \"name\" from $PACKAGE_JSON"
pkg_license="$(sed -n 's/.*"license": *"\([^"]*\)".*/\1/p' "$PACKAGE_JSON" | head -n 1)"
[[ -n "$pkg_license" ]] || fail "could not read \"license\" from $PACKAGE_JSON"

# ---- Mechanical license-table extraction -----------------------------------
# Extracts the data rows of FontPatcher/ATTRIBUTION.md's
# "## Component license table" as tab-separated fields (verbatim cell text,
# whitespace-trimmed only). Nothing is invented: if the table shape changes,
# validation below fails closed rather than emitting guessed licenses.
extract_table_rows() {
    awk '
        /^## Component license table/ { in_table = 1; next }
        in_table && /^## / { exit }
        in_table && /^\|/ {
            if ($0 ~ /^\|[ \t]*Component[ \t]*\|/) next   # header row
            if ($0 ~ /^\|[ \t]*---/) next                 # separator row
            print
        }
    ' "$ATTRIBUTION_FILE" \
        | awk -F'|' '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        {
            comp    = trim($2)
            path    = trim($3)
            lic     = trim($4)
            licfile = trim($5)
            vers    = trim($6)
            up      = trim($7)
            printf "%s\t%s\t%s\t%s\t%s\t%s\n", comp, path, lic, licfile, vers, up
        }'
}

# Validate the parsed table BEFORE emitting anything (fail-closed: a broken
# table must never produce an SBOM with fabricated or missing licenses).
rowcount="$(extract_table_rows | grep -c . || true)"
if (( rowcount < 1 )); then
    fail "mechanical parse of $ATTRIBUTION_FILE yielded no component rows; refusing to emit an SBOM with guessed licenses"
fi
extract_table_rows | awk -F'\t' '
    NF < 6 || $1 == "" || $3 == "" { bad = 1 }
    END { exit bad ? 1 : 0 }
' || fail "license table parse error (empty component or license cell) in $ATTRIBUTION_FILE"

# ---- Emitter: font components from the ATTRIBUTION table -------------------
# Row order and cell text are the ATTRIBUTION.md order verbatim; SPDXIDs are
# sequential (001, 002, ...) in table order. Deterministic by construction.
emit_font_components() {
    extract_table_rows | awk -F'\t' '
    BEGIN { n = 0 }
    {
        n++
        comp = $1; path = $2; lic = $3; licfile = $4; vers = $5; up = $6

        slug = tolower(comp)
        gsub(/[^a-z0-9]+/, "-", slug)
        gsub(/^-+|-+$/, "", slug)
        spdxid = sprintf("SPDXRef-Package-font-%03d-%s", n, slug)

        printf "\n"
        printf "PackageName: %s\n", comp
        printf "SPDXID: %s\n", spdxid
        printf "PackagePath: %s\n", path
        printf "PackageVersion: %s\n", vers
        printf "PackageDownloadLocation: NOASSERTION\n"
        printf "LicenseDeclared: %s\n", lic
        printf "LicenseFiles: %s\n", licfile
        printf "Upstream: %s\n", up
        # Mechanical flag, mirroring the ATTRIBUTION.md table itself: rows it
        # could not resolve are carried verbatim and marked UNRESOLVED; the
        # rest mirror its "verified from bundled file" column. Never guessed.
        if (lic ~ /Not stated in the bundled files/) {
            printf "LicenseVerification: UNRESOLVED per FontPatcher/ATTRIBUTION.md (license not stated in the bundled files)\n"
        } else {
            printf "LicenseVerification: per FontPatcher/ATTRIBUTION.md (verified from bundled license file)\n"
        }
        printf "Relationship: SPDXRef-Package-root CONTAINS %s\n", spdxid
    }'
}

# ---- Shell-script inventory (git-tracked, deterministic) --------------------
emit_shell_inventory() {
    if ! command -v git >/dev/null 2>&1; then
        fail "git not found; the shell-script inventory must come from the tracked set"
    fi
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        fail "not inside a git worktree; refusing to inventory untracked files (non-deterministic)"
    fi
    printf "ShellScriptInventorySource: git ls-files -- '*.sh' (LC_ALL=C-sorted)\n"
    printf "ShellScriptCountTotal: %s\n" \
        "$(git ls-files -- '*.sh' | grep -c . || true)"
    git ls-files -- '*.sh' | awk -F'/' '
        {
            if (NF > 1) seg = $1
            else seg = "(repo root)"
            cnt[seg]++
        }
        END {
            for (s in cnt) printf "%s\t%d\n", s, cnt[s]
        }' | LC_ALL=C sort | awk -F'\t' '
        { printf "ShellScriptCount: %s = %s\n", $1, $2 }'
}

# ---- Action dependency pins read from the workflows ------------------------
emit_action_pins() {
    local wf srcfile file_pins
    local -a pin_lines=()
    for wf in .github/workflows/*.yml; do
        [[ -f "$wf" ]] || continue
        srcfile="$(basename "$wf")"
        # shellcheck disable=SC2016  # awk program: $-references are awk fields, not shell expansions
        file_pins="$(awk -v srcfile="$srcfile" '
            /^[ \t]*#/ { next }
            /^[ \t]*$/ { next }
            {
                line = $0
                if (sub(/^[ \t]*-[ \t]*uses:[ \t]*/, "", line) == 0) {
                    if (sub(/^[ \t]*uses:[ \t]*/, "", line) == 0) next
                }
                sub(/[ \t]+$/, "", line)
                if (line !~ /^[^@ \t]+@/) next
                ver = ""
                idx = index(line, "#")
                if (idx > 0) {
                    ver = substr(line, idx + 1)
                    line = substr(line, 1, idx - 1)
                    gsub(/^[ \t]+|[ \t]+$/, "", ver)
                    gsub(/[ \t]+$/, "", line)
                }
                if (ver == "") ver = "UNVERSIONED"
                printf "%s\t%s\t%s\n", line, ver, srcfile
            }' "$wf")"
        if [[ -n "$file_pins" ]]; then
            pin_lines+=("$file_pins")
        fi
    done
    if (( ${#pin_lines[@]} == 0 )); then
        fail "no action pins found under .github/workflows/*.yml"
    fi
    printf "ActionPinsSource: uses: lines from .github/workflows/*.yml (LC_ALL=C-sorted, deduplicated)\n"
    printf '%s\n' "${pin_lines[@]}" | LC_ALL=C sort -u | awk -F'\t' '
        /^[ \t]*$/ { next }
        { files[$1 "\t" $2] = files[$1 "\t" $2] ? files[$1 "\t" $2] ", " $3 : $3 }
        END {
            for (k in files) {
                split(k, a, "\t")
                printf "%s\t%s\t%s\n", a[1], a[2], files[k]
            }
        }' | LC_ALL=C sort | awk -F'\t' '
        { printf "Action: %s  # %s  (workflows: %s)\n", $1, $2, $3 }'
}

# ---- Assemble the SBOM ------------------------------------------------------
generate() {
    local gen_cmd="release-sbom.sh --version $version"
    if [[ -n "$output" ]]; then
        gen_cmd="$gen_cmd --output $output"
    fi

    printf 'SPDXVersion: SPDX-2.3\n'
    printf 'DataLicense: CC0-1.0\n'
    printf 'SPDXID: SPDXRef-DOCUMENT\n'
    printf 'DocumentName: %s-%s-sbom\n' "$name" "$version"
    printf 'DocumentNamespace: https://spdx.org/spdxdocs/%s-%s\n' "$name" "$version"
    printf 'Creator: Tool: release-sbom.sh\n'
    printf '# Created: omitted by design — this SBOM is deterministic (no\n'
    printf '# timestamps); the GenerationCommand below is the reproducibility\n'
    printf '# contract: rerunning it in the same worktree yields byte-identical\n'
    printf '# output.\n'
    printf 'GenerationCommand: %s\n' "$gen_cmd"
    printf 'DocumentDescribes: SPDXRef-Package-root\n'
    printf '\n'
    printf 'PackageName: %s\n' "$name"
    printf 'SPDXID: SPDXRef-Package-root\n'
    printf 'PackageVersion: %s\n' "$version"
    printf 'PackageDownloadLocation: NOASSERTION\n'
    printf 'PackageLicenseDeclared: %s\n' "$pkg_license"
    printf '# License source of truth for bundled glyphs: FontPatcher/ATTRIBUTION.md\n'
    printf '# (per-component table; supersedes any blanket claim in FONT_MANIFEST.md).\n'
    printf '# License files ship inside the release archives and are published as\n'
    printf '# top-level release assets (ATTRIBUTION.md, SECURITY.md).\n'

    emit_font_components

    printf '\n'
    emit_shell_inventory

    printf '\n'
    emit_action_pins

    printf '\n'
    printf '# Integrity mechanism: SHA-256 checksums.txt covers every published\n'
    printf '# artifact. Keyless signing is a documented follow-up decision for the\n'
    printf '# repository owner — see docs/MAINTENANCE.md (do not add unverifiable\n'
    printf '# signing).\n'
}

if [[ -n "$output" ]]; then
    tmp_output="${output}.sbomtmp"
    generate > "$tmp_output"
    mv "$tmp_output" "$output"
else
    generate
fi
