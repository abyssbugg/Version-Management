#!/usr/bin/env bash
# =============================================================================
# Path Validation Security Tests (remediation directive M3 / findings A4, B1.3)
# =============================================================================
# Binding requirements:
#   - Path containment is SIBLING-PROOF: /base2/file must not pass for
#     base /base (A4 — raw prefix comparison accepted it).
#   - '..' traversal fails closed, never warn-and-pass (A4).
#   - validate_safe_path fails closed (B1.3: the NUL check was dead code —
#     bash strings cannot contain NUL — and '..' only warned).
#   - Containment is canonical/symlink-aware: a symlink escaping the base
#     is rejected; not-yet-existing install targets are supported by
#     canonicalizing the nearest existing ancestor.
#   - Identifier grammar shared by plugin/project name validation.
# =============================================================================

source "${BASH_SOURCE[0]%/*}/../helpers.sh" || { echo "FATAL: cannot source helpers.sh — run via tests/test_runner.sh (P0-3: unsandboxed HOME writes forbidden)" >&2; exit 1; }

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$ROOT_DIR/lib/validation.sh"

SHA() { sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }

failures=0

# ── 1. Sibling-prefix attack (A4) ────────────────────────────────────────────
test_sibling_prefix() {
    local base; base=$(mktemp -d "${TMPDIR:-/tmp}/vms-base.XXXXXX")
    local sibling; sibling="${base}-evil"
    mkdir -p "$sibling"
    printf 'x\n' > "$sibling/file"
    if validate_path_within "$sibling/file" "$base" >/dev/null 2>&1; then
        assert_equals "rejected" "accepted" "A4: sibling prefix ${base}-evil must NOT pass containment for $base"
    else
        assert_equals "rejected" "rejected" "A4: sibling prefix rejected"
    fi
    rm -rf "$base" "$sibling"
}

# ── 2. '..' traversal fails closed in validate_safe_path (A4) ────────────────
test_dotdot_fails_closed() {
    if validate_safe_path "/home/user/../../etc/passwd" >/dev/null 2>&1; then
        assert_equals "rejected" "accepted" "A4: '..' must fail closed, not warn-and-pass"
    else
        assert_equals "rejected" "rejected" "A4: '..' fails closed"
    fi
}

# ── 3. Containment with '..' components canonicalizes then decides ───────────
test_containment_canonicalizes_dotdot() {
    local base; base=$(mktemp -d "${TMPDIR:-/tmp}/vms-base.XXXXXX")
    mkdir -p "$base/sub"
    # resolves INSIDE the base -> allowed
    if validate_path_within "$base/sub/../sub/file" "$base" >/dev/null 2>&1; then
        assert_equals "allowed" "allowed" "containment resolves benign ../ within base"
    else
        assert_equals "allowed" "rejected" "containment must canonicalize, not string-match"
    fi
    # resolves OUTSIDE the base -> rejected
    if validate_path_within "$base/sub/../../outside" "$base" >/dev/null 2>&1; then
        assert_equals "rejected" "accepted" "containment must reject canonical-outside .."
    else
        assert_equals "rejected" "rejected" "canonical-outside .. rejected"
    fi
    rm -rf "$base"
}

# ── 4. Symlink escape rejection ──────────────────────────────────────────────
test_symlink_escape() {
    local base; base=$(mktemp -d "${TMPDIR:-/tmp}/vms-base.XXXXXX")
    local outside; outside=$(mktemp -d "${TMPDIR:-/tmp}/vms-out.XXXXXX")
    printf 'secret\n' > "$outside/target"
    ln -s "$outside/target" "$base/link"
    if validate_path_within "$base/link" "$base" >/dev/null 2>&1; then
        assert_equals "rejected" "accepted" "symlink escaping the base must be rejected"
    else
        assert_equals "rejected" "rejected" "symlink escape rejected"
    fi
    rm -rf "$base" "$outside"
}

# ── 5. Not-yet-existing install targets (parent canonicalization) ────────────
test_nonexistent_target() {
    local base; base=$(mktemp -d "${TMPDIR:-/tmp}/vms-base.XXXXXX")
    # target inside base, parent exists, file doesn't -> allowed
    if validate_path_within "$base/plugins/new.sh" "$base" >/dev/null 2>&1; then
        assert_equals "allowed" "allowed" "nonexistent target inside base allowed"
    else
        assert_equals "allowed" "rejected" "nonexistent target inside base must be allowed (install case)"
    fi
    # parent outside base -> rejected
    if validate_path_within "/etc/vms-evil/new.sh" "$base" >/dev/null 2>&1; then
        assert_equals "rejected" "accepted" "nonexistent target outside base rejected"
    else
        assert_equals "rejected" "rejected" "nonexistent target outside base rejected"
    fi
    rm -rf "$base"
}

# ── 6. Identifier grammar (shared by B1.1/B1.2 lanes) ────────────────────────
test_identifier_grammar() {
    local f=0
    local good=("rbenv" "my-plugin.v2" "tool_1" "A" "a-b_c.d")
    local bad=("../evil" "a/b" ".hidden" "" "a b" 'a"b' ".." "x..y")
    local name
    for name in "${good[@]}"; do
        validate_identifier "$name" >/dev/null 2>&1 \
            && assert_equals "ok" "ok" "identifier '$name' accepted" \
            || { assert_equals "ok" "rejected" "identifier '$name' wrongly rejected"; f=$((f+1)); }
    done
    for name in "${bad[@]}"; do
        validate_identifier "$name" >/dev/null 2>&1 \
            && { assert_equals "rejected" "accepted" "identifier '$name' must be rejected"; f=$((f+1)); } \
            || assert_equals "rejected" "rejected" "identifier '$name' rejected"
    done
    return "$f"
}

# ── 7. Lexical validation: shell metacharacters + control chars fail closed ──
test_lexical() {
    local f=0
    local bad=("/tmp/x;rm -rf /" '/tmp/$(id)' '/tmp/`id`' '/tmp/a|b' '/tmp/x&y' $'/tmp/x\ny' $'/tmp/x\ty')
    local p
    for p in "${bad[@]}"; do
        validate_safe_path "$p" >/dev/null 2>&1 \
            && { assert_equals "rejected" "accepted" "lexical must reject: $(printf %q "$p")"; f=$((f+1)); } \
            || assert_equals "rejected" "rejected" "lexical rejects dangerous path"
    done
    # benign paths pass
    for p in "/home/user/file.txt" "relative/path.txt" "file-name_1.2"; do
        validate_safe_path "$p" >/dev/null 2>&1 \
            && assert_equals "ok" "ok" "lexical accepts benign: $p" \
            || { assert_equals "ok" "rejected" "lexical wrongly rejects benign: $p"; f=$((f+1)); }
    done
    return "$f"
}

# ── 8. Empty args fail closed everywhere (B1.3) ─────────────────────────────
test_empty_fails_closed() {
    local f=0
    validate_safe_path "" >/dev/null 2>&1 && { assert_equals "fail" "pass" "empty path rejected"; f=$((f+1)); } || assert_equals "fail" "fail" "empty path rejected"
    validate_path_within "" "/tmp" >/dev/null 2>&1 && { assert_equals "fail" "pass" "empty path rejected (within)"; f=$((f+1)); } || assert_equals "fail" "fail" "empty path rejected (within)"
    validate_path_within "/tmp/x" "" >/dev/null 2>&1 && { assert_equals "fail" "pass" "empty base rejected"; f=$((f+1)); } || assert_equals "fail" "fail" "empty base rejected"
    return "$f"
}

test_sibling_prefix || failures=$((failures + 1))
test_dotdot_fails_closed || failures=$((failures + 1))
test_containment_canonicalizes_dotdot || failures=$((failures + 1))
test_symlink_escape || failures=$((failures + 1))
test_nonexistent_target || failures=$((failures + 1))
test_identifier_grammar || failures=$((failures + 1))
test_lexical || failures=$((failures + 1))
test_empty_fails_closed || failures=$((failures + 1))

if [[ "$failures" -gt 0 ]]; then
    echo "test_path_validation.sh: $failures case(s) failed"
    exit 1
fi
