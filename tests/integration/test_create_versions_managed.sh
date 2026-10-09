#!/usr/bin/env bash
# =============================================================================
# AX-6b (P3-1, P2-4): `version-manager.sh create-versions` through the REAL
# CLI, inside a private sandbox (HOME / XDG / TMPDIR / project dirs created
# with mktemp -d BEFORE any project code runs).
#
# Every invocation runs under `env -i` with an explicit PATH made of
# symlinked base tools only — no nvm/pyenv/rbenv/phpenv/node/python/jq is
# visible, so the defaults are deterministic (20.0.0 / 3.12.0 / 3.0.0).
# Network/installer commands (git curl wget brew sudo apt-get yum) are
# tripwire stubs that record any call; ping is an always-offline stub.
#
# Cases:
#   a) no-arg invocation exits 0 and writes the four pin files
#   b) explicit versions -> exact bytes; one-arg form uses the defaults
#   c) rerun -> byte-identical, mtimes and inodes unchanged
#   d) existing pins replaced (modes kept); injected later failure (jq stub
#      printing invalid JSON) -> every pin, the symlinked pin's target and
#      package.json restored byte-identical, non-zero exit
#   e) jq stub printing nothing -> package.json byte-identical, non-zero
#      exit, no package.json.tmp or temp file left in the project dir
#   f) --dry-run (anywhere after the command) and TRANSACTION_DRY_RUN=1 ->
#      plan printed, project dir / HOME / TMPDIR manifests unchanged
#   g) install-* with no version no longer die on "unbound variable": the
#      callee default is announced and the flow stops offline, no install
#   h) unsupported option / whitespace version -> refused, nothing written
#   i) symlinked pin stays a symlink; real-jq package.json path (if jq exists)
# =============================================================================
set -euo pipefail
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/vms-create-versions-test.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home" TMPDIR="$SANDBOX/tmp"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME" "$TMPDIR"

BASH_BIN="${BASH:-$(command -v bash)}"
VM="$ROOT/version-manager.sh"
TRIPWIRE="$SANDBOX/tripwire.log"
: > "$TRIPWIRE"

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { printf 'FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
check() { if "$@"; then ok; else bad "$*"; fi; }
check_not() { if "$@"; then bad "NOT $*"; else ok; fi; }

sha_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}
same_bytes() { [[ -f "$1" && -f "$2" && "$(sha_of "$1")" == "$(sha_of "$2")" ]]; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
inode_of() { ls -di "$1" | awk '{print $1}'; }
has_text() { grep -qF -- "$2" "$1"; }
has_line() { grep -qxF -- "$2" "$1"; }
is_absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
is_link_to() { [[ -L "$1" && "$(readlink "$1")" == "$2" ]]; }
# Sorted listing of a directory's entries (names only, hidden included).
listing() { (cd "$1" && find . -mindepth 1 -print | LC_ALL=C sort); }
listing_is() { [[ "$(listing "$1")" == "$2" ]]; }
is_empty_dir() { [[ -d "$1" && -z "$(find "$1" -mindepth 1 -print)" ]]; }
# Sorted find + type + mode + mtime + sha256 manifest (root dir included, so
# a created-then-deleted entry still shows up through the dir mtime).
manifest() (
    cd "$1" || exit 1
    find . -print | LC_ALL=C sort | while IFS= read -r p; do
        if [[ -L "$p" ]]; then
            printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
        elif [[ -d "$p" ]]; then
            printf 'D %s %s %s\n' "$p" "$(mode_of "$p")" "$(mtime_of "$p")"
        else
            printf 'F %s %s %s %s\n' "$p" "$(mode_of "$p")" "$(mtime_of "$p")" "$(sha_of "$p")"
        fi
    done
)
# Age every entry so any later write is visible as an mtime change even
# within the same second.
age_tree() { find "$1" -exec touch -t 200001010000 {} +; }

# --- sandbox PATH -------------------------------------------------------------
make_bin() {
    local dir="$1" tool path stub
    mkdir -p "$dir"
    for tool in awk basename cat chmod cmp cp cut date dirname du env find grep head \
        id kill ln ls mkdir mktemp mv od readlink rm rmdir sed sha256sum shasum sleep \
        sort stat tail touch tr uname wc xargs tput ps; do
        if path=$(command -v "$tool" 2>/dev/null) && [[ "$path" == /* ]]; then
            ln -s "$path" "$dir/$tool"
        fi
    done
    ln -s "$BASH_BIN" "$dir/bash"
    for stub in git curl wget brew sudo apt-get yum; do
        printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit 1\n' "$stub" "$TRIPWIRE" > "$dir/$stub"
        chmod 755 "$dir/$stub"
    done
    printf '#!/bin/sh\nexit 1\n' > "$dir/ping"   # always offline
    chmod 755 "$dir/ping"
}
BIN="$SANDBOX/bin"
make_bin "$BIN"
BIN_BADJQ="$SANDBOX/bin-badjq"      # exits 0, prints invalid JSON
make_bin "$BIN_BADJQ"
printf '#!/bin/sh\nprintf "{\\"broken\\": \\n"\nexit 0\n' > "$BIN_BADJQ/jq"
chmod 755 "$BIN_BADJQ/jq"
BIN_EMPTYJQ="$SANDBOX/bin-emptyjq"  # exits 0, prints nothing
make_bin "$BIN_EMPTYJQ"
printf '#!/bin/sh\nexit 0\n' > "$BIN_EMPTYJQ/jq"
chmod 755 "$BIN_EMPTYJQ/jq"
REAL_JQ="$(command -v jq 2>/dev/null || true)"
BIN_REALJQ=""
if [[ "$REAL_JQ" == /* ]]; then
    BIN_REALJQ="$SANDBOX/bin-realjq"
    make_bin "$BIN_REALJQ"
    ln -s "$REAL_JQ" "$BIN_REALJQ/jq"
fi

# run_cli <home> <tmpdir> <bindir> <args...> — runs from the CURRENT dir;
# stdout/stderr land in $OUT/$ERR, the exit status in $RC.
OUT="$SANDBOX/out" ERR="$SANDBOX/err" RC=0
EXTRA_ENV=()
run_cli() {
    local home="$1" tmp="$2" bin="$3"
    shift 3
    RC=0
    env -i HOME="$home" TMPDIR="$tmp" PATH="$bin" LC_ALL=C SHELL=/bin/bash \
        XDG_CONFIG_HOME="$home/.config" XDG_CACHE_HOME="$home/.cache" \
        XDG_DATA_HOME="$home/.local/share" XDG_STATE_HOME="$home/.local/state" \
        ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
        "$BASH_BIN" "$VM" "$@" > "$OUT" 2> "$ERR" || RC=$?
}
expect_file() { # <file> <printf-format> [args...]: exact bytes
    local file="$1" fmt="$2"
    shift 2
    # shellcheck disable=SC2059 # the format is the expected-content template
    printf "$fmt" "$@" > "$SANDBOX/expected"
    same_bytes "$file" "$SANDBOX/expected"
}
new_project() { local d="$SANDBOX/$1"; mkdir -p "$d"; printf '%s\n' "$d"; }
PINS_LISTING=$'./.nvmrc\n./.python-version\n./.ruby-version\n./.tool-versions'

# --- a) no-arg invocation ------------------------------------------------------
echo "--- a) create-versions with no arguments ---"
PA=$(new_project proj-a)
cd "$PA"
run_cli "$HOME" "$TMPDIR" "$BIN" create-versions
check test "$RC" -eq 0
check_not has_text "$ERR" "unbound variable"
check expect_file .nvmrc '20.0.0\n'
check expect_file .python-version '3.12.0\n'
check expect_file .ruby-version '3.0.0\n'
check expect_file .tool-versions 'nodejs 20.0.0\npython 3.12.0\nruby 3.0.0\n'
check has_text "$ERR" "Created .nvmrc with Node.js 20.0.0"
check has_text "$ERR" "Created .tool-versions for asdf compatibility"
for f in .nvmrc .python-version .ruby-version .tool-versions; do
    check test "$(mode_of "$f")" = 644   # umask 022 -> what `>` produced
done
check listing_is "$PA" "$PINS_LISTING"

# --- b) explicit versions ------------------------------------------------------
echo "--- b) explicit versions (exact content) ---"
PB=$(new_project proj-b)
cd "$PB"
run_cli "$HOME" "$TMPDIR" "$BIN" create-versions v22.1.0 3.11.4 3.3.0
check test "$RC" -eq 0
check expect_file .nvmrc '22.1.0\n'
check expect_file .python-version '3.11.4\n'
check expect_file .ruby-version '3.3.0\n'
check expect_file .tool-versions 'nodejs 22.1.0\npython 3.11.4\nruby 3.3.0\n'
check has_text "$ERR" "Created .nvmrc with Node.js v22.1.0"
check has_text "$ERR" "Created .python-version with Python 3.11.4"
check has_text "$ERR" "Created .ruby-version with Ruby 3.3.0"
check listing_is "$PB" "$PINS_LISTING"
PB1=$(new_project proj-b1)
cd "$PB1"
run_cli "$HOME" "$TMPDIR" "$BIN" create-versions 18.20.0
check test "$RC" -eq 0
check_not has_text "$ERR" "unbound variable"
check expect_file .nvmrc '18.20.0\n'
check expect_file .python-version '3.12.0\n'
check expect_file .tool-versions 'nodejs 18.20.0\npython 3.12.0\nruby 3.0.0\n'

# --- c) rerun is byte-identical and does not touch mtimes -----------------------
echo "--- c) rerun: no mtime churn ---"
cd "$PB"
age_tree "$PB"
declare -A before_mtime=() before_inode=() before_sha=()
for f in .nvmrc .python-version .ruby-version .tool-versions; do
    before_mtime[$f]=$(mtime_of "$f")
    before_inode[$f]=$(inode_of "$f")
    before_sha[$f]=$(sha_of "$f")
done
run_cli "$HOME" "$TMPDIR" "$BIN" create-versions v22.1.0 3.11.4 3.3.0
check test "$RC" -eq 0
for f in .nvmrc .python-version .ruby-version .tool-versions; do
    check test "$(sha_of "$f")" = "${before_sha[$f]}"
    check test "$(mtime_of "$f")" = "${before_mtime[$f]}"
    check test "$(inode_of "$f")" = "${before_inode[$f]}"
done
check listing_is "$PB" "$PINS_LISTING"

# --- d) replace existing pins; injected later failure rolls everything back ----
echo "--- d) replace + rollback on invalid jq output ---"
PD=$(new_project proj-d)
cd "$PD"
printf 'lts/iron\n' > .nvmrc; chmod 600 .nvmrc
printf '3.9.1\n' > .python-version; chmod 640 .python-version
printf '{"name":"demo","version":"1.0.0"}\n' > package.json
cp -p package.json "$SANDBOX/pkg-d.orig"
# d1) no jq on PATH: pins replaced as before, modes kept, package.json skipped.
run_cli "$HOME" "$TMPDIR" "$BIN" create-versions 20.1.0 3.12.1 3.3.1
check test "$RC" -eq 0
check expect_file .nvmrc '20.1.0\n'
check expect_file .python-version '3.12.1\n'
check test "$(mode_of .nvmrc)" = 600
check test "$(mode_of .python-version)" = 640
check same_bytes package.json "$SANDBOX/pkg-d.orig"
# d2) reset to user state (+ a symlinked .ruby-version), then inject jq garbage.
rm -f .nvmrc .python-version .ruby-version .tool-versions
printf 'lts/iron\n' > .nvmrc; chmod 600 .nvmrc
printf '3.9.1\n' > .python-version; chmod 640 .python-version
mkdir -p "$SANDBOX/shared-d"
printf '2.7.0\n' > "$SANDBOX/shared-d/ruby-version"
ln -s "$SANDBOX/shared-d/ruby-version" .ruby-version
mkdir -p "$SANDBOX/orig-d"
cp -p .nvmrc .python-version package.json "$SANDBOX/orig-d/"
cp -p "$SANDBOX/shared-d/ruby-version" "$SANDBOX/orig-d/ruby-version"
listing_d=$(listing "$PD")
run_cli "$HOME" "$TMPDIR" "$BIN_BADJQ" create-versions 20.1.0 3.12.1 3.3.1
check test "$RC" -ne 0
check same_bytes .nvmrc "$SANDBOX/orig-d/.nvmrc"
check same_bytes .python-version "$SANDBOX/orig-d/.python-version"
check same_bytes package.json "$SANDBOX/orig-d/package.json"
check same_bytes "$SANDBOX/shared-d/ruby-version" "$SANDBOX/orig-d/ruby-version"
check is_link_to .ruby-version "$SANDBOX/shared-d/ruby-version"
check test "$(mode_of .nvmrc)" = 600
check test "$(mode_of .python-version)" = 640
check is_absent .tool-versions
check listing_is "$PD" "$listing_d"
check has_text "$ERR" "rolled back"
check_not has_text "$ERR" "Created .nvmrc"
check is_empty_dir "$TMPDIR"

# --- e) jq printing nothing ----------------------------------------------------
echo "--- e) empty jq output ---"
PE=$(new_project proj-e)
cd "$PE"
printf '{"name":"demo-e"}\n' > package.json
cp -p package.json "$SANDBOX/pkg-e.orig"
run_cli "$HOME" "$TMPDIR" "$BIN_EMPTYJQ" create-versions 20.1.0 3.12.1 3.3.1
check test "$RC" -ne 0
check same_bytes package.json "$SANDBOX/pkg-e.orig"
check listing_is "$PE" "./package.json"   # no pins, no package.json.tmp, no temp
check has_text "$ERR" "empty output"
check_not has_text "$ERR" "Updated package.json engines"
check is_empty_dir "$TMPDIR"

# --- f) dry-run is zero-write --------------------------------------------------
echo "--- f) --dry-run: zero writes, plan printed ---"
HF="$SANDBOX/home-f" TF="$SANDBOX/tmp-f"
mkdir -p "$HF" "$TF"
PF=$(new_project proj-f)
cd "$PF"
printf '18\n' > .nvmrc
printf '3.12.0\n' > .python-version
printf '{"name":"demo-f"}\n' > package.json
age_tree "$PF"; age_tree "$HF"
proj_before=$(manifest "$PF"); home_before=$(manifest "$HF")
run_cli "$HF" "$TF" "$BIN" create-versions 21.0.0 --dry-run 3.12.0
check test "$RC" -eq 0
check has_line "$OUT" "[dry-run] replace: .nvmrc"
check has_line "$OUT" "[dry-run] unchanged: .python-version"
check has_line "$OUT" "[dry-run] create: .ruby-version"
check has_line "$OUT" "[dry-run] create: .tool-versions"
check has_line "$OUT" "[dry-run] skip: package.json (jq not available; engines not updated)"
check_not has_text "$ERR" "Created .nvmrc"
check test "$(manifest "$PF")" = "$proj_before"
check test "$(manifest "$HF")" = "$home_before"
check is_empty_dir "$HF"
# The plan is staged in TMPDIR (allowed); nothing may be left behind there.
check is_empty_dir "$TF"
# Environment-selected preview takes the same zero-write route.
EXTRA_ENV=(TRANSACTION_DRY_RUN=1)
run_cli "$HF" "$TF" "$BIN" create-versions
EXTRA_ENV=()
check test "$RC" -eq 0
check has_line "$OUT" "[dry-run] replace: .nvmrc"
check test "$(manifest "$PF")" = "$proj_before"
check test "$(manifest "$HF")" = "$home_before"
check is_empty_dir "$TF"
if [[ -n "$BIN_REALJQ" ]]; then
    run_cli "$HF" "$TF" "$BIN_REALJQ" create-versions 21.0.0 3.12.0 --dry-run
    check test "$RC" -eq 0
    check has_line "$OUT" "[dry-run] replace: package.json"
    check test "$(manifest "$PF")" = "$proj_before"
    check test "$(manifest "$HF")" = "$home_before"
    check is_empty_dir "$TF"
else
    echo "SKIP: real jq not installed — dry-run package.json plan line not exercised"
fi

# --- g) install-* without a version argument ------------------------------------
echo "--- g) install-* with omitted version ---"
HG="$SANDBOX/home-g"
mkdir -p "$HG"
PG=$(new_project proj-g)
cd "$PG"
g_case() { # <command> <announcement>
    run_cli "$HG" "$TMPDIR" "$BIN" "$1"
    check test "$RC" -eq 1
    check_not has_text "$ERR" "unbound variable"
    check has_text "$ERR" "$2"
    check has_text "$ERR" "No internet connection available"
}
g_case install-node "Installing Node.js version: lts"
g_case install-python "Installing Python version: 3.12.0"
g_case install-ruby "Installing Ruby version: 3.0.0"
g_case install-php "Installing PHP version: 8.3"
g_case install-nvm "Installing NVM..."
for d in .nvm .pyenv .rbenv .phpenv; do
    check is_absent "$HG/$d"
done
check test ! -s "$TRIPWIRE"   # no git/curl/wget/brew/sudo/apt-get/yum call
check is_empty_dir "$PG"

# --- h) refusals before any write ---------------------------------------------
echo "--- h) unsupported option / invalid version ---"
PH=$(new_project proj-h)
cd "$PH"
run_cli "$HOME" "$TMPDIR" "$BIN" create-versions --force
check test "$RC" -eq 2
check has_text "$ERR" "Unsupported create-versions option: --force"
check is_empty_dir "$PH"
run_cli "$HOME" "$TMPDIR" "$BIN" create-versions "20.0.0 extra"
check test "$RC" -eq 1
check has_text "$ERR" "refusing invalid Node.js version"
check is_empty_dir "$PH"

# --- i) symlinked pin kept; real-jq package.json path ---------------------------
echo "--- i) symlink preserved; package.json via real jq ---"
PI=$(new_project proj-i)
cd "$PI"
mkdir -p "$SANDBOX/shared-i"
printf '16\n' > "$SANDBOX/shared-i/nvmrc"
chmod 640 "$SANDBOX/shared-i/nvmrc"
ln -s "$SANDBOX/shared-i/nvmrc" .nvmrc
run_cli "$HOME" "$TMPDIR" "$BIN" create-versions 20.1.0 3.12.1 3.3.1
check test "$RC" -eq 0
check is_link_to .nvmrc "$SANDBOX/shared-i/nvmrc"
check expect_file "$SANDBOX/shared-i/nvmrc" '20.1.0\n'
check test "$(mode_of "$SANDBOX/shared-i/nvmrc")" = 640
if [[ -n "$BIN_REALJQ" ]]; then
    PJ=$(new_project proj-j)
    cd "$PJ"
    printf '{"name":"demo-j","engines":{"node":">=14"}}\n' > package.json
    chmod 600 package.json
    "$REAL_JQ" --arg engines '>=20' '.engines.node = $engines' package.json > "$SANDBOX/pkg-j.expected"
    run_cli "$HOME" "$TMPDIR" "$BIN_REALJQ" create-versions 20.1.0 3.12.1 3.3.1
    check test "$RC" -eq 0
    check same_bytes package.json "$SANDBOX/pkg-j.expected"
    check test "$(mode_of package.json)" = 600
    check has_text "$ERR" "Updated package.json engines"
    check listing_is "$PJ" $'./.nvmrc\n./.python-version\n./.ruby-version\n./.tool-versions\n./package.json'
    age_tree "$PJ"
    pkg_mtime=$(mtime_of package.json)
    run_cli "$HOME" "$TMPDIR" "$BIN_REALJQ" create-versions 20.1.0 3.12.1 3.3.1
    check test "$RC" -eq 0
    check test "$(mtime_of package.json)" = "$pkg_mtime"
else
    echo "SKIP: real jq not installed — package.json happy path not exercised"
fi
check is_empty_dir "$TMPDIR"

cd "$ROOT"
printf 'create-versions managed: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
