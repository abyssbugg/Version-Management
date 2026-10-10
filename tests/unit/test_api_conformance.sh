#!/usr/bin/env bash
# =============================================================================
# P3-4: docs/API.md conformance — the library API is enforced, not aspirational
# =============================================================================
# Conventions (docs/API.md "Conventions"; ENGINEERING_RULES §5):
#   - A lib/ function is PUBLIC when docs/API.md lists it in the table of
#     its owning module's section (`## <module>.sh - ...`). Only public
#     functions may be called outside their module.
#   - A `_`-prefixed function is PRIVATE to its module. The few that the
#     framework's own adopters share are listed, with their owner, in the
#     "Framework-internal helpers" table; no other private function may be
#     referenced outside its module.
#   - A function name is defined at top level by ONE lib module (guarded
#     fallback shims inside `if ! declare -f ...` blocks are indented and
#     exempt).
#   - Every lib/ module has an API.md section.
#
# Rules checked (static; definitions and uses inside here-documents — the
# generated plugin template, generated scripts — are ignored):
#   R1 every documented function exists in the module whose section lists it
#   R2 every public function referenced outside its module is documented in
#      its owner's section
#   R3 every private function referenced outside its module is allow-listed
#      with that owner
#   R4 no function is defined at top level by two lib modules
#   R5 every lib/*.sh module has a section
#   R6 every allow-listed helper exists in its stated owner
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SBX="$(mktemp -d "${TMPDIR:-/tmp}/vms-api-conformance.XXXXXX")"
trap 'rm -rf -- "$SBX"' EXIT
cd "$ROOT" || exit 1
API="docs/API.md"
failures=0
report() {  # <rule label> <violations (newline-separated, may be empty)>
    if [[ -z "$2" ]]; then
        printf 'PASS: %s\n' "$1"
    else
        printf 'FAIL: %s\n' "$1"
        printf '%s\n' "$2" | sed 's/^/    /'
        failures=$((failures + 1))
    fi
}

# Shared awk preamble: skip full-line comments and here-document bodies.
# shellcheck disable=SC2016 # awk program text, not shell expansions
HEREDOC_AWK='
function heredoc_open(line,   m, t) {
    if (line ~ /<<</) return ""
    if (match(line, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
        t = substr(line, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*/, "", t); gsub(/["\047]/, "", t)
        return t
    }
    return ""
}
FNR == 1 { term = "" }
term != "" { probe = $0; sub(/^\t+/, "", probe); if (probe == term) term = ""; next }
/^[ \t]*#/ { next }
'

# ── definitions in lib/ ─────────────────────────────────────────────────────
# kind: top (column 0), guarded (indented, outside any function: fallback
# shims in `if ! declare -f` blocks) or nested (defined inside another
# function's body, e.g. the lazy-load `nvm()`/`node()` wrappers — those are
# command shims, not library API, and own no name).
awk "$HEREDOC_AWK"'
FNR == 1 { infunc = 0 }
{
    t = heredoc_open($0)
    if (match($0, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/)) {
        def = substr($0, RSTART, RLENGTH)
        if (def ~ /^[ \t]/) kind = infunc ? "nested" : "guarded"; else kind = "top"
        gsub(/[ \t()]/, "", def)
        n = split(FILENAME, parts, "/")
        print def "\t" parts[n] "\t" kind
        # A top-level body opens here unless the definition closes on the
        # same line (one-liner) — the body ends at the next column-0 "}".
        if (kind == "top" && $0 !~ /\}[ \t;]*$/) infunc = 1
    } else if ($0 ~ /^\}/) {
        infunc = 0
    }
    if (t != "") term = t
}' lib/*.sh | LC_ALL=C sort -u > "$SBX/defs.tsv"

# owner: the top-level definer, else the (single) guarded definer
awk -F'\t' '
    $3 == "top" { if (!($1 in top)) top[$1] = $2 }
    $3 == "guarded" { if (!($1 in g)) g[$1] = $2 }
    END {
        for (k in top) print k "\t" top[k]
        for (k in g) if (!(k in top)) print k "\t" g[k]
    }' "$SBX/defs.tsv" | LC_ALL=C sort > "$SBX/owners.tsv"

# ── API.md inventory ────────────────────────────────────────────────────────
awk '
    /^## / {
        section = ""; internal = 0
        if (match($0, /^## [A-Za-z0-9_-]+\.sh /)) { section = substr($0, 4, RLENGTH - 4) }
        if ($0 ~ /^## Framework-internal helpers/) internal = 1
        next
    }
    section != "" && /^\| `[A-Za-z_][A-Za-z0-9_]*` \|/ {
        f = $0; sub(/^\| `/, "", f); sub(/`.*/, "", f); print "doc\t" f "\t" section
    }
    internal && /^\| `_[A-Za-z0-9_]*` \| `lib\/[A-Za-z0-9_-]+\.sh` \|/ {
        f = $0; sub(/^\| `/, "", f); sub(/`.*/, "", f)
        o = $0; sub(/^\| `[^`]*` \| `lib\//, "", o); sub(/`.*/, "", o)
        print "internal\t" f "\t" o
    }
    /^## [A-Za-z0-9_-]+\.sh / { }
' "$API" > "$SBX/api.tsv"
grep -oE '^## [A-Za-z0-9_-]+\.sh ' "$API" | sed -E 's/^## //; s/ $//' | LC_ALL=C sort -u > "$SBX/sections.txt"

# ── references outside the owning module ────────────────────────────────────
git ls-files '*.sh' | grep -vE '^(tests|FontPatcher|docs)/' > "$SBX/shipped.txt"
# shellcheck disable=SC2046 # one file per line, no spaces in tracked paths
awk -F'\t' "$HEREDOC_AWK"'
NR == FNR && FILENAME == ARGV[1] { owner[$1] = $2; next }
{
    t = heredoc_open($0)
    line = $0
    if (line ~ /(^|[^A-Za-z0-9_])unset -f /) { if (t != "") term = t; next }
    sub(/^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/, "", line)
    gsub(/[^A-Za-z0-9_]/, " ", line)
    n = split(FILENAME, parts, "/"); base = parts[n]
    islib = (FILENAME ~ /^lib\//)
    k = split(line, toks, " ")
    for (i = 1; i <= k; i++) {
        w = toks[i]
        if (!(w in owner)) continue
        if (islib && owner[w] == base) continue
        print w "\t" owner[w] "\t" FILENAME
    }
    if (t != "") term = t
}' "$SBX/owners.tsv" $(cat "$SBX/shipped.txt") | LC_ALL=C sort -u > "$SBX/uses.tsv"

# ── rules ───────────────────────────────────────────────────────────────────
r1=$(awk -F'\t' 'NR == FNR { def[$1 "\t" $2] = 1; next }
    $1 == "doc" && !(($2 "\t" $3) in def) { print $2 " is documented under " $3 " but not defined there" }' \
    "$SBX/defs.tsv" "$SBX/api.tsv")
report "R1 every documented function exists in its documented module" "$r1"

r2=$(awk -F'\t' 'NR == FNR { if ($1 == "doc") doc[$2 "\t" $3] = 1; next }
    $1 !~ /^_/ && !(($1 "\t" $2) in doc) { u[$1 " (" $2 ")"] = u[$1 " (" $2 ")"] " " $3 }
    END { for (k in u) print k " used by:" u[k] }' "$SBX/api.tsv" "$SBX/uses.tsv" | LC_ALL=C sort)
report "R2 every public function used outside its module is documented in its owner's section" "$r2"

r3=$(awk -F'\t' 'NR == FNR { if ($1 == "internal") ok[$2 "\t" $3] = 1; next }
    $1 ~ /^_/ && !(($1 "\t" $2) in ok) { u[$1 " (" $2 ")"] = u[$1 " (" $2 ")"] " " $3 }
    END { for (k in u) print k " used by:" u[k] }' "$SBX/api.tsv" "$SBX/uses.tsv" | LC_ALL=C sort)
report "R3 private functions are referenced outside their module only when allow-listed" "$r3"

r4=$(awk -F'\t' '$3 == "top" { c[$1]++; f[$1] = f[$1] " " $2 } END { for (k in c) if (c[k] > 1) print k ":" f[k] }' \
    "$SBX/defs.tsv" | LC_ALL=C sort)
report "R4 no function is defined at top level by two lib modules" "$r4"

r5=$(for f in lib/*.sh; do grep -qxF "$(basename "$f")" "$SBX/sections.txt" || echo "$(basename "$f") has no API.md section"; done)
report "R5 every lib module has an API.md section" "$r5"

r6=$(awk -F'\t' 'NR == FNR { def[$1 "\t" $2] = 1; next }
    $1 == "internal" && !(($2 "\t" $3) in def) { print $2 " is allow-listed for " $3 " but not defined there" }' \
    "$SBX/defs.tsv" "$SBX/api.tsv")
report "R6 every allow-listed internal helper exists in its stated owner" "$r6"

printf 'API conformance (P3-4): %s rule(s) violated (%s documented, %s allow-listed, %s cross-module references)\n' \
    "$failures" "$(grep -c '^doc' "$SBX/api.tsv")" "$(grep -c '^internal' "$SBX/api.tsv")" "$(wc -l < "$SBX/uses.tsv" | tr -d ' ')"
[[ "$failures" -eq 0 ]]
