#!/usr/bin/env bash
# P3-1 / P3-2: auto_activate_setup/remove must use managed-block semantics
# (mutation_block_write/remove) instead of raw append/awk.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tmp_rovodev_autoactivate.XXXXXX")"
SANDBOX=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$SANDBOX")
trap 'rm -rf -- "$SANDBOX"' EXIT

export HOME="$SANDBOX/home" ZDOTDIR="$SANDBOX/home"
export XDG_CONFIG_HOME="$SANDBOX/home/.config" XDG_CACHE_HOME="$SANDBOX/home/.cache"
export XDG_DATA_HOME="$SANDBOX/home/.local/share" XDG_STATE_HOME="$SANDBOX/home/.local/state"
unset LOG_FILE BACKUP_DIR TRANSACTION_DRY_RUN NVM_DIR

mkdir -p "$HOME"

source "$ROOT/lib/auto-activate.sh"

failures=0
zshrc="$HOME/.zshrc"

# Test 1: idempotent apply
printf 'test_1_apply_idempotent: '
cat > "$zshrc" <<'EOF'
# header
export SHELL=/bin/zsh
EOF
hash1=$(sha256sum < "$zshrc" | cut -d' ' -f1)
auto_activate_setup >/dev/null 2>&1 || { echo "FAIL (setup)"; failures=$((failures+1)); }
hash2=$(sha256sum < "$zshrc" | cut -d' ' -f1)
if [[ "$hash1" != "$hash2" ]]; then
    auto_activate_setup >/dev/null 2>&1 || { echo "FAIL (rerun)"; failures=$((failures+1)); }
    hash3=$(sha256sum < "$zshrc" | cut -d' ' -f1)
    if [[ "$hash2" == "$hash3" ]]; then
        echo "PASS"
    else
        echo "FAIL (not idempotent)"
        failures=$((failures+1))
    fi
else
    echo "FAIL (first apply did nothing)"
    failures=$((failures+1))
fi

# Test 2: remove idempotent
printf 'test_2_remove_idempotent: '
cat > "$zshrc" <<'EOF'
# header
export SHELL=/bin/zsh
EOF
auto_activate_setup >/dev/null 2>&1 || { echo "FAIL (setup)"; failures=$((failures+1)); }
auto_activate_remove >/dev/null 2>&1 || { echo "FAIL (remove)"; failures=$((failures+1)); }
hash1=$(sha256sum < "$zshrc" | cut -d' ' -f1)
auto_activate_remove >/dev/null 2>&1 || { echo "FAIL (remove 2)"; failures=$((failures+1)); }
hash2=$(sha256sum < "$zshrc" | cut -d' ' -f1)
if [[ "$hash1" == "$hash2" ]]; then
    echo "PASS"
else
    echo "FAIL (not idempotent)"
    failures=$((failures+1))
fi

# Test 3: dry-run zero writes
printf 'test_3_dryrun_zero_writes: '
cat > "$zshrc" <<'EOF'
# header
export SHELL=/bin/zsh
EOF
hash_before=$(sha256sum < "$zshrc" | cut -d' ' -f1)
TRANSACTION_DRY_RUN=1 auto_activate_setup >/dev/null 2>&1 || { echo "FAIL (dryrun)"; failures=$((failures+1)); }
hash_after=$(sha256sum < "$zshrc" | cut -d' ' -f1)
if [[ "$hash_before" == "$hash_after" ]]; then
    echo "PASS"
else
    echo "FAIL (dry-run wrote to file)"
    failures=$((failures+1))
fi

# Test 4: preserve unrelated lines
printf 'test_4_preserve_unrelated_lines: '
cat > "$zshrc" <<'EOF'
# header
export SHELL=/bin/zsh
alias myalias='echo hello'
# footer
EOF
hash_original=$(sha256sum < "$zshrc" | cut -d' ' -f1)
auto_activate_setup >/dev/null 2>&1 || { echo "FAIL (setup)"; failures=$((failures+1)); }
grep -q "export SHELL=/bin/zsh" "$zshrc" || { echo "FAIL (SHELL lost)"; failures=$((failures+1)); }
grep -q "alias myalias" "$zshrc" || { echo "FAIL (alias lost)"; failures=$((failures+1)); }
auto_activate_remove >/dev/null 2>&1 || { echo "FAIL (remove)"; failures=$((failures+1)); }
hash_restored=$(sha256sum < "$zshrc" | cut -d' ' -f1)
if [[ "$hash_original" == "$hash_restored" ]]; then
    echo "PASS"
else
    echo "FAIL (not restored)"
    failures=$((failures+1))
fi

# Test 5: roundtrip
printf 'test_5_roundtrip: '
cat > "$zshrc" <<'EOF'
# header
export SHELL=/bin/zsh
EOF
hash_original=$(sha256sum < "$zshrc" | cut -d' ' -f1)
auto_activate_setup >/dev/null 2>&1 || { echo "FAIL (setup)"; failures=$((failures+1)); }
hash_with_hook=$(sha256sum < "$zshrc" | cut -d' ' -f1)
if [[ "$hash_original" == "$hash_with_hook" ]]; then
    echo "FAIL (setup did nothing)"
    failures=$((failures+1))
else
    auto_activate_remove >/dev/null 2>&1 || { echo "FAIL (remove)"; failures=$((failures+1)); }
    hash_after_remove=$(sha256sum < "$zshrc" | cut -d' ' -f1)
    if [[ "$hash_original" != "$hash_after_remove" ]]; then
        echo "FAIL (remove did not restore)"
        failures=$((failures+1))
    else
        auto_activate_setup >/dev/null 2>&1 || { echo "FAIL (reapply)"; failures=$((failures+1)); }
        hash_reapply=$(sha256sum < "$zshrc" | cut -d' ' -f1)
        if [[ "$hash_with_hook" == "$hash_reapply" ]]; then
            echo "PASS"
        else
            echo "FAIL (reapply not byte-equal)"
            failures=$((failures+1))
        fi
    fi
fi

# Test 6: markers present
printf 'test_6_markers_present: '
cat > "$zshrc" <<'EOF'
# header
export SHELL=/bin/zsh
EOF
auto_activate_setup >/dev/null 2>&1 || { echo "FAIL (setup)"; failures=$((failures+1)); }
if grep -q "^# BEGIN version-management-setup:dev-auto-activate-hook\$" "$zshrc" && \
   grep -q "^# END version-management-setup:dev-auto-activate-hook\$" "$zshrc"; then
    echo "PASS"
else
    echo "FAIL (markers missing or malformed)"
    failures=$((failures+1))
fi

if [[ $failures -eq 0 ]]; then
    echo ""
    echo "test_autoactivate_managed.sh: all 6 passed"
    exit 0
else
    echo ""
    echo "test_autoactivate_managed.sh: $failures case(s) failed"
    exit 1
fi
