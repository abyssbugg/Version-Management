#!/usr/bin/env bash
# A3-3: invoke real public APIs and real transactional publisher.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../helpers.sh"
ROOT="$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)"
for lib in nvm fnm pyvm phpenv gvm jenv rustup; do
    # Fixed module list above; each module is linted independently.
    # shellcheck source=/dev/null
    source "$ROOT/lib/$lib.sh"
done
# No runtime manager, network installer, or cache writer is allowed in this test.
nvm_detect() { return 0; }; fnm_detect() { return 0; }; pyvm_detect() { return 0; }
phpenv_detect() { return 0; }; gvm_detect() { return 0; }; jenv_detect() { return 0; }; rustup_detect() { return 0; }
nvm_validate_version() { return 0; }; fnm_validate_version() { return 0; }; pyvm_validate_version() { return 0; }
phpenv_validate_version() { return 0; }; gvm_validate_version() { return 0; }; jenv_validate_version() { return 0; }; rustup_validate_version() { return 0; }
manager() { calls=$((calls + 1)); SWITCHED=yes; return "$manager_rc"; }
nvm() { manager "$@"; }; fnm() { if [[ "$1" == list ]]; then return 0; fi; manager "$@"; }
pyenv() { manager "$@"; }; phpenv() { manager "$@"; }; goenv() { manager "$@"; }; jenv() { manager "$@"; }
cache_delete() { calls=$((calls + 1)); }
failures=0
check() { if ! "$@"; then printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); fi; }
mkdir -p "$HOME/project"
cd "$HOME/project"
while read -r lib file version; do
    calls=0; manager_rc=0; SWITCHED=no
    printf 'previous\n' > "$file"
    TRANSACTION_DRY_RUN=1 "${lib}_set_local" "$version" || failures=$((failures + 1))
    check test "$(cat "$file")" = previous
    check test "$calls" -eq 0
    manager_rc=1
    if [[ "$lib" != rustup ]]; then
        if "${lib}_set_local" "$version"; then failures=$((failures + 1)); fi
        check test "$(cat "$file")" = previous
    fi
    manager_rc=0
    "${lib}_set_local" "$version" || failures=$((failures + 1))
    check test "$(cat "$file")" = "$version"
    if [[ "$lib" != rustup ]]; then check test "$SWITCHED" = yes; fi
    rm "$file"
done <<'CASES'
nvm .nvmrc 22.1.0
fnm .node-version 22.1.0
pyvm .python-version 3.12.1
phpenv .php-version 8.3.1
gvm .go-version 1.22.1
jenv .java-version 17.0.1
rustup rust-toolchain 1.81.0
CASES
calls=0; manager_rc=0
LOG_FILE="$HOME/preview-log/file" TRANSACTION_DRY_RUN=1 fnm_install_version 22.1.0 || failures=$((failures + 1))
LOG_FILE="$HOME/preview-log/file" TRANSACTION_DRY_RUN=1 nvm_set_local 22.1.0 || failures=$((failures + 1))
check test ! -e "$HOME/preview-log"
check test "$calls" -eq 0
# Failed callbacks remove new files and restore symlink targets and modes.
manager_rc=1
if nvm_set_local 22.1.0; then failures=$((failures + 1)); fi
check test ! -e .nvmrc
printf 'target-before\n' > target
chmod 600 target
ln -s target .nvmrc
if nvm_set_local 22.1.0; then failures=$((failures + 1)); fi
check test -L .nvmrc
check test "$(cat target)" = target-before
check test "$(ls -l target | awk '{print substr($1,1,10)}')" = '-rw-------'
manager_rc=0
transaction_start caller_version
active=$_TRANSACTION_ACTIVE
calls=0
if nvm_set_local 22.1.0; then failures=$((failures + 1)); fi
check test "$_TRANSACTION_ACTIVE" = "$active"
check test "$calls" -eq 0
transaction_rollback
if (transaction_add_file() { return 1; }; nvm_set_local 22.1.0); then failures=$((failures + 1)); fi
check test "$(cat target)" = target-before
# A failing manager can mutate an already-identical version file itself.
mutating_callback() { printf 'broken\n' > "$1"; return 1; }
printf '22.1.0\n' > target
if local_version_publish .nvmrc 22.1.0 mutating_callback .nvmrc; then failures=$((failures + 1)); fi
check test -L .nvmrc
check test "$(cat target)" = 22.1.0
printf 'Local version safety failures: %s\n' "$failures"
exit "$failures"
