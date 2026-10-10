#!/usr/bin/env bash
# =============================================================================
# Font writer adoption tests (AX-19, P3-1)
# =============================================================================
# lib/fonts.sh font_install_bundled / font_install_from_url / font_uninstall
# and tools/preview-nerd-fonts.sh --install used to cp/mv/rm in the user's
# font directory with no backup, no preview and (URL installs) no integrity
# check. Binding invariants:
#   - every write is transaction-backed: a replaced font is restored and a
#     newly installed one removed when a later step fails;
#   - identical fonts are not rewritten; TRANSACTION_DRY_RUN=1 writes nothing;
#   - font_install_from_url fails closed without an https URL, a plain
#     .ttf/.otf name and a matching SHA-256;
#   - font_uninstall is restorable from the transaction backup.
#
# Safety: the library and the tool run from a COPY of the repository under a
# mktemp -d sandbox (bundled-font fixtures live next to the copy); HOME,
# TMPDIR and XDG point into the sandbox; curl and fc-cache are PATH shims.
# =============================================================================

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB=$(mktemp -d "${TMPDIR:-/tmp}/vms-font-writers.XXXXXX")
SB=$(cd "$SB" && pwd -P)
trap 'chmod -R u+w "$SB" 2>/dev/null; rm -rf -- "$SB"' EXIT
mkdir -p "$SB/tmp"
export TMPDIR="$SB/tmp"
source "$ROOT_DIR/tests/helpers.sh"

# Repository copy with fixture fonts (never write into the real checkout).
COPY="$SB/repo"
mkdir -p "$COPY/tools"
cp -R "$ROOT_DIR/lib" "$COPY/lib"
cp "$ROOT_DIR/tools/preview-nerd-fonts.sh" "$COPY/tools/"
FONTS=("MesloLGS NF Regular.ttf" "MesloLGS NF Bold.ttf" "MesloLGS NF Italic.ttf" "MesloLGS NF Bold Italic.ttf")
for f in "${FONTS[@]}"; do printf 'fixture %s\n' "$f" > "$COPY/$f"; done

SHIM="$SB/shim"
mkdir -p "$SHIM"
cat > "$SHIM/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done
printf 'downloaded-font\n' > "$out"
SH
printf '#!/bin/sh\nexit 0\n' > "$SHIM/fc-cache"
chmod +x "$SHIM/curl" "$SHIM/fc-cache"
GOOD_SHA=$(printf 'downloaded-font\n' | { shasum -a 256 2>/dev/null || sha256sum; } | cut -d' ' -f1)

failures=0
chk() { assert_equals "$@" || failures=$((failures + 1)); }
chk_contains() { assert_contains "$@" || failures=$((failures + 1)); }

OUT="" RC=0
# _lib <case> [VAR=value ...] -- <shell code using the library>
_lib() {
    local tag="$1"
    shift
    local -a envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
    shift
    H="$SB/$tag/home"
    mkdir -p "$H"
    OUT=$(/usr/bin/env -i HOME="$H" TMPDIR="$TMPDIR" PATH="$SHIM:/usr/bin:/bin" CURL_LOG="$SB/curl.log" \
        "${envs[@]}" "$(command -v bash)" -c 'source "$1/lib/fonts.sh" >/dev/null 2>&1 || exit 97
'"$1" _ "$COPY" 2>&1)
    RC=$?
}
font_dir() {
    if [[ "$(uname -s)" == Darwin ]]; then printf '%s\n' "$1/Library/Fonts"; else printf '%s\n' "$1/.local/share/fonts"; fi
}
mtime_of() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1"; }

test_install_bundled() {
    local fd
    _lib dry TRANSACTION_DRY_RUN=1 -- 'font_install_bundled'
    fd=$(font_dir "$H")
    chk 0 "$RC" "dry-run install exits 0"
    chk_contains "[dry-run] would create: $fd/MesloLGS NF Regular.ttf" "$OUT" "dry-run names each font"
    chk "" "$(find "$H" -mindepth 1 -print -quit)" "dry-run writes nothing under HOME"

    _lib install -- 'font_install_bundled'
    fd=$(font_dir "$H")
    chk 0 "$RC" "install exits 0"
    chk "fixture MesloLGS NF Bold.ttf" "$(cat "$fd/MesloLGS NF Bold.ttf" 2>/dev/null)" "font installed with the bundled bytes"
    touch -t 202001010000 "$fd"/*.ttf
    local m
    m=$(mtime_of "$fd/MesloLGS NF Bold.ttf")
    _lib install -- 'font_install_bundled'
    chk 0 "$RC" "rerun exits 0"
    chk "$m" "$(mtime_of "$fd/MesloLGS NF Bold.ttf")" "identical font not rewritten"
}

test_install_rollback() {
    local fd
    H="$SB/rollback/home"
    fd=$(font_dir "$H")
    mkdir -p "$fd/MesloLGS NF Italic.ttf"           # 3rd publish must fail
    printf 'user regular\n' > "$fd/MesloLGS NF Regular.ttf"   # replaced, then restored
    _lib rollback -- 'font_install_bundled'
    chk 1 "$([[ "$RC" -ne 0 ]] && echo 1 || echo 0)" "install fails when a font cannot be published"
    chk "user regular" "$(cat "$fd/MesloLGS NF Regular.ttf")" "replaced font restored byte-identically"
    chk 0 "$([[ -e "$fd/MesloLGS NF Bold.ttf" ]] && echo 1 || echo 0)" "font installed before the failure removed"
    chk 1 "$([[ -d "$fd/MesloLGS NF Italic.ttf" ]] && echo 1 || echo 0)" "blocking directory untouched"
    chk_contains "rolled back" "$OUT" "rollback reported"
}

test_install_from_url() {
    : > "$SB/curl.log"
    _lib url -- 'font_install_from_url https://example.invalid/f.ttf "Font.ttf"'
    chk 1 "$([[ "$RC" -ne 0 ]] && echo 1 || echo 0)" "missing checksum refused"
    _lib url -- 'font_install_from_url http://example.invalid/f.ttf "Font.ttf" '"$GOOD_SHA"
    chk 1 "$([[ "$RC" -ne 0 ]] && echo 1 || echo 0)" "non-https URL refused"
    _lib url -- 'font_install_from_url https://example.invalid/f.ttf "../evil.ttf" '"$GOOD_SHA"
    chk 1 "$([[ "$RC" -ne 0 ]] && echo 1 || echo 0)" "path-like font name refused"
    chk "" "$(cat "$SB/curl.log")" "nothing downloaded for refused requests"
    _lib url TRANSACTION_DRY_RUN=1 -- 'font_install_from_url https://example.invalid/f.ttf "Font.ttf" '"$GOOD_SHA"
    chk 0 "$RC" "dry-run URL install exits 0"
    chk "" "$(cat "$SB/curl.log")" "dry-run performs no download"
    _lib url -- 'font_install_from_url https://example.invalid/f.ttf "Font.ttf" '"$(printf '%064d' 0)"
    chk 1 "$([[ "$RC" -ne 0 ]] && echo 1 || echo 0)" "checksum mismatch refused"
    chk 0 "$([[ -e "$(font_dir "$H")/Font.ttf" ]] && echo 1 || echo 0)" "mismatched download not installed"
    _lib url -- 'font_install_from_url https://example.invalid/f.ttf "Font.ttf" '"$GOOD_SHA"
    chk 0 "$RC" "verified URL install exits 0"
    chk "downloaded-font" "$(cat "$(font_dir "$H")/Font.ttf" 2>/dev/null)" "verified font installed"
    chk 0 "$(find "$TMPDIR" -name 'vms-font.*' | wc -l | tr -d ' ')" "no download temp file left"
}

test_uninstall() {
    local fd
    _lib uninstall -- 'font_install_bundled'
    fd=$(font_dir "$H")
    _lib uninstall TRANSACTION_DRY_RUN=1 -- 'font_uninstall'
    chk 0 "$RC" "dry-run uninstall exits 0"
    chk 1 "$([[ -f "$fd/MesloLGS NF Bold.ttf" ]] && echo 1 || echo 0)" "dry-run uninstall removes nothing"
    _lib uninstall -- 'font_uninstall'
    chk 0 "$RC" "uninstall exits 0"
    chk 0 "$([[ -e "$fd/MesloLGS NF Bold.ttf" ]] && echo 1 || echo 0)" "font removed"
    local hits
    hits=$(grep -rl 'fixture MesloLGS NF Bold.ttf' "$H" 2>/dev/null | grep -vc "$fd")
    chk 1 "$([[ "$hits" -ge 1 ]] && echo 1 || echo 0)" "removed font kept in the transaction backup"
    _lib uninstall -- 'bash -c "font_uninstall"'
    chk_contains "lib/mutation.sh is not loaded" "$OUT" "inherited function fails closed with a clear error"
}

test_preview_tool_install() {
    local h="$SB/tool/home" fd out rc
    mkdir -p "$h"
    fd=$(font_dir "$h")
    out=$(/usr/bin/env -i HOME="$h" TMPDIR="$TMPDIR" PATH="$SHIM:/usr/bin:/bin" "$(command -v bash)" \
        "$COPY/tools/preview-nerd-fonts.sh" --install --dry-run </dev/null 2>&1)
    rc=$?
    chk 0 "$rc" "preview --install --dry-run exits 0"
    chk "" "$(find "$h" -mindepth 1 -print -quit)" "preview --install --dry-run writes nothing"
    printf 'user bold\n' > "$SB/user-bold.ref"
    mkdir -p "$fd" && cp "$SB/user-bold.ref" "$fd/MesloLGS NF Bold.ttf"
    out=$(/usr/bin/env -i HOME="$h" TMPDIR="$TMPDIR" PATH="$SHIM:/usr/bin:/bin" "$(command -v bash)" \
        "$COPY/tools/preview-nerd-fonts.sh" --install </dev/null 2>&1)
    rc=$?
    chk 0 "$rc" "preview --install exits 0"
    chk "fixture MesloLGS NF Bold.ttf" "$(cat "$fd/MesloLGS NF Bold.ttf")" "preview --install publishes the bundled font"
    local hits
    hits=$(grep -rl 'user bold' "$h" 2>/dev/null | wc -l | tr -d ' ')
    chk 1 "$([[ "$hits" -ge 1 ]] && echo 1 || echo 0)" "the user's previous font is kept in the transaction backup"
}

test_install_bundled
test_install_rollback
test_install_from_url
test_uninstall
test_preview_tool_install

if [[ "$failures" -gt 0 ]]; then
    echo "test_font_writers.sh: $failures assertion(s) failed"
    exit 1
fi
echo "test_font_writers.sh: all assertions passed"
exit 0
