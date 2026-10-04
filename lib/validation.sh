#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# ============================================================================
# Input Validation Module
# Part of Professional Development Terminal Setup
# ============================================================================
# Provides input validation functions for security and robustness.
# All public functions should validate their inputs using these helpers.
# ============================================================================

# Source logger if not already loaded
_VMS_VALIDATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f log_error >/dev/null 2>&1; then
    source "$_VMS_VALIDATION_DIR/logger.sh" 2>/dev/null || {
        log_error() { echo "[ERROR] $*" >&2; }
        log_warn() { echo "[WARN] $*" >&2; }
        log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo "[DEBUG] $*"; }
    }
fi

# ============================================================================
# String Validation
# ============================================================================

# Validate string is not empty
# Usage: validate_not_empty "$var" "Variable name"
validate_not_empty() {
    local value="$1"
    local name="${2:-value}"

    if [[ -z "$value" ]]; then
        log_error "Validation failed: $name cannot be empty"
        return 1
    fi
    return 0
}

# Validate string matches regex pattern
# Usage: validate_pattern "$var" "^[a-z]+$" "must be lowercase letters"
validate_pattern() {
    local value="$1"
    local pattern="$2"
    local message="${3:-must match pattern $pattern}"

    if [[ ! "$value" =~ $pattern ]]; then
        log_error "Validation failed: '$value' $message"
        return 1
    fi
    return 0
}

# Validate string length is within bounds
# Usage: validate_length "$var" 1 255 "username"
validate_length() {
    local value="$1"
    local min="${2:-0}"
    local max="${3:-999999}"
    local name="${4:-value}"
    local len=${#value}

    if (( len < min )); then
        log_error "Validation failed: $name is too short (${len} < ${min})"
        return 1
    fi
    if (( len > max )); then
        log_error "Validation failed: $name is too long (${len} > ${max})"
        return 1
    fi
    return 0
}

# ============================================================================
# Version Validation
# ============================================================================

# Validate semantic version format (major.minor.patch)
# Usage: validate_semver "1.2.3"
validate_semver() {
    local version="$1"
    local strict="${2:-false}"

    if [[ "$strict" == "true" ]]; then
        # Strict: exactly major.minor.patch
        if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_error "Invalid version format: $version (expected major.minor.patch)"
            return 1
        fi
    else
        # Flexible: major, major.minor, or major.minor.patch
        if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)?(\.[0-9]+)?$ ]]; then
            log_error "Invalid version format: $version"
            return 1
        fi
    fi
    return 0
}

# Validate Node.js version format
# Usage: validate_node_version "20.10.0"
validate_node_version() {
    local version="$1"
    # Allow v prefix and various formats
    if [[ ! "$version" =~ ^v?[0-9]+(\.[0-9]+)?(\.[0-9]+)?$ ]]; then
        log_error "Invalid Node.js version: $version"
        return 1
    fi
    return 0
}

# Validate Python version format
# Usage: validate_python_version "3.12.0"
validate_python_version() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        log_error "Invalid Python version: $version"
        return 1
    fi
    return 0
}

# ============================================================================
# Path Validation
# ============================================================================

# Validate path contains no dangerous characters — LEXICAL ONLY (no
# filesystem access). Redesigned M3 (findings A4, B1.3): the old version's
# NUL check was dead code (bash strings cannot contain NUL) and '..' only
# warned then PASSED. Now: fails closed on empty, newline/tab, shell
# metacharacters, and any '..' (raw user input never needs traversal —
# canonical containment in path_validate_containment handles resolved '..'
# where it is legitimate).
validate_safe_path() {
    local path="$1"

    [[ -n "$path" ]] || { log_error "Path validation failed: empty path"; return 1; }

    # Embedded newlines/tabs corrupt logs and registries — reject.
    if [[ "$path" == *$'\n'* || "$path" == *$'\t'* ]]; then
        log_error "Path contains newline/tab: rejected"
        return 1
    fi

    # Shell metacharacters: paths are data, never command strings — a path
    # carrying these is an injection attempt.
    if [[ "$path" =~ [\;\|\&\$\`] ]]; then
        log_error "Path contains shell metacharacters: rejected"
        return 1
    fi

    # A4 hardening: '..' fails closed (was warn-and-pass).
    if [[ "$path" == *".."* ]]; then
        log_error "Path contains '..' — rejected (fail closed)"
        return 1
    fi

    return 0
}

# Resolve symlinks fully for an existing path (portable: readlink -f on GNU
# coreutils and macOS 12.3+, python3 fallback). Fail closed if neither works.
_path_realpath() {
    local p="$1"
    if readlink -f "$p" >/dev/null 2>&1; then
        readlink -f "$p"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null
        return 0
    fi
    return 1
}

# Canonicalize a path whose LEAF may not exist yet (install targets): the
# nearest existing ancestor is resolved (symlinks followed via cd -P) and the
# remaining suffix — which must not contain '..' (lexical check upstream) —
# is appended. Prints the canonical path; fails closed if the ancestor
# cannot be resolved.
_path_canonical() {
    local path="$1"
    [[ -n "$path" ]] || return 1
    case "$path" in
        /*) ;;
        *) path="$PWD/$path" ;;
    esac
    local dir="$path" suffix=""
    # Walk up to the nearest existing ancestor, collecting the missing suffix.
    while [[ ! -e "$dir" && ! -L "$dir" && "$dir" != "/" ]]; do
        suffix="/${dir##*/}$suffix"
        dir="${dir%/*}"
        [[ -z "$dir" ]] && dir="/"
    done
    local resolved
    resolved=$(cd -P "$dir" 2>/dev/null && pwd) || return 1
    printf '%s%s\n' "${resolved%/}" "$suffix"
    return 0
}

# Validate a path resolves INSIDE an allowed base directory.
# Redesigned M3 (finding A4): the old check compared RAW STRING PREFIXES, so
# /base2/file passed for base /base, and non-existent targets always failed
# (the resolver required the path to exist). Now:
#   - the base must exist (canonicalized via realpath)
#   - existing candidates are realpath-resolved (symlink escapes rejected)
#   - not-yet-existing candidates are canonicalized via their existing
#     ancestor (the install-target case)
#   - the comparison is exact-base or base/<anything> — sibling-proof
# Benign '..' is allowed here because the canonical form decides (raw '..'
# stays rejected in validate_safe_path).
path_validate_containment() {
    local path="$1" base="$2"

    [[ -n "$path" && -n "$base" ]] || { log_error "Containment: empty path or base"; return 1; }
    if [[ "$path" == *$'\n'* || "$path" == *$'\t'* ]] || [[ "$path" =~ [\;\|\&\$\`] ]]; then
        log_error "Containment: path failed lexical screen"
        return 1
    fi

    local rbase
    rbase=$(_path_realpath "$base") || { log_error "Containment: cannot resolve base: $base"; return 1; }
    [[ -d "$rbase" ]] || { log_error "Containment: base is not a directory: $base"; return 1; }

    local rcand
    if [[ -e "$path" || -L "$path" ]]; then
        rcand=$(_path_realpath "$path") || { log_error "Containment: cannot resolve path: $path"; return 1; }
    else
        rcand=$(_path_canonical "$path") || { log_error "Containment: cannot canonicalize path: $path"; return 1; }
    fi

    if [[ "$rcand" != "$rbase" && "$rcand" != "$rbase/"* ]]; then
        log_error "Path is outside allowed directory: $path"
        return 1
    fi
    return 0
}

# Legacy name preserved as a thin wrapper.
validate_path_within() {
    path_validate_containment "$@"
}

# Strict identifier grammar (M3): shared by plugin and project name
# validation (findings B1.1, B1.2). Letters/digits first, then letters,
# digits, dot, underscore, hyphen; '..' is rejected; empty is rejected.
validate_identifier() {
    local name="$1"
    local max="${2:-64}"

    [[ -n "$name" ]] || { log_error "Identifier: empty"; return 1; }
    (( ${#name} <= max )) || { log_error "Identifier too long (${#name} > $max)"; return 1; }
    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        log_error "Invalid identifier: '$name'"
        return 1
    fi
    if [[ "$name" == *".."* ]]; then
        log_error "Identifier must not contain '..': '$name'"
        return 1
    fi
    return 0
}

# ============================================================================
# File Validation
# ============================================================================

# Validate file exists and is readable
# Usage: validate_file_readable "/path/to/file"
validate_file_readable() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        log_error "File not found: $file"
        return 1
    fi

    if [[ ! -r "$file" ]]; then
        log_error "File not readable: $file"
        return 1
    fi

    return 0
}

# Validate file is writable (or parent dir is writable for new files)
# Usage: validate_file_writable "/path/to/file"
validate_file_writable() {
    local file="$1"

    if [[ -f "$file" ]]; then
        if [[ ! -w "$file" ]]; then
            log_error "File not writable: $file"
            return 1
        fi
    else
        local dir
        dir="$(dirname "$file")"
        if [[ ! -d "$dir" ]]; then
            log_error "Parent directory does not exist: $dir"
            return 1
        fi
        if [[ ! -w "$dir" ]]; then
            log_error "Parent directory not writable: $dir"
            return 1
        fi
    fi

    return 0
}

# ============================================================================
# Numeric Validation
# ============================================================================

# Validate value is a positive integer
# Usage: validate_positive_int "$var" "port number"
validate_positive_int() {
    local value="$1"
    local name="${2:-value}"

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log_error "Invalid $name: must be a positive integer"
        return 1
    fi

    if (( value <= 0 )); then
        log_error "Invalid $name: must be greater than 0"
        return 1
    fi

    return 0
}

# Validate value is within numeric range
# Usage: validate_in_range "$var" 1 100 "percentage"
validate_in_range() {
    local value="$1"
    local min="$2"
    local max="$3"
    local name="${4:-value}"

    if [[ ! "$value" =~ ^-?[0-9]+$ ]]; then
        log_error "Invalid $name: must be a number"
        return 1
    fi

    if (( value < min || value > max )); then
        log_error "Invalid $name: must be between $min and $max"
        return 1
    fi

    return 0
}

# ============================================================================
# Selection Validation
# ============================================================================

# Validate value is one of allowed options
# Usage: validate_option "$choice" "yes" "no" "maybe"
validate_option() {
    local value="$1"
    shift
    local options=("$@")

    for opt in "${options[@]}"; do
        if [[ "$value" == "$opt" ]]; then
            return 0
        fi
    done

    log_error "Invalid option '$value'. Allowed: ${options[*]}"
    return 1
}

# ============================================================================
# Export Functions
# ============================================================================

export -f validate_not_empty validate_pattern validate_length
export -f validate_semver validate_node_version validate_python_version
export -f validate_safe_path validate_path_within path_validate_containment
export -f validate_identifier _path_realpath _path_canonical
export -f validate_file_readable validate_file_writable
export -f validate_positive_int validate_in_range
export -f validate_option
