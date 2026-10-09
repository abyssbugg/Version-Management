#!/usr/bin/env bash
# AX-6a / P3-1: tools/version-diagnostic-enhanced.sh --fix may change a shell
# rc only through managed blocks, under the shared workstation-config lock and
# a backup transaction (verify, rollback on failure). --dry-run is zero-write.
# Every case runs the real tool as a process in its own private HOME.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$ROOT/tools/version-diagnostic-enhanced.sh"
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/vms-diag-managed.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
# Sandbox BEFORE any project code runs (each case below also gets its own HOME).
export HOME="$SANDBOX/home" TMPDIR="$SANDBOX/tmp"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME" "$TMPDIR"
unset LOG_FILE TRANSACTION_DRY_RUN BACKUP_DIR VMS_STATE_DIR TXN_AUDIT_LOG REPORT_PATH

command -v zsh >/dev/null 2>&1 || { echo "FAIL: zsh is required to verify zsh rc cases" >&2; exit 1; }

# Detection fakes: check_pyenv_installed needs `pyenv` on PATH; NVM is found
# through $HOME/.nvm/nvm.sh (created per case). FAILBIN holds a zsh whose
# syntax check (-n) always fails: the post-write verification seam.
FAKEBIN="$SANDBOX/fakebin" FAILBIN="$SANDBOX/failbin"
mkdir -p "$FAKEBIN" "$FAILBIN"
printf '%s\n' '#!/bin/sh' 'case "$1" in --version) echo "pyenv 2.3.0" ;; esac' 'exit 0' > "$FAKEBIN/pyenv"
printf '%s\n' '#!/bin/sh' 'if [ "$1" = "-n" ]; then echo "injected zsh -n failure" >&2; exit 1; fi' 'exit 0' > "$FAILBIN/zsh"
chmod +x "$FAKEBIN/pyenv" "$FAILBIN/zsh"

PASS=0 FAIL=0 CASE=''
check() {
    local what="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); else printf 'FAIL [%s]: %s\n' "$CASE" "$what" >&2; FAIL=$((FAIL + 1)); fi
}
has() { grep -qF -- "$1" <<< "$OUT"; }
lacks() { ! grep -qF -- "$1" <<< "$OUT"; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
same() { [[ -f "$1" && -f "$2" && "$(sha "$1")" == "$(sha "$2")" ]]; }
mode_of() { if stat -c %a "$1" >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
block_body() {
    awk -v b="# BEGIN version-management-setup:$2" -v e="# END version-management-setup:$2" '
        $0 == b { inside = 1; next } $0 == e { inside = 0; next } inside { print }' "$1"
}
txn_count() { find "$1/.config-backups/transactions" -mindepth 1 -maxdepth 1 -name 'version_diagnostic_fix.*' 2>/dev/null | wc -l | tr -d ' '; }
lock_released() { [[ ! -e "$1/.local/state/version-manager/locks/workstation-config.lock.d" ]]; }
no_editor_temps() { [[ -z "$(find "$1" -name '.vms-mutation.*' -print 2>/dev/null)" ]]; }
# Sorted tree manifest: every path, symlink target, file mode and content hash.
manifest() {
    (cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r p; do
        if [[ -L "$p" ]]; then printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
        elif [[ -f "$p" ]]; then printf 'F %s %s %s\n' "$p" "$(mode_of "$p")" "$(sha "$p")"
        else printf 'D %s\n' "$p"; fi
    done)
}

# new_home <case>: private HOME with a detectable (fake) NVM install.
new_home() {
    local home="$SANDBOX/cases/$1/home"
    mkdir -p "$home/.nvm" "$SANDBOX/cases/$1/tmp"
    printf '# fake nvm for detection\n' > "$home/.nvm/nvm.sh"
    printf '%s\n' "$home"
}

# run_tool <home> <login-shell> <PATH-prefix> [tool args...]: sets OUT and ST.
# The report and TMPDIR live beside HOME, never inside it.
EXTRA_ENV=()
run_tool() {
    local home="$1" login_shell="$2" prefix="$3" case_dir
    shift 3
    case_dir=$(dirname "$home")
    ST=0
    OUT=$(env -i PATH="${prefix}$FAKEBIN:$PATH" HOME="$home" SHELL="$login_shell" TERM=dumb \
        TMPDIR="$case_dir/tmp" REPORT_PATH="$case_dir/report.txt" \
        XDG_CONFIG_HOME="$home/.config" XDG_CACHE_HOME="$home/.cache" \
        XDG_DATA_HOME="$home/.local/share" XDG_STATE_HOME="$home/.local/state" \
        ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
        bash "$TOOL" "$@" < /dev/null 2>&1) || ST=$?
}

# Oracle: the canonical NVM block is whatever lib/mutation.sh emits.
EXPECTED_NVM=$(env -i PATH="$PATH" HOME="$HOME" bash -c 'source "$1/lib/mutation.sh" >/dev/null 2>&1 && mutation_nvm_block' _ "$ROOT")
EXPECTED_PYENV=$(printf '%s\n' 'export PYENV_ROOT="$HOME/.pyenv"' 'export PATH="$PYENV_ROOT/bin:$PATH"' \
    'eval "$(pyenv init --path)"' 'eval "$(pyenv init -)"')

# (a) Fresh rc: both managed blocks written, user text kept, syntax valid.
CASE=a-fresh
H=$(new_home a); RC="$H/.zshrc"
printf '# user canary\n' > "$RC"
run_tool "$H" /bin/zsh "" --fix
check "exit 0 (got $ST)" test "$ST" -eq 0
check "nvm BEGIN marker" grep -qx '# BEGIN version-management-setup:nvm' "$RC"
check "nvm END marker" grep -qx '# END version-management-setup:nvm' "$RC"
check "pyenv BEGIN marker" grep -qx '# BEGIN version-management-setup:version-diagnostic-pyenv' "$RC"
check "pyenv END marker" grep -qx '# END version-management-setup:version-diagnostic-pyenv' "$RC"
check "canary preserved" grep -qx '# user canary' "$RC"
check "canonical nvm block body" test "$(block_body "$RC" nvm)" == "$EXPECTED_NVM"
check "pyenv block body" test "$(block_body "$RC" version-diagnostic-pyenv)" == "$EXPECTED_PYENV"
check "no unmanaged appends" test "$(grep -c 'NVM_DIR=' "$RC")" -eq 1
check "bash -n" bash -n "$RC"
check "zsh -n" zsh -n "$RC"
check "one transaction per block" test "$(txn_count "$H")" -eq 2
check "lock released" lock_released "$H"
check "no editor temp files" no_editor_temps "$H"
cp "$RC" "$SANDBOX/cases/a/expected"

# (b) Second run: byte-identical, no write attempted.
CASE=b-idempotent
run_tool "$H" /bin/zsh "" --fix
check "exit 0 (got $ST)" test "$ST" -eq 0
check "rc byte-identical" same "$RC" "$SANDBOX/cases/a/expected"
check "no new transaction" test "$(txn_count "$H")" -eq 2
check "already-configured reported" has 'NVM already configured correctly'

# (k) Convergence: fix-nvm-issues.sh owns the same `nvm` block — one block,
# one body, no duplicate. (The editor re-appends a rewritten block last, so
# block ORDER may change; the content may not.) The diag tool then leaves
# that state byte-identical.
CASE=k-converge
ST=0
OUT=$(env -i PATH="$PATH" HOME="$H" SHELL=/bin/zsh TERM=dumb TMPDIR="$SANDBOX/cases/a/tmp" \
    bash "$ROOT/scripts/fix-nvm-issues.sh" --silent < /dev/null 2>&1) || ST=$?
check "fix-nvm-issues --silent exit 0 (got $ST)" test "$ST" -eq 0
check "still exactly one nvm block" test "$(grep -cx '# BEGIN version-management-setup:nvm' "$RC")" -eq 1
check "nvm block body unchanged" test "$(block_body "$RC" nvm)" == "$EXPECTED_NVM"
check "pyenv block body unchanged" test "$(block_body "$RC" version-diagnostic-pyenv)" == "$EXPECTED_PYENV"
check "no duplicate NVM_DIR" test "$(grep -c 'NVM_DIR=' "$RC")" -eq 1
check "canary preserved" grep -qx '# user canary' "$RC"
cp "$RC" "$SANDBOX/cases/a/converged"
run_tool "$H" /bin/zsh "" --fix
check "diag rerun exit 0 (got $ST)" test "$ST" -eq 0
check "diag rerun byte-identical" same "$RC" "$SANDBOX/cases/a/converged"

# (c) Unmanaged NVM_DIR (+ NVM_SILENT) and pyenv init: never touched.
CASE=c-unmanaged
H=$(new_home c); RC="$H/.zshrc"
printf '%s\n' '# user canary' 'export NVM_DIR="$HOME/custom-nvm"' 'export NVM_SILENT=true' 'eval "$(pyenv init -)"' > "$RC"
cp "$RC" "$SANDBOX/cases/c/expected"
run_tool "$H" /bin/zsh "" --fix
check "exit 0 (got $ST)" test "$ST" -eq 0
check "rc byte-identical" same "$RC" "$SANDBOX/cases/c/expected"
check "no managed block" bash -c '! grep -q "^# BEGIN version-management-setup:" "$1"' _ "$RC"
check "no transaction" test "$(txn_count "$H")" -eq 0
check "no NVM_SILENT warning" lacks 'NVM_SILENT is not set'

# (d) NVM_DIR without NVM_SILENT: no write, warning names the real command.
CASE=d-silent-absent
H=$(new_home d); RC="$H/.zshrc"
printf '%s\n' '# user canary' 'export NVM_DIR="$HOME/.nvm"' 'eval "$(pyenv init -)"' > "$RC"
cp "$RC" "$SANDBOX/cases/d/expected"
run_tool "$H" /bin/zsh "" --fix
check "exit 0 (got $ST)" test "$ST" -eq 0
check "rc byte-identical" same "$RC" "$SANDBOX/cases/d/expected"
check "no transaction" test "$(txn_count "$H")" -eq 0
check "warning printed" has 'NVM_SILENT is not set'
check "warning names remediation" has "$ROOT/scripts/fix-nvm-issues.sh --silent"
check "named option exists in fix-nvm-issues.sh" grep -qF -- '--silent)' "$ROOT/scripts/fix-nvm-issues.sh"

# (e) --fix --dry-run: entire HOME tree identical, plan printed, exit 0.
# Hostile environment: any write via logging/backup/audit would show up.
CASE=e-dry-run
H=$(new_home e); RC="$H/.zshrc"
printf '# user canary\n' > "$RC"
manifest "$H" > "$SANDBOX/cases/e/before"
EXTRA_ENV=("LOG_FILE=$H/unwanted.log" "BACKUP_DIR=$H/unwanted-backups" "TXN_AUDIT_LOG=$H/unwanted-audit.log")
run_tool "$H" /bin/zsh "" --fix --dry-run
manifest "$H" > "$SANDBOX/cases/e/after"
check "exit 0 (got $ST)" test "$ST" -eq 0
check "HOME tree byte-identical (no new files)" same "$SANDBOX/cases/e/before" "$SANDBOX/cases/e/after"
check "nvm plan printed" has "[dry-run] Would write managed block nvm to $RC"
check "pyenv plan printed" has "[dry-run] Would write managed block version-diagnostic-pyenv to $RC"
check "cache plan printed" has '[dry-run] Would clear the diagnostic cache'
check "no transaction started" lacks 'Transaction started'
EXTRA_ENV=()

# (e2) TRANSACTION_DRY_RUN=1 from the environment is honored the same way.
CASE=e2-env-dry-run
H=$(new_home e2); RC="$H/.zshrc"
printf '# user canary\n' > "$RC"
manifest "$H" > "$SANDBOX/cases/e2/before"
EXTRA_ENV=("TRANSACTION_DRY_RUN=1" "LOG_FILE=$H/unwanted.log")
run_tool "$H" /bin/zsh "" --fix
EXTRA_ENV=()
manifest "$H" > "$SANDBOX/cases/e2/after"
check "exit 0 (got $ST)" test "$ST" -eq 0
check "HOME tree byte-identical" same "$SANDBOX/cases/e2/before" "$SANDBOX/cases/e2/after"
check "plan printed" has '[dry-run] Would write managed block nvm'

# (f1) Verification fails after the write (PATH seam): rollback, non-zero.
CASE=f1-verify-fails
H=$(new_home f1); RC="$H/.zshrc"
printf '# user canary\n' > "$RC"; chmod 600 "$RC"
cp "$RC" "$SANDBOX/cases/f1/expected"
run_tool "$H" /bin/zsh "$FAILBIN:" --fix
check "non-zero exit (got $ST)" test "$ST" -ne 0
check "rc restored byte-identical" same "$RC" "$SANDBOX/cases/f1/expected"
check "rc mode preserved" test "$(mode_of "$RC")" = 600
check "failure was post-write verification" has 'injected zsh -n failure'
check "rolled back" has 'Rolling back transaction: version_diagnostic_fix'
check "failure reported" has 'One or more remediations failed'
check "lock released" lock_released "$H"
check "no editor temp files" no_editor_temps "$H"

# (f2) Editor fails after corrupting the file (function seam): rollback.
CASE=f2-editor-fails
H=$(new_home f2); RC="$H/.zshrc"
printf '# user canary\n' > "$RC"
cp "$RC" "$SANDBOX/cases/f2/expected"
ST=0
OUT=$(env -i PATH="$FAKEBIN:$PATH" HOME="$H" SHELL=/bin/zsh TERM=dumb TMPDIR="$SANDBOX/cases/f2/tmp" \
    REPORT_PATH="$SANDBOX/cases/f2/report.txt" \
    bash -c 'source "$1"; mutation_block_write() { printf "CORRUPTED\n" >> "$1"; return 1; }; apply_fixes' _ "$TOOL" \
    < /dev/null 2>&1) || ST=$?
check "non-zero status (got $ST)" test "$ST" -ne 0
check "rc restored byte-identical" same "$RC" "$SANDBOX/cases/f2/expected"
check "rolled back" has 'Rolling back transaction: version_diagnostic_fix'
check "lock released" lock_released "$H"

# (f3) Signal mid-write (TERM after the file was corrupted): the writer's
# trap path still rolls back and releases the lock.
CASE=f3-signal
H=$(new_home f3); RC="$H/.zshrc"
printf '# user canary\n' > "$RC"
cp "$RC" "$SANDBOX/cases/f3/expected"
ST=0
OUT=$(env -i PATH="$FAKEBIN:$PATH" HOME="$H" SHELL=/bin/zsh TERM=dumb TMPDIR="$SANDBOX/cases/f3/tmp" \
    REPORT_PATH="$SANDBOX/cases/f3/report.txt" \
    bash -c 'source "$1"; mutation_block_write() { printf "CORRUPTED\n" >> "$1"; kill -TERM "$BASHPID"; }; apply_fixes' _ "$TOOL" \
    < /dev/null 2>&1) || ST=$?
check "non-zero status (got $ST)" test "$ST" -ne 0
check "rc restored byte-identical" same "$RC" "$SANDBOX/cases/f3/expected"
check "rolled back" has 'Rolling back transaction: version_diagnostic_fix'
check "lock released" lock_released "$H"

# (g) Symlinked rc: link survives, target updated, target mode kept.
CASE=g-symlink
H=$(new_home g); mkdir -p "$H/dotfiles"
printf '# user canary\n' > "$H/dotfiles/zshrc"; chmod 600 "$H/dotfiles/zshrc"
ln -s dotfiles/zshrc "$H/.zshrc"
run_tool "$H" /bin/zsh "" --fix
check "exit 0 (got $ST)" test "$ST" -eq 0
check "rc still a symlink" test -L "$H/.zshrc"
check "link target unchanged" test "$(readlink "$H/.zshrc")" = dotfiles/zshrc
check "target has nvm block" grep -qx '# BEGIN version-management-setup:nvm' "$H/dotfiles/zshrc"
check "target has pyenv block" grep -qx '# BEGIN version-management-setup:version-diagnostic-pyenv' "$H/dotfiles/zshrc"
check "target canary preserved" grep -qx '# user canary' "$H/dotfiles/zshrc"
check "target mode 600 preserved" test "$(mode_of "$H/dotfiles/zshrc")" = 600
check "lock released" lock_released "$H"

# (h) Malformed markers (BEGIN without END): refused, unchanged, non-zero.
CASE=h-malformed
H=$(new_home h); RC="$H/.zshrc"
printf '%s\n' '# user canary' '# BEGIN version-management-setup:nvm' 'export KEEP_ME=1' \
    '# BEGIN version-management-setup:version-diagnostic-pyenv' 'export KEEP_ME_TOO=1' > "$RC"
cp "$RC" "$SANDBOX/cases/h/expected"
run_tool "$H" /bin/zsh "" --fix
check "non-zero exit (got $ST)" test "$ST" -ne 0
check "rc byte-identical" same "$RC" "$SANDBOX/cases/h/expected"
check "nvm refusal" has 'Malformed managed block nvm'
check "pyenv refusal" has 'Malformed managed block version-diagnostic-pyenv'
check "no transaction" test "$(txn_count "$H")" -eq 0
run_tool "$H" /bin/zsh "" --fix --dry-run
check "dry-run also refuses (got $ST)" test "$ST" -ne 0
check "rc byte-identical after dry-run" same "$RC" "$SANDBOX/cases/h/expected"

# (i) bash login shell: blocks land in ~/.bashrc, verified with bash -n.
CASE=i-bashrc
H=$(new_home i); RC="$H/.bashrc"
printf '# user canary\n' > "$RC"
run_tool "$H" /bin/bash "" --fix
check "exit 0 (got $ST)" test "$ST" -eq 0
check "nvm block in .bashrc" grep -qx '# BEGIN version-management-setup:nvm' "$RC"
check "pyenv block in .bashrc" grep -qx '# BEGIN version-management-setup:version-diagnostic-pyenv' "$RC"
check "bash -n" bash -n "$RC"
check "no .zshrc created" test ! -e "$H/.zshrc"
cp "$RC" "$SANDBOX/cases/i/expected"
run_tool "$H" /bin/bash "" --fix
check "rerun exit 0 (got $ST)" test "$ST" -eq 0
check "rerun byte-identical" same "$RC" "$SANDBOX/cases/i/expected"

printf 'version-diagnostic managed: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
