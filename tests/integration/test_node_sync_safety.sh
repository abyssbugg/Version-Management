#!/usr/bin/env bash
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../helpers.sh"
ROOT="$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)"
# Keep updater's secondary backups inside the per-test HOME for cleanup.
mkdir -p "$HOME/tmp"
export TMPDIR="$HOME/tmp"
failures=0
check() { if ! "$@"; then printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); fi; }
# Relocate only hardcoded system destinations in a test copy. Real transaction,
# backup, comparison and compensation functions execute against the sandbox.
mkdir -p "$HOME/fixture/tools" "$HOME/bin" "$HOME/runtime" "$HOME/shims"
ln -s "$ROOT/lib" "$HOME/fixture/lib"
sed "s|/usr/local/bin|$HOME/bin|g" "$ROOT/tools/update-global-node-symlinks.sh" > "$HOME/fixture/tools/updater.sh"
cat > "$HOME/shims/sudo" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HOME/sudo-calls"
[[ "${1:-}" != -n ]] || shift
if [[ "${FAIL_NPM:-0}" == 1 && "$1" == ln && "$3" == "$HOME/runtime/npm" ]]; then exit 9; fi
exec "$@"
SHIM
chmod +x "$HOME/shims/sudo"
export PATH="$HOME/shims:$PATH"
for cmd in node npm npx; do printf 'runtime-%s\n' "$cmd" > "$HOME/runtime/$cmd"; printf 'old-%s\n' "$cmd" > "$HOME/bin/$cmd"; done
updater="$HOME/fixture/tools/updater.sh"
: > "$HOME/sudo-calls"
TRANSACTION_DRY_RUN=1 bash "$updater" --confirm --non-interactive --node-bin "$HOME/runtime"
check test ! -s "$HOME/sudo-calls"
# A held workstation lock rejects apply before backups or privileged writes.
source "$ROOT/lib/lock.sh"
lock_acquire workstation-mutation 0
if bash "$updater" --confirm --non-interactive --node-bin "$HOME/runtime"; then failures=$((failures + 1)); fi
check test ! -s "$HOME/sudo-calls"
lock_release workstation-mutation
if FAIL_NPM=1 bash "$updater" --confirm --non-interactive --node-bin "$HOME/runtime"; then failures=$((failures + 1)); fi
for cmd in node npm npx; do
    check test "$(cat "$HOME/bin/$cmd")" = "old-$cmd"
    check test "$(cat "$HOME/runtime/$cmd")" = "runtime-$cmd"
done
check grep -q -- '^-n ln' "$HOME/sudo-calls"
bash "$updater" --confirm --non-interactive --node-bin "$HOME/runtime"
for cmd in node npm npx; do check test "$(readlink "$HOME/bin/$cmd")" = "$HOME/runtime/$cmd"; done
: > "$HOME/sudo-calls"
bash "$updater" --confirm --non-interactive --node-bin "$HOME/runtime"
check test ! -s "$HOME/sudo-calls"
# Correct node must not conceal a stale npm destination.
rm "$HOME/bin/npm"
printf wrong > "$HOME/bin/npm"
bash "$updater" --confirm --non-interactive --node-bin "$HOME/runtime"
check test "$(readlink "$HOME/bin/npm")" = "$HOME/runtime/npm"
rm "$HOME/runtime/npx"
: > "$HOME/sudo-calls"
if bash "$updater" --confirm --non-interactive --node-bin "$HOME/runtime"; then failures=$((failures + 1)); fi
check test ! -s "$HOME/sudo-calls"
printf 'Node sync safety failures: %s\n' "$failures"
exit "$failures"
