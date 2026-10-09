#!/usr/bin/env bash
# =============================================================================
# Installer Safety Tests (AX-6d / AX-6e / AX-6f, P3-1)
# =============================================================================
# Binding invariants:
#   AX-6d  An installer that moves the user's existing version-manager tree
#          aside RESTORES it byte-identically when the clone/install fails,
#          and never moves it at all on the Homebrew path.
#   AX-6e  Privileged (sudo) package installs require explicit consent:
#          non-interactive without VMS_CONFIRM=1 -> nothing runs under sudo,
#          the exact command is printed, the user-space install continues;
#          VMS_CONFIRM=1 -> the exact argv runs; TRANSACTION_DRY_RUN=1 -> plan.
#   AX-6f  The Composer installer fails CLOSED on an empty/malformed/mismatched
#          signature, hashes via argv, verifies the produced binary before it
#          lands in the bin dir, never overwrites, gates sudo on consent, and
#          always removes its temp dir.
#
# Everything runs in a mktemp -d sandbox (HOME/TMPDIR/XDG) created BEFORE any
# project file is sourced. git/brew/apt-get/yum/curl/php/ping/uname are PATH
# shims and sudo is tests/shims/sudo (records argv, never executes). The
# shims refuse any destination outside the sandbox; nothing reaches the
# network or a real system path.
# =============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_SBX=$(mktemp -d "${TMPDIR:-/tmp}/tmp_rovodev_installsafety.XXXXXX")
trap 'chmod -R u+w "$_SBX" 2>/dev/null; rm -rf -- "$_SBX"' EXIT
export HOME="$_SBX/home" TMPDIR="$_SBX/tmp"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME" "$TMPDIR"
unset LOG_FILE TXN_AUDIT_LOG TRANSACTION_DRY_RUN VMS_CONFIRM BACKUP_DIR
unset NVM_DIR PYENV_ROOT GOENV_ROOT JENV_ROOT PHPENV_ROOT _VMS_COMPOSER_BIN_DIR
source "$ROOT_DIR/tests/helpers.sh"

set +e

_T_CASE_FAILS=0
chk() { assert_equals "$@" || _T_CASE_FAILS=$((_T_CASE_FAILS + 1)); }
chk_contains() { assert_contains "$@" || _T_CASE_FAILS=$((_T_CASE_FAILS + 1)); }
chk_not_contains() {
    local needle="$1" hay="$2" msg="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        chk "absent: $needle" "present" "$msg"
    else
        chk "absent" "absent" "$msg"
    fi
}

# ── Shims ────────────────────────────────────────────────────────────────────
SHIM="$_SBX/bin"           # always on PATH: git ping uname
BREWBIN="$_SBX/brewbin"    # opt-in: brew
APTBIN="$_SBX/aptbin"      # opt-in: apt-get
YUMBIN="$_SBX/yumbin"      # opt-in: yum
PHPBIN="$_SBX/phpbin"      # opt-in: php + curl (composer cases)
LOGS="$_SBX/logs"
mkdir -p "$SHIM" "$BREWBIN" "$APTBIN" "$YUMBIN" "$PHPBIN" "$LOGS"

cat > "$SHIM/git" <<'SH'
#!/usr/bin/env bash
# git shim: GIT_SHIM_MODE=fail (every clone fails, leaving a partial dir),
# fail-second (first clone ok, later ones fail), ok (fake tree). Never network.
printf '%s\n' "$*" >> "${GIT_SHIM_LOG:-/dev/null}"
sub=""
for a in "$@"; do case "$a" in clone|checkout) sub="$a"; break ;; esac; done
[ "$sub" = clone ] || { [ "$sub" = checkout ] && [ "${GIT_SHIM_MODE:-fail}" != ok ] && exit 1; exit 0; }
dest="${!#}"
case "$dest" in
    "$SHIM_SANDBOX"/*) ;;
    *) echo "git shim: refusing destination outside sandbox: $dest" >&2; exit 99 ;;
esac
if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    echo "fatal: destination path '$dest' already exists and is not an empty directory." >&2
    exit 128
fi
n=$(( $(cat "$GIT_SHIM_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$GIT_SHIM_COUNT"
fail=0
case "${GIT_SHIM_MODE:-fail}" in
    fail) fail=1 ;;
    fail-second) [ "$n" -ge 2 ] && fail=1 ;;
esac
if [ "$fail" = 1 ]; then
    mkdir -p "$dest" && echo partial > "$dest/PARTIAL"
    echo "fatal: unable to access remote (git shim)" >&2
    exit 128
fi
mkdir -p "$dest/bin" "$dest/.git" && echo fake > "$dest/bin/tool" && echo cloned > "$dest/CLONED"
SH

printf '#!/bin/sh\nexit 0\n' > "$SHIM/ping"
# mktemp shim: macOS mktemp ignores $TMPDIR for a bare `mktemp -d`; pin every
# template-less call into the sandbox TMPDIR so code under test (including
# the pre-fix sources during RED runs) can never write to the real temp dir.
cat > "$SHIM/mktemp" <<'SH'
#!/usr/bin/env bash
real=/usr/bin/mktemp
[ -x "$real" ] || real=/bin/mktemp
have_template=0
for a in "$@"; do case "$a" in -*) ;; *) have_template=1 ;; esac; done
if [ "$have_template" = 0 ]; then
    exec "$real" "$@" "${TMPDIR:?}/tmp.XXXXXXXXXX"
fi
exec "$real" "$@"
SH
cat > "$SHIM/uname" <<'SH'
#!/bin/sh
case "${1:-}" in
    -m) echo x86_64 ;;
    -r) echo 0.0-shim ;;
    *) echo "${VMS_TEST_UNAME:-Linux}" ;;
esac
SH

cat > "$BREWBIN/brew" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${BREW_SHIM_LOG:-/dev/null}"
exit "${BREW_SHIM_RC:-0}"
SH
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${APT_SHIM_LOG:-/dev/null}"\nexit 0\n' > "$APTBIN/apt-get"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${APT_SHIM_LOG:-/dev/null}"\nexit 0\n' > "$YUMBIN/yum"

cat > "$PHPBIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_SHIM_LOG:-/dev/null}"
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
case "$url" in
    *installer.sig)
        case "${CURL_SIG_MODE:-good}" in
            empty) exit 0 ;;
            bad) printf '%096d\n' 0 | tr 0 f ;;
            good) cat "$COMPOSER_GOOD_SIG_FILE" ;;
        esac ;;
    *getcomposer.org/installer)
        case "$out" in "$SHIM_SANDBOX"/*) ;; *) exit 23 ;; esac
        cp "$COMPOSER_STUB_INSTALLER" "$out" ;;
    *) exit 22 ;;
esac
SH

cat > "$PHPBIN/php" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PHP_SHIM_LOG:-/dev/null}"
_sha384() {
    if command -v sha384sum >/dev/null 2>&1; then sha384sum "$1" | awk '{print $1}'
    else shasum -a 384 "$1" | awk '{print $1}'; fi
}
if [ "${1:-}" = "-r" ]; then
    code="${2:-}"
    [ "${PHP_HASH_BROKEN:-0}" = 1 ] && exit 0   # hash unavailable: prints nothing
    case "$code" in
        *'$argv[1]'*) f="${3:-}" ;;
        *hash_file*) f=$(printf '%s' "$code" | sed -n "s/.*hash_file('sha384', '\([^']*\)').*/\1/p") ;;
        *) exit 1 ;;
    esac
    [ -f "$f" ] || exit 0
    _sha384 "$f" | tr -d '\n'
    exit 0
fi
script="${1:-}"; shift
if [ "${1:-}" = "--version" ]; then
    grep -q FAKE-COMPOSER "$script" 2>/dev/null && { echo "Composer version 2.7.0 (shim)"; exit 0; }
    exit 1
fi
dir="" name="composer"
for a in "$@"; do
    case "$a" in
        --install-dir=*) dir="${a#--install-dir=}" ;;
        --filename=*) name="${a#--filename=}" ;;
    esac
done
echo "RAN-INSTALLER $script" >> "${PHP_SHIM_LOG:-/dev/null}"
case "$dir" in
    "$SHIM_SANDBOX"/*) ;;
    *) echo "php shim: refusing install-dir outside sandbox: $dir" >&2; exit 1 ;;
esac
case "${PHP_INSTALLER_MODE:-good}" in
    fail) exit 1 ;;
    broken-binary) printf 'not composer\n' > "$dir/$name"; exit 0 ;;
esac
printf '#!/usr/bin/env php\nFAKE-COMPOSER\n' > "$dir/$name"
SH
chmod +x "$SHIM"/* "$BREWBIN"/* "$APTBIN"/* "$YUMBIN"/* "$PHPBIN"/*

STUB_INSTALLER="$_SBX/composer-setup.stub.php"
printf '<?php // composer installer stub (test fixture)\n' > "$STUB_INSTALLER"
GOOD_SIG_FILE="$_SBX/good.sig"
if command -v sha384sum >/dev/null 2>&1; then
    sha384sum "$STUB_INSTALLER" | awk '{print toupper($1)}' > "$GOOD_SIG_FILE"
else
    shasum -a 384 "$STUB_INSTALLER" | awk '{print toupper($1)}' > "$GOOD_SIG_FILE"
fi

BASE_PATH="$SHIM:$ROOT_DIR/tests/shims:/usr/bin:/bin:/usr/sbin:/sbin"
VM_BACKUP_DIR="$HOME/.local/backup/version-manager"

# Run a child bash under a clean, fully sandboxed environment (env -i: no
# inherited exported functions or host variables). Usage:
#   _child [VAR=value ...] -- <bash -c script> [args...]
_child() {
    local -a envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        envs+=("$1")
        shift
    done
    shift
    /usr/bin/env -i HOME="$HOME" TMPDIR="$TMPDIR" SHELL=/bin/bash \
        XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
        XDG_DATA_HOME="$XDG_DATA_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
        PATH="$BASE_PATH" SHIM_SANDBOX="$_SBX" VMS_PROC_VERSION="$_SBX/no-proc-version" \
        GIT_SHIM_LOG="$LOGS/git" GIT_SHIM_COUNT="$LOGS/git.count" SUDO_SHIM_LOG="$LOGS/sudo" \
        BREW_SHIM_LOG="$LOGS/brew" APT_SHIM_LOG="$LOGS/apt" CURL_SHIM_LOG="$LOGS/curl" \
        PHP_SHIM_LOG="$LOGS/php" TXN_AUDIT_LOG="$LOGS/audit" \
        COMPOSER_GOOD_SIG_FILE="$GOOD_SIG_FILE" COMPOSER_STUB_INSTALLER="$STUB_INSTALLER" \
        "${envs[@]}" "$BASH" -c "$@" </dev/null
}

# Library installer under test: detection forced to "absent" so the install
# path itself is exercised. Args: <lib file> <function>.
_LIB_CHILD='lib="$1"; fn="$2"
source "$lib" >/dev/null 2>&1 || exit 97
pyvm_detect() { return 1; }; gvm_detect() { return 1; }; jenv_detect() { return 1; }
phpenv_detect() { return 1; }; nvm_detect() { return 1; }; composer_detect() { return 1; }
"$fn"'
# version-manager.sh installer: sourced like main() runs it (set -euo pipefail
# from the script stays active, so an unguarded failure aborts the child).
_VM_CHILD='root="$1"; fn="$2"; set --
source "$root/version-manager.sh" >/dev/null 2>&1 || exit 97
"$fn"'

_reset_logs() { rm -f "$LOGS"/*; : > "$LOGS/sudo"; }
_logs() { cat "$LOGS/$1" 2>/dev/null; }

# Canary tree: an "existing installation" with user data.
_REF="$_SBX/ref"
_mk_canary() {
    local dir="$1" tag="$2"
    rm -rf -- "$dir" "$_REF"
    mkdir -p "$dir/versions/1.0/bin" "$_REF"
    printf 'canary-%s\n' "$tag" > "$dir/canary.txt"
    printf '#!/bin/sh\necho %s\n' "$tag" > "$dir/versions/1.0/bin/tool"
    chmod 755 "$dir/versions/1.0/bin/tool"
    cp -Rp "$dir" "$_REF/tree"
}
_identical() { diff -r "$_REF/tree" "$1" >/dev/null 2>&1 && echo identical || echo DIFFERENT; }
_count() { local n=0 f; for f in "$@"; do [[ -e "$f" || -L "$f" ]] && n=$((n + 1)); done; echo "$n"; }
_clean_home() {
    chmod -R u+w "$HOME" 2>/dev/null
    rm -rf -- "$HOME" && mkdir -p "$HOME" "$VM_BACKUP_DIR"
}

# =============================================================================
# (a) install_dir_stage / install_dir_restore primitives (in-process)
# =============================================================================
source "$ROOT_DIR/lib/backup.sh"

test_helpers_reject_unsafe_paths() {
    _clean_home
    if ! declare -F install_dir_stage >/dev/null || ! declare -F install_dir_restore >/dev/null; then
        chk "defined" "missing" "install_dir_stage/install_dir_restore exist (AX-6d)"
        return "$_T_CASE_FAILS"
    fi
    mkdir -p "$HOME/victim" "$HOME/a"
    printf 'v\n' > "$HOME/victim/keep"
    local nl_dir="$HOME/new"$'\n'"line"
    mkdir -p "$nl_dir"
    local -a bad=("" "relative/dir" "/" "$HOME" "$HOME/" "$TMPDIR" "$HOME/a/../victim" \
        "$HOME/./victim" "$nl_dir")
    local p rc
    for p in "${bad[@]}"; do
        TXN_AUDIT_LOG="$LOGS/audit" install_dir_stage "$p" "$HOME/staged.x" >/dev/null 2>&1
        rc=$?
        chk 1 "$rc" "stage rejects target '${p//$'\n'/\\n}'"
        TXN_AUDIT_LOG="$LOGS/audit" install_dir_restore "$p" "" >/dev/null 2>&1
        rc=$?
        chk 1 "$rc" "restore rejects target '${p//$'\n'/\\n}'"
    done
    chk 0 "$(_count "$HOME/staged.x")" "nothing was staged for any rejected target"
    chk "v" "$(cat "$HOME/victim/keep" 2>/dev/null)" "'..'-target victim untouched"
    chk 1 "$(_count "$nl_dir")" "newline-named dir untouched"
    [[ -d "$HOME" && -d "$TMPDIR" ]] && chk ok ok "\$HOME and \$TMPDIR still exist"

    # Bad staging paths (valid target).
    mkdir -p "$HOME/.tool" && printf 't\n' > "$HOME/.tool/keep"
    local -a bad_staged=("" "relative" "/" "$HOME" "$HOME/.tool" "$HOME/.tool/inner" \
        "$HOME/x/../y" "$HOME/s"$'\n'"x")
    for p in "${bad_staged[@]}"; do
        install_dir_stage "$HOME/.tool" "$p" >/dev/null 2>&1
        rc=$?
        chk 1 "$rc" "stage rejects staging path '${p//$'\n'/\\n}'"
    done
    chk "t" "$(cat "$HOME/.tool/keep" 2>/dev/null)" "target untouched after bad staging paths"
    install_dir_restore "$HOME/.tool" "$HOME" >/dev/null 2>&1
    chk 1 "$?" "restore rejects \$HOME as staging path (would move \$HOME)"
    chk "t" "$(cat "$HOME/.tool/keep" 2>/dev/null)" "target untouched after rejected restore"
    return "$_T_CASE_FAILS"
}

test_helpers_round_trip() {
    _clean_home
    declare -F install_dir_stage >/dev/null || { chk "defined" "missing" "install_dir_stage exists"; return 1; }
    local target="$HOME/.tool" staged="$HOME/.tool.bak.20240101_000000"
    _mk_canary "$target" roundtrip
    ln -s canary.txt "$target/link"
    rm -rf "$_REF/tree" && cp -Rp "$target" "$_REF/tree"
    TXN_AUDIT_LOG="$LOGS/audit" install_dir_stage "$target" "$staged" >/dev/null 2>&1
    chk 0 "$?" "stage succeeds"
    chk 0 "$(_count "$target")" "target moved away"
    chk identical "$(_identical "$staged")" "staged copy is byte-identical"
    # Simulate a partial clone, then restore.
    mkdir -p "$target/bin" && printf 'partial\n' > "$target/PARTIAL"
    TXN_AUDIT_LOG="$LOGS/audit" install_dir_restore "$target" "$staged" >/dev/null 2>&1
    chk 0 "$?" "restore succeeds"
    chk identical "$(_identical "$target")" "restored tree is byte-identical (incl. symlink)"
    chk 0 "$(_count "$staged")" "staged path consumed by restore"
    chk link "$( [[ -L "$target/link" ]] && echo link || echo not-link)" "symlink preserved as a link"
    local journal
    journal=$(cat "$LOGS/audit" 2>/dev/null)
    chk_contains "install_dir_stage" "$journal" "stage journaled"
    chk_contains "install_dir_restore" "$journal" "restore journaled"

    # Absent target: stage is a successful no-op; restore removes a partial.
    rm -rf -- "$target"
    install_dir_stage "$target" "$staged" >/dev/null 2>&1
    chk 0 "$?" "stage of an absent target succeeds"
    chk 0 "$(_count "$staged")" "nothing staged for an absent target"
    mkdir -p "$target" && printf 'partial\n' > "$target/PARTIAL"
    install_dir_restore "$target" "$staged" >/dev/null 2>&1
    chk 0 "$?" "restore with nothing staged succeeds"
    chk 0 "$(_count "$target")" "partial install removed when nothing was staged"

    # Refuse to overwrite an existing staging path.
    _mk_canary "$target" refuse
    mkdir -p "$staged" && printf 'older backup\n' > "$staged/keep"
    install_dir_stage "$target" "$staged" >/dev/null 2>&1
    chk 1 "$?" "stage refuses an existing staging path"
    chk identical "$(_identical "$target")" "target untouched when staging path exists"
    chk "older backup" "$(cat "$staged/keep")" "existing staging path untouched"
    return "$_T_CASE_FAILS"
}

# AX-6d follow-up: install roots OUTSIDE $HOME/$TMPDIR (PYENV_ROOT=/opt/pyenv,
# NVM_DIR=/usr/local/nvm). A fresh install proceeds; an existing tree is moved
# aside and restored; a partial install there is never rm -rf'd; system roots
# are never moved. Everything stays inside the sandbox ($_SBX/outside is
# outside the sandbox HOME and TMPDIR).
test_helpers_outside_home_roots() {
    _clean_home
    declare -F install_dir_stage >/dev/null || { chk "defined" "missing" "install_dir_stage exists"; return 1; }
    local root="$_SBX/outside" target="$_SBX/outside/tool" staged="$_SBX/outside/tool.bak.1" out
    rm -rf -- "$root" && mkdir -p "$root"

    install_dir_stage "$target" "$staged" >/dev/null 2>&1
    chk 0 "$?" "stage of an absent outside-\$HOME target succeeds (fresh custom-root install)"
    chk 0 "$(_count "$target" "$staged")" "nothing created for an absent outside target"
    install_dir_restore "$target" "$staged" >/dev/null 2>&1
    chk 0 "$?" "restore with no partial and nothing staged succeeds outside \$HOME"

    _mk_canary "$target" outside
    install_dir_stage "$target" "$staged" >/dev/null 2>&1
    chk 0 "$?" "existing outside-\$HOME tree is moved aside"
    chk identical "$(_identical "$staged")" "staged outside copy is byte-identical"
    install_dir_restore "$target" "$staged" >/dev/null 2>&1
    chk 0 "$?" "restore moves the outside tree back when no partial exists"
    chk identical "$(_identical "$target")" "outside tree restored byte-identically"
    chk 0 "$(_count "$staged")" "staged path consumed"

    install_dir_stage "$target" "$staged" >/dev/null 2>&1
    mkdir -p "$target" && printf 'partial\n' > "$target/PARTIAL"
    out=$(install_dir_restore "$target" "$staged" 2>&1)
    chk 1 "$?" "restore refuses to rm -rf a partial install outside \$HOME"
    chk partial "$(cat "$target/PARTIAL" 2>/dev/null)" "outside partial left in place"
    chk identical "$(_identical "$staged")" "previous install kept at the staged path"
    chk_contains "preserved at $staged" "$out" "manual restore steps are logged"
    out=$(TRANSACTION_DRY_RUN=1 install_dir_restore "$target" "$staged" 2>&1)
    chk_contains "never removed automatically" "$out" "dry-run states the outside partial is kept"
    chk partial "$(cat "$target/PARTIAL" 2>/dev/null)" "dry-run removes nothing outside \$HOME"

    # System roots are never moved aside. mv/rm/mkdir are shadowed in a
    # subshell so a broken guard records instead of acting.
    local sys_log="$LOGS/sysroot.log" p rc
    : > "$sys_log"
    for p in /usr /usr/bin /usr/local /etc; do
        (
            mv() { printf 'mv %s\n' "$*" >> "$sys_log"; return 1; }
            rm() { printf 'rm %s\n' "$*" >> "$sys_log"; return 1; }
            mkdir() { printf 'mkdir %s\n' "$*" >> "$sys_log"; return 1; }
            install_dir_stage "$p" "$_SBX/staged.sys" >/dev/null 2>&1
        )
        rc=$?
        chk 1 "$rc" "stage refuses system root '$p'"
    done
    chk "" "$(cat "$sys_log")" "no mv/rm/mkdir attempted for any system root"
    local q verdict
    for q in /opt /usr/share /opt/homebrew /usr/local/Cellar "$_SBX" "$(dirname "$TMPDIR")"; do
        verdict=no
        _install_dir_is_system_root "$q" && verdict=yes
        chk yes "$verdict" "'$q' is classified as a system root"
    done
    for q in /opt/pyenv /usr/local/nvm "$target" "$HOME/.pyenv"; do
        verdict=no
        _install_dir_is_system_root "$q" && verdict=yes
        chk no "$verdict" "'$q' is a dedicated install root"
    done
    rm -rf -- "$root"
    return "$_T_CASE_FAILS"
}

test_helpers_dry_run() {
    _clean_home
    declare -F install_dir_stage >/dev/null || { chk "defined" "missing" "install_dir_stage exists"; return 1; }
    local target="$HOME/.tool" staged="$HOME/.tool.bak.dry" out
    _mk_canary "$target" dry
    rm -f "$LOGS/audit"
    out=$(TRANSACTION_DRY_RUN=1 TXN_AUDIT_LOG="$LOGS/audit" install_dir_stage "$target" "$staged" 2>&1)
    chk 0 "$?" "dry-run stage returns 0"
    chk_contains "[dry-run]" "$out" "dry-run stage prints its plan"
    chk identical "$(_identical "$target")" "dry-run stage moves nothing"
    chk 0 "$(_count "$staged")" "dry-run stage creates nothing"
    out=$(TRANSACTION_DRY_RUN=1 TXN_AUDIT_LOG="$LOGS/audit" install_dir_restore "$target" "$staged" 2>&1)
    chk 0 "$?" "dry-run restore returns 0"
    chk identical "$(_identical "$target")" "dry-run restore removes nothing"
    chk 0 "$(_count "$LOGS/audit")" "dry-run writes no audit journal"
    return "$_T_CASE_FAILS"
}

test_backup_resource_preserves_transaction() {
    _clean_home
    transaction_start "installsafety_resource" >/dev/null 2>&1 || { chk started failed "txn start"; return 1; }
    printf 'x\n' > "$HOME/f"
    transaction_add_file "$HOME/f" >/dev/null 2>&1
    # shellcheck source=lib/backup.sh
    source "$ROOT_DIR/lib/backup.sh"
    chk "true" "${_TRANSACTION_ACTIVE:-}" "re-sourcing backup.sh keeps the active transaction"
    chk 1 "${#_TRANSACTION_FILES[@]}" "re-sourcing backup.sh keeps registered files"
    transaction_rollback >/dev/null 2>&1 || _TRANSACTION_ACTIVE=""
    return "$_T_CASE_FAILS"
}

# =============================================================================
# (b) failing clone restores the existing install byte-identically
# =============================================================================
# _fail_case <label> <child-kind lib|vm> <file-or-fn> <fn> <target> <staged-glob-dir> <staged-prefix> [mode]
_assert_restored() {
    local label="$1" rc="$2" target="$3" stage_dir="$4" stage_prefix="$5"
    [[ "$rc" -ne 0 ]] && chk nonzero nonzero "$label: returns non-zero" \
        || chk nonzero "rc=$rc" "$label: returns non-zero"
    chk identical "$(_identical "$target")" "$label: existing install restored byte-identical"
    chk 0 "$(_count "$target/PARTIAL" "$target/CLONED")" "$label: no partial clone left behind"
    chk 0 "$(_count "$stage_dir/$stage_prefix"*)" "$label: staged copy moved back (none left)"
}

_lib_fail_case() {
    local label="$1" lib="$2" fn="$3" target="$4" mode="${5:-fail}" rc
    _clean_home; _reset_logs
    _mk_canary "$target" "$label"
    _child VMS_TEST_UNAME=Linux PATH="$SHIM:$ROOT_DIR/tests/shims:/usr/bin:/bin:/usr/sbin:/sbin" \
        GIT_SHIM_MODE="$mode" -- "$_LIB_CHILD" _ "$ROOT_DIR/lib/$lib" "$fn" >/dev/null 2>&1
    rc=$?
    _assert_restored "$label" "$rc" "$target" "$(dirname "$target")" "$(basename "$target").bak."
}

_vm_fail_case() {
    local label="$1" fn="$2" target="$3" prefix="$4" mode="${5:-fail}" rc
    _clean_home; _reset_logs
    _mk_canary "$target" "$label"
    _child VMS_TEST_UNAME=Linux GIT_SHIM_MODE="$mode" -- "$_VM_CHILD" _ "$ROOT_DIR" "$fn" >/dev/null 2>&1
    rc=$?
    _assert_restored "$label" "$rc" "$target" "$VM_BACKUP_DIR" "$prefix"
}

test_failed_clone_restores_libs() {
    _lib_fail_case "pyvm_install" pyvm.sh pyvm_install "$HOME/.pyenv"
    _lib_fail_case "pyvm_install(plugin clone fails)" pyvm.sh pyvm_install "$HOME/.pyenv" fail-second
    _lib_fail_case "gvm_install" gvm.sh gvm_install "$HOME/.goenv"
    _lib_fail_case "jenv_install" jenv.sh jenv_install "$HOME/.jenv"
    _lib_fail_case "phpenv_install" phpenv.sh phpenv_install "$HOME/.phpenv"
    _lib_fail_case "phpenv_install(php-build clone fails)" phpenv.sh phpenv_install "$HOME/.phpenv" fail-second
    _lib_fail_case "nvm_install" nvm.sh nvm_install "$HOME/.nvm"
    return "$_T_CASE_FAILS"
}

test_failed_clone_restores_version_manager() {
    _vm_fail_case "install_nvm" install_nvm "$HOME/.nvm" "nvm_"
    _vm_fail_case "install_pyenv" install_pyenv "$HOME/.pyenv" "pyenv_"
    _vm_fail_case "install_pyenv(plugin clone fails)" install_pyenv "$HOME/.pyenv" "pyenv_" fail-second
    _vm_fail_case "install_rbenv" install_rbenv "$HOME/.rbenv" "rbenv_"
    _vm_fail_case "install_rbenv(ruby-build clone fails)" install_rbenv "$HOME/.rbenv" "rbenv_" fail-second
    _vm_fail_case "install_phpenv" install_phpenv "$HOME/.phpenv" "phpenv_"
    _vm_fail_case "install_phpenv(php-build clone fails)" install_phpenv "$HOME/.phpenv" "phpenv_" fail-second
    return "$_T_CASE_FAILS"
}

# =============================================================================
# (c) Homebrew path never displaces the existing directory
# =============================================================================
_brew_assert() {
    local label="$1" rc="$2" want_rc="$3" target="$4" stage_dir="$5" prefix="$6" pkg="$7"
    if [[ "$want_rc" == 0 ]]; then
        chk 0 "$rc" "$label: brew path returns 0"
    else
        [[ "$rc" -ne 0 ]] && chk nonzero nonzero "$label: failed brew returns non-zero" \
            || chk nonzero "rc=$rc" "$label: failed brew returns non-zero"
    fi
    chk identical "$(_identical "$target")" "$label: existing dir untouched at its path"
    chk 0 "$(_count "$stage_dir/$prefix"*)" "$label: nothing moved aside"
    chk_contains "install $pkg" "$(_logs brew)" "$label: brew install invoked"
    chk_not_contains "clone" "$(_logs git)" "$label: no git clone on the brew path"
}

_lib_brew_case() {
    local label="$1" lib="$2" fn="$3" target="$4" pkg="$5" brew_rc="${6:-0}" rc
    _clean_home; _reset_logs
    _mk_canary "$target" "$label"
    _child VMS_TEST_UNAME=Darwin BREW_SHIM_RC="$brew_rc" \
        PATH="$BREWBIN:$BASE_PATH" -- "$_LIB_CHILD" _ "$ROOT_DIR/lib/$lib" "$fn" >/dev/null 2>&1
    rc=$?
    _brew_assert "$label" "$rc" "$brew_rc" "$target" "$(dirname "$target")" "$(basename "$target").bak." "$pkg"
}

_vm_brew_case() {
    local label="$1" fn="$2" target="$3" prefix="$4" pkg="$5" brew_rc="${6:-0}" rc
    _clean_home; _reset_logs
    _mk_canary "$target" "$label"
    _child VMS_TEST_UNAME=Darwin BREW_SHIM_RC="$brew_rc" \
        PATH="$BREWBIN:$BASE_PATH" -- "$_VM_CHILD" _ "$ROOT_DIR" "$fn" >/dev/null 2>&1
    rc=$?
    _brew_assert "$label" "$rc" "$brew_rc" "$target" "$VM_BACKUP_DIR" "$prefix" "$pkg"
}

test_brew_path_never_displaces() {
    _lib_brew_case "pyvm_install(brew)" pyvm.sh pyvm_install "$HOME/.pyenv" pyenv
    _lib_brew_case "pyvm_install(brew fails)" pyvm.sh pyvm_install "$HOME/.pyenv" pyenv 1
    _lib_brew_case "gvm_install(brew)" gvm.sh gvm_install "$HOME/.goenv" goenv
    _lib_brew_case "jenv_install(brew)" jenv.sh jenv_install "$HOME/.jenv" jenv
    _vm_brew_case "install_pyenv(brew)" install_pyenv "$HOME/.pyenv" "pyenv_" pyenv
    _vm_brew_case "install_rbenv(brew)" install_rbenv "$HOME/.rbenv" "rbenv_" rbenv
    _vm_brew_case "install_rbenv(brew fails)" install_rbenv "$HOME/.rbenv" "rbenv_" rbenv 1
    _vm_brew_case "install_phpenv(brew)" install_phpenv "$HOME/.phpenv" "phpenv_" phpenv
    return "$_T_CASE_FAILS"
}

# =============================================================================
# (d) privileged build-dependency installs need explicit consent
# =============================================================================
# _priv_case <label> <kind lib|vm> <lib file|-> <fn> <target> <pkgbin dir> <expect-cmd> <sudo-line-prefix>
_priv_case() {
    local label="$1" kind="$2" lib="$3" fn="$4" target="$5" pkgbin="$6" expect="$7" sudo_prefix="$8"
    local -a child
    if [[ "$kind" == lib ]]; then
        child=("$_LIB_CHILD" _ "$ROOT_DIR/lib/$lib" "$fn")
    else
        child=("$_VM_CHILD" _ "$ROOT_DIR" "$fn")
    fi
    local out rc

    # Non-interactive, no consent: nothing under sudo, exact command shown,
    # user-space install still performed.
    _clean_home; _reset_logs
    out=$(_child VMS_TEST_UNAME=Linux GIT_SHIM_MODE=ok PATH="$pkgbin:$BASE_PATH" -- "${child[@]}" 2>&1)
    rc=$?
    chk "" "$(_logs sudo)" "$label: non-interactive w/o VMS_CONFIRM runs nothing under sudo"
    chk_contains "$expect" "$out" "$label: decline prints the exact command"
    chk_contains "VMS_CONFIRM=1" "$out" "$label: decline names --confirm / VMS_CONFIRM=1"
    chk_contains "clone" "$(_logs git)" "$label: user-space clone still attempted"
    chk 0 "$rc" "$label: install continues and succeeds without build deps"
    chk 1 "$(_count "$target/CLONED")" "$label: user-space install present"

    # VMS_CONFIRM=1: the exact argv runs under sudo.
    _clean_home; _reset_logs
    out=$(_child VMS_TEST_UNAME=Linux GIT_SHIM_MODE=ok VMS_CONFIRM=1 PATH="$pkgbin:$BASE_PATH" -- "${child[@]}" 2>&1)
    rc=$?
    chk_contains "$sudo_prefix" "$(_logs sudo)" "$label: VMS_CONFIRM=1 runs the expected sudo argv"
    chk 0 "$rc" "$label: confirmed install succeeds"

    # TRANSACTION_DRY_RUN=1: plan only — no sudo, no clone, nothing created.
    _clean_home; _reset_logs
    out=$(_child VMS_TEST_UNAME=Linux GIT_SHIM_MODE=ok VMS_CONFIRM=1 TRANSACTION_DRY_RUN=1 \
        PATH="$pkgbin:$BASE_PATH" -- "${child[@]}" 2>&1)
    rc=$?
    chk "" "$(_logs sudo)" "$label: dry-run runs nothing under sudo"
    chk "" "$(_logs git)" "$label: dry-run clones nothing"
    chk_contains "[dry-run]" "$out" "$label: dry-run prints the plan"
    chk_contains "$expect" "$out" "$label: dry-run plan names the privileged command"
    chk 0 "$(_count "$target")" "$label: dry-run creates no install dir"
    chk 0 "$rc" "$label: dry-run returns 0"
}

_have_host_apt() { [[ -x /usr/bin/apt-get || -x /bin/apt-get ]]; }

test_privileged_installs_need_consent() {
    local apt_expect="sudo apt-get update && sudo apt-get install -y make build-essential libssl-dev"
    local apt_sudo=$'apt-get\tinstall\t-y\tmake\tbuild-essential'
    _priv_case "pyvm_install(apt)" lib pyvm.sh pyvm_install "$HOME/.pyenv" "$APTBIN" "$apt_expect" "$apt_sudo"
    _priv_case "phpenv_install(apt)" lib phpenv.sh phpenv_install "$HOME/.phpenv" "$APTBIN" \
        "sudo apt-get update && sudo apt-get install -y autoconf bison build-essential" \
        $'apt-get\tinstall\t-y\tautoconf\tbison'
    _priv_case "install_pyenv(apt)" vm - install_pyenv "$HOME/.pyenv" "$APTBIN" "$apt_expect" "$apt_sudo"
    if _have_host_apt; then
        echo "SKIP: yum branch unreachable on a host with /usr/bin/apt-get"
    else
        _priv_case "pyvm_install(yum)" lib pyvm.sh pyvm_install "$HOME/.pyenv" "$YUMBIN" \
            "sudo yum install -y gcc zlib-devel" $'yum\tinstall\t-y\tgcc\tzlib-devel'
        _priv_case "install_pyenv(yum)" vm - install_pyenv "$HOME/.pyenv" "$YUMBIN" \
            "sudo yum install -y gcc zlib-devel" $'yum\tinstall\t-y\tgcc\tzlib-devel'
    fi
    return "$_T_CASE_FAILS"
}

# AX-11: version-manager.sh's documented global flags were no-ops (parse_args
# runs in a process substitution) and the consent warning named a --confirm
# flag that did not exist. Exercised through the real CLI entry point.
test_cli_confirm_and_global_flags() {
    local out rc order apt_sudo=$'apt-get\tinstall\t-y\tmake\tbuild-essential'
    local cli='exec "$BASH" "$1/version-manager.sh" "${@:2}"'
    for order in trailing leading; do
        _clean_home; _reset_logs
        if [[ "$order" == trailing ]]; then
            out=$(_child VMS_TEST_UNAME=Linux GIT_SHIM_MODE=ok PATH="$APTBIN:$BASE_PATH" -- \
                "$cli" _ "$ROOT_DIR" install-pyenv --confirm 2>&1)
        else
            out=$(_child VMS_TEST_UNAME=Linux GIT_SHIM_MODE=ok PATH="$APTBIN:$BASE_PATH" -- \
                "$cli" _ "$ROOT_DIR" --confirm install-pyenv 2>&1)
        fi
        rc=$?
        chk 0 "$rc" "cli $order --confirm: install-pyenv succeeds"
        chk_contains "$apt_sudo" "$(_logs sudo)" "cli $order --confirm: consented sudo argv runs"
        chk_not_contains "Confirmation required" "$out" "cli $order --confirm: no consent warning"
    done
    _clean_home; _reset_logs
    out=$(_child VMS_TEST_UNAME=Linux GIT_SHIM_MODE=ok PATH="$APTBIN:$BASE_PATH" -- \
        "$cli" _ "$ROOT_DIR" install-pyenv 2>&1)
    chk "" "$(_logs sudo)" "cli without --confirm: nothing under sudo"
    chk_contains "re-run with --confirm or VMS_CONFIRM=1" "$out" "cli without --confirm: warning names the flag"
    chk_contains "--confirm" "$(_child -- "$cli" _ "$ROOT_DIR" help 2>&1)" "help documents --confirm"

    # --no-color only matters on a terminal: drive help through a pty (the
    # driver is written by test_confirm_gate_contract, which runs first).
    local py pty="$_SBX/vms_tty_driver.py"
    if ! py=$(command -v python3) || [[ ! -f "$pty" ]]; then
        echo "SKIP: python3/pty driver unavailable — --no-color not exercised"
        return "$_T_CASE_FAILS"
    fi
    _clean_home
    out=$(_child -- 'exec "$0" "$@"' "$py" "$pty" n "$BASH" "$ROOT_DIR/version-manager.sh" help 2>&1)
    chk_contains $'\033[' "$out" "control: help on a tty is colored"
    chk_not_contains '\033[' "$out" "help on a tty renders colors (no literal \\033 sequences)"
    _clean_home
    out=$(_child -- 'exec "$0" "$@"' "$py" "$pty" n "$BASH" "$ROOT_DIR/version-manager.sh" --no-color help 2>&1)
    chk_contains "Options:" "$out" "--no-color help still prints usage"
    chk_not_contains $'\033[' "$out" "--no-color strips ANSI escapes on a tty"
    chk_not_contains '\033[' "$out" "--no-color leaves no literal \\033 sequences"
    return "$_T_CASE_FAILS"
}

# vms_confirm_privileged contract + shell-experience delegate parity.
test_confirm_gate_contract() {
    _clean_home; _reset_logs
    local out rc
    out=$(_child -- 'source "$1/lib/env.sh" >/dev/null 2>&1; vms_confirm_privileged "widget via apt"; echo "rc=$?"' _ "$ROOT_DIR" 2>&1)
    chk_contains "rc=1" "$out" "non-interactive: declines"
    chk_contains "Confirmation required to install widget via apt; re-run with --confirm or VMS_CONFIRM=1" \
        "$out" "non-interactive: warns naming --confirm or VMS_CONFIRM=1"
    out=$(_child VMS_CONFIRM=1 -- 'source "$1/lib/env.sh" >/dev/null 2>&1; vms_confirm_privileged "widget via apt"; echo "rc=$?"' _ "$ROOT_DIR" 2>&1)
    chk "rc=0" "$out" "VMS_CONFIRM=1: confirms silently"
    out=$(_child -- 'source "$1/lib/shell-experience.sh" >/dev/null 2>&1; _shellxp_confirm_system_change "widget via apt"; echo "rc=$?"' _ "$ROOT_DIR" 2>&1)
    chk_contains "rc=1" "$out" "shellxp delegate: declines non-interactively"
    chk_contains "Confirmation required to install widget via apt; re-run with --confirm or VMS_CONFIRM=1" \
        "$out" "shellxp delegate: identical warning"

    # Interactive (pty) path — requires python3; skipped otherwise.
    local py
    if ! py=$(command -v python3); then
        echo "SKIP: python3 unavailable — interactive confirm path not exercised"
        return "$_T_CASE_FAILS"
    fi
    local pty="$_SBX/vms_tty_driver.py"
    cat > "$pty" <<'PY'
import os, pty, select, sys, time
answer = sys.argv[1].encode()
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[2], sys.argv[2:])
out, sent, deadline = b"", False, time.time() + 30
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if fd in r:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        out += data
        if not sent and b"[y/N]" in out:
            os.write(fd, answer + b"\n")
            sent = True
os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace").replace("\r", ""))
PY
    local script='source "$1/lib/shell-experience.sh" >/dev/null 2>&1; "$2" "widget via apt" "${3:-}"; echo "rc=$?"'
    out=$(_child -- 'exec "$0" "$@"' "$py" "$pty" n "$BASH" -c "$script" _ "$ROOT_DIR" _shellxp_confirm_system_change 2>&1)
    chk_contains "Install widget via apt on this system? [y/N]: " "$out" "tty: prompt text unchanged"
    chk_contains "shellxp: skipped widget via apt" "$out" "tty 'n': shellxp skip message unchanged"
    chk_contains "rc=1" "$out" "tty 'n': declines"
    out=$(_child -- 'exec "$0" "$@"' "$py" "$pty" y "$BASH" -c "$script" _ "$ROOT_DIR" _shellxp_confirm_system_change 2>&1)
    chk_contains "rc=0" "$out" "tty 'y': confirms"
    out=$(_child -- 'exec "$0" "$@"' "$py" "$pty" n "$BASH" -c "$script" _ "$ROOT_DIR" vms_confirm_privileged 2>&1)
    chk_contains "Skipped widget via apt" "$out" "tty 'n': untagged canonical skip message"
    chk_contains "rc=1" "$out" "tty 'n': canonical gate declines"
    return "$_T_CASE_FAILS"
}

# =============================================================================
# (e) Composer official installer
# =============================================================================
CBIN="$_SBX/cbin"
_composer_run() {  # extra env... ; sets _C_OUT/_C_RC
    _C_OUT=$(_child VMS_TEST_UNAME=Linux _VMS_COMPOSER_BIN_DIR="$CBIN" \
        PATH="$PHPBIN:$BASE_PATH" "$@" -- "$_LIB_CHILD" _ "$ROOT_DIR/lib/phpenv.sh" composer_install 2>&1)
    _C_RC=$?
}
_composer_reset() {
    _clean_home; _reset_logs
    chmod -R u+w "$CBIN" 2>/dev/null; rm -rf -- "$CBIN"; mkdir -p "$CBIN"
    rm -rf -- "$TMPDIR" && mkdir -p "$TMPDIR"
}
_tmp_clean() { chk 0 "$(_count "$TMPDIR"/vms-composer.* "$TMPDIR"/tmp.* "$CBIN"/.composer.*)" "$1: temp dirs cleaned"; }

test_composer_fail_closed() {
    # Empty signature AND a hash that yields nothing: the old equality check
    # passed ("" == "") and ran the installer. Must fail closed.
    _composer_reset
    _composer_run CURL_SIG_MODE=empty PHP_HASH_BROKEN=1
    [[ "$_C_RC" -ne 0 ]] && chk nonzero nonzero "empty sig: fails" || chk nonzero "rc=$_C_RC" "empty sig: fails"
    chk_not_contains "RAN-INSTALLER" "$(_logs php)" "empty sig: installer never executed"
    chk 0 "$(_count "$CBIN/composer")" "empty sig: nothing published"
    chk "" "$(_logs sudo)" "empty sig: no sudo"
    _tmp_clean "empty sig"

    _composer_reset
    _composer_run CURL_SIG_MODE=empty
    [[ "$_C_RC" -ne 0 ]] && chk nonzero nonzero "empty sig (php ok): fails" || chk nonzero "rc=$_C_RC" "empty sig (php ok): fails"
    chk_not_contains "RAN-INSTALLER" "$(_logs php)" "empty sig (php ok): installer never executed"
    _tmp_clean "empty sig (php ok)"

    _composer_reset
    _composer_run CURL_SIG_MODE=bad
    [[ "$_C_RC" -ne 0 ]] && chk nonzero nonzero "mismatched sig: fails" || chk nonzero "rc=$_C_RC" "mismatched sig: fails"
    chk_not_contains "RAN-INSTALLER" "$(_logs php)" "mismatched sig: installer never executed"
    chk 0 "$(_count "$CBIN/composer")" "mismatched sig: nothing published"
    chk "" "$(_logs sudo)" "mismatched sig: no sudo"
    _tmp_clean "mismatched sig"

    # Hash is taken via argv, never by interpolating the path into PHP source.
    chk_contains '$argv[1]' "$(_logs php)" "hash computed via argv"

    _composer_reset
    _composer_run CURL_SIG_MODE=good PHP_INSTALLER_MODE=broken-binary
    [[ "$_C_RC" -ne 0 ]] && chk nonzero nonzero "broken binary: fails" || chk nonzero "rc=$_C_RC" "broken binary: fails"
    chk 0 "$(_count "$CBIN/composer")" "broken binary: not published"
    _tmp_clean "broken binary"
    return "$_T_CASE_FAILS"
}

test_composer_publish() {
    _composer_reset
    _composer_run CURL_SIG_MODE=good
    chk 0 "$_C_RC" "matching (upper-case) sig: install succeeds"
    chk 1 "$(_count "$CBIN/composer")" "published to the sandboxed bin dir"
    chk_contains "FAKE-COMPOSER" "$(cat "$CBIN/composer" 2>/dev/null)" "published file is the verified binary"
    local mode
    mode=$(stat -c '%a' "$CBIN/composer" 2>/dev/null || stat -f '%Lp' "$CBIN/composer" 2>/dev/null)
    chk 755 "$mode" "published with mode 0755"
    chk_contains "--install-dir=$TMPDIR" "$(_logs php)" "installer ran into a private temp dir"
    chk "" "$(_logs sudo)" "writable bin dir: no sudo"
    _tmp_clean "publish"

    # Existing target: refused, unchanged, no network.
    _composer_reset
    printf 'user composer\n' > "$CBIN/composer"
    _composer_run CURL_SIG_MODE=good
    [[ "$_C_RC" -ne 0 ]] && chk nonzero nonzero "existing target: refused" || chk nonzero "rc=$_C_RC" "existing target: refused"
    chk "user composer" "$(cat "$CBIN/composer")" "existing target unchanged"
    chk_contains "not on PATH" "$_C_OUT" "existing target: user told it is not on PATH"
    chk "" "$(_logs curl)" "existing target: no download"
    _tmp_clean "existing target"

    # Dry-run: no network, plan printed, nothing published.
    _composer_reset
    _composer_run CURL_SIG_MODE=good TRANSACTION_DRY_RUN=1
    chk 0 "$_C_RC" "dry-run returns 0"
    chk_contains "[dry-run]" "$_C_OUT" "dry-run prints the plan"
    chk "" "$(_logs curl)" "dry-run: no download"
    chk "" "$(_logs php)" "dry-run: php never run"
    chk 0 "$(_count "$CBIN/composer")" "dry-run: nothing published"
    _tmp_clean "dry-run"

    if [[ "$(id -u)" == 0 ]]; then
        echo "SKIP: unwritable-dir composer cases (running as root)"
        return "$_T_CASE_FAILS"
    fi
    _composer_reset
    chmod 555 "$CBIN"
    _composer_run CURL_SIG_MODE=good
    [[ "$_C_RC" -ne 0 ]] && chk nonzero nonzero "unwritable dir, no consent: not installed" \
        || chk nonzero "rc=$_C_RC" "unwritable dir, no consent: not installed"
    chk "" "$(_logs sudo)" "unwritable dir, no consent: no sudo"
    chk 0 "$(_count "$CBIN/composer")" "unwritable dir, no consent: nothing published"
    chk_contains "VMS_CONFIRM=1" "$_C_OUT" "unwritable dir: user told how to consent"
    _tmp_clean "unwritable/no-consent"

    _composer_reset
    chmod 555 "$CBIN"
    _composer_run CURL_SIG_MODE=good VMS_CONFIRM=1
    chk_contains $'install\t-m\t0755\t' "$(_logs sudo)" "unwritable dir + VMS_CONFIRM=1: sudo install -m 0755"
    chk_contains $'/build/composer\t'"$CBIN/composer" "$(_logs sudo)" "sudo install argv: verified binary -> bin dir"
    _tmp_clean "unwritable/consent"
    chmod 755 "$CBIN"
    return "$_T_CASE_FAILS"
}

# ── Run — explicit failure accumulation ─────────────────────────────────────
failures=0
run_tcase() { _T_CASE_FAILS=0; "$@" || failures=$((failures + 1)); }
run_tcase test_helpers_reject_unsafe_paths
run_tcase test_helpers_round_trip
run_tcase test_helpers_outside_home_roots
run_tcase test_helpers_dry_run
run_tcase test_backup_resource_preserves_transaction
run_tcase test_failed_clone_restores_libs
run_tcase test_failed_clone_restores_version_manager
run_tcase test_brew_path_never_displaces
run_tcase test_privileged_installs_need_consent
run_tcase test_confirm_gate_contract
run_tcase test_cli_confirm_and_global_flags
run_tcase test_composer_fail_closed
run_tcase test_composer_publish

if [[ "$failures" -gt 0 ]]; then
    echo "test_install_safety.sh: $failures case(s) failed"
    exit 1
fi
echo "test_install_safety.sh: all cases passed"
