#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# ============================================================================
# Release Automation Script
# Part of Professional Development Terminal Setup
# ============================================================================
# Automates the release process: version bumping, changelog generation,
# tagging, and GitHub release creation.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source dependencies
source "$SCRIPT_DIR/lib/logger.sh" 2>/dev/null || {
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warn() { echo "[WARN] $*"; }
}

# ============================================================================
# Configuration
# ============================================================================

VERSION_FILE="$SCRIPT_DIR/package.json"
CHANGELOG_FILE="$SCRIPT_DIR/CHANGELOG.md"
README_FILE="$SCRIPT_DIR/README.md"

# Conventional commit types
declare -A COMMIT_TYPES=(
    ["feat"]="Features"
    ["fix"]="Bug Fixes"
    ["perf"]="Performance"
    ["docs"]="Documentation"
    ["style"]="Styling"
    ["refactor"]="Refactoring"
    ["test"]="Testing"
    ["chore"]="Maintenance"
    ["build"]="Build"
    ["ci"]="CI/CD"
)

# ============================================================================
# Version Management
# ============================================================================

# Get current version from package.json
get_current_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        grep -o '"version": *"[^"]*"' "$VERSION_FILE" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1
    else
        echo "0.0.0"
    fi
}

# Parse semver components
parse_version() {
    local version="$1"
    local major minor patch

    IFS='.' read -r major minor patch <<< "$version"
    echo "$major $minor $patch"
}

# Bump version based on type
bump_version() {
    local current="$1"
    local bump_type="$2"

    local major minor patch
    read -r major minor patch <<< "$(parse_version "$current")"

    case "$bump_type" in
        major)
            echo "$((major + 1)).0.0"
            ;;
        minor)
            echo "$major.$((minor + 1)).0"
            ;;
        patch)
            echo "$major.$minor.$((patch + 1))"
            ;;
        *)
            echo "$current"
            ;;
    esac
}

# Update version in package.json
update_package_version() {
    local new_version="$1"

    if [[ -f "$VERSION_FILE" ]]; then
        if [[ "$(uname -s)" == "Darwin" ]]; then
            sed -i '' "s/\"version\": *\"[^\"]*\"/\"version\": \"$new_version\"/" "$VERSION_FILE"
        else
            sed -i "s/\"version\": *\"[^\"]*\"/\"version\": \"$new_version\"/" "$VERSION_FILE"
        fi
        log_success "Updated package.json to version $new_version"
    fi
}

# Update version in README badge (if exists)
update_readme_version() {
    local new_version="$1"

    if [[ -f "$README_FILE" ]]; then
        # Update version badge if present
        if grep -q "version-[0-9]" "$README_FILE"; then
            if [[ "$(uname -s)" == "Darwin" ]]; then
                sed -i '' "s/version-[0-9]\+\.[0-9]\+\.[0-9]\+/version-$new_version/g" "$README_FILE"
            else
                sed -i "s/version-[0-9]\+\.[0-9]\+\.[0-9]\+/version-$new_version/g" "$README_FILE"
            fi
            log_info "Updated README version badge"
        fi
    fi
}

# ============================================================================
# Changelog Generation
# ============================================================================

# Generate changelog from git commits
generate_changelog() {
    local from_tag="$1"
    local to_ref="${2:-HEAD}"
    local version="$3"

    local changelog=""
    local date
    date=$(date +%Y-%m-%d)

    changelog+="## [$version] - $date\n\n"

    # Get commits since last tag
    local commits
    if [[ -n "$from_tag" ]] && git rev-parse "$from_tag" >/dev/null 2>&1; then
        commits=$(git log "$from_tag..$to_ref" --pretty=format:"%s|%h" --no-merges 2>/dev/null || echo "")
    else
        commits=$(git log --pretty=format:"%s|%h" --no-merges -50 2>/dev/null || echo "")
    fi

    # Categorize commits
    declare -A categories
    for type in "${!COMMIT_TYPES[@]}"; do
        categories[$type]=""
    done
    categories["other"]=""

    while IFS='|' read -r message hash; do
        [[ -z "$message" ]] && continue

        local matched=false
        for type in "${!COMMIT_TYPES[@]}"; do
            if [[ "$message" =~ ^$type(\(.+\))?:\ (.+) ]]; then
                local scope="${BASH_REMATCH[1]}"
                local desc="${BASH_REMATCH[2]}"
                scope="${scope//[()]/}"

                if [[ -n "$scope" ]]; then
                    categories[$type]+="- **$scope:** $desc ($hash)\n"
                else
                    categories[$type]+="- $desc ($hash)\n"
                fi
                matched=true
                break
            fi
        done

        if [[ "$matched" == "false" ]]; then
            categories["other"]+="- $message ($hash)\n"
        fi
    done <<< "$commits"

    # Build changelog sections
    for type in feat fix perf docs refactor test chore build ci; do
        if [[ -n "${categories[$type]:-}" ]]; then
            changelog+="### ${COMMIT_TYPES[$type]}\n\n"
            changelog+="${categories[$type]}\n"
        fi
    done

    if [[ -n "${categories["other"]:-}" ]]; then
        changelog+="### Other Changes\n\n"
        changelog+="${categories["other"]}\n"
    fi

    echo -e "$changelog"
}

# Prepend to changelog file
update_changelog_file() {
    local new_content="$1"

    if [[ -f "$CHANGELOG_FILE" ]]; then
        # Read existing content (skip header)
        local existing
        existing=$(tail -n +3 "$CHANGELOG_FILE" 2>/dev/null || echo "")

        {
            echo "# Changelog"
            echo
            echo -e "$new_content"
            echo "$existing"
        } > "$CHANGELOG_FILE"
    else
        {
            echo "# Changelog"
            echo
            echo "All notable changes to this project will be documented in this file."
            echo
            echo "The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),"
            echo "and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)."
            echo
            echo -e "$new_content"
        } > "$CHANGELOG_FILE"
    fi

    log_success "Updated CHANGELOG.md"
}

# ============================================================================
# Git Operations
# ============================================================================

# Get latest tag
get_latest_tag() {
    git describe --tags --abbrev=0 2>/dev/null || echo ""
}

# Create release tag
create_tag() {
    local version="$1"
    local message="${2:-Release v$version}"

    git tag -a "v$version" -m "$message"
    log_success "Created tag v$version"
}

# Create release commit
create_release_commit() {
    local version="$1"

    git add -A
    git commit -m "chore(release): v$version

- Updated version to $version
- Generated changelog
- Prepared release artifacts"

    log_success "Created release commit"
}

# Push release
push_release() {
    local version="$1"

    git push origin HEAD
    git push origin "v$version"

    log_success "Pushed release to origin"
}

# ============================================================================
# GitHub Release
# ============================================================================

# Create GitHub release
create_github_release() {
    local version="$1"
    local changelog="$2"
    local draft="${3:-false}"
    local prerelease="${4:-false}"

    if ! command -v gh >/dev/null 2>&1; then
        log_warn "GitHub CLI (gh) not installed. Skipping GitHub release creation."
        log_info "Install with: brew install gh"
        return 1
    fi

    local gh_args=("release" "create" "v$version")
    gh_args+=("--title" "v$version")
    gh_args+=("--notes" "$changelog")

    [[ "$draft" == "true" ]] && gh_args+=("--draft")
    [[ "$prerelease" == "true" ]] && gh_args+=("--prerelease")

    if gh "${gh_args[@]}"; then
        log_success "Created GitHub release v$version"
        return 0
    else
        log_error "Failed to create GitHub release"
        return 1
    fi
}

# ============================================================================
# Pre-release Checks
# ============================================================================

# Run pre-release checks
run_checks() {
    log_info "Running pre-release checks..."

    local issues=0

    # Check git status
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        log_warn "Working directory has uncommitted changes"
        issues=$(( issues + 1 ))
    fi

    # Check we're on main/master
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    if [[ "$branch" != "main" && "$branch" != "master" ]]; then
        log_warn "Not on main/master branch (current: $branch)"
        issues=$(( issues + 1 ))
    fi

    # Run tests if available
    if [[ -f "$SCRIPT_DIR/Makefile" ]]; then
        log_info "Running tests..."
        if make -C "$SCRIPT_DIR" test >/dev/null 2>&1; then
            log_success "Tests passed"
        else
            log_warn "Tests failed or not available"
            issues=$(( issues + 1 ))
        fi
    fi

    # Run linting if available
    if [[ -f "$SCRIPT_DIR/scripts/lint-shell.sh" ]]; then
        log_info "Running linter..."
        if "$SCRIPT_DIR/scripts/lint-shell.sh" >/dev/null 2>&1; then
            log_success "Lint passed"
        else
            log_warn "Lint issues found"
            issues=$(( issues + 1 ))
        fi
    fi

    if [[ $issues -gt 0 ]]; then
        log_warn "Found $issues issue(s). Consider addressing before release."
        return 1
    fi

    log_success "All pre-release checks passed"
    return 0
}

# ============================================================================
# Interactive Release
# ============================================================================

interactive_release() {
    echo
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║            Release Automation                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo

    local current_version
    current_version=$(get_current_version)
    local latest_tag
    latest_tag=$(get_latest_tag)

    echo "  Current version: $current_version"
    echo "  Latest tag:      ${latest_tag:-none}"
    echo

    # Select bump type
    echo "  Select version bump type:"
    echo
    echo "    1) patch  - Bug fixes (x.x.X)"
    echo "    2) minor  - New features (x.X.0)"
    echo "    3) major  - Breaking changes (X.0.0)"
    echo "    4) custom - Enter version manually"
    echo

    local choice
    read -r -p "  Enter choice [1]: " choice
    choice="${choice:-1}"

    local new_version
    case "$choice" in
        1) new_version=$(bump_version "$current_version" "patch") ;;
        2) new_version=$(bump_version "$current_version" "minor") ;;
        3) new_version=$(bump_version "$current_version" "major") ;;
        4)
            read -r -p "  Enter version (e.g., 1.2.3): " new_version
            ;;
        *) new_version=$(bump_version "$current_version" "patch") ;;
    esac

    echo
    echo "  New version: $new_version"
    echo

    # Run checks
    run_checks || true
    echo

    # Confirm
    read -r -p "  Proceed with release v$new_version? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        echo "  Release cancelled."
        exit 0
    fi

    echo
    log_info "Starting release process..."

    # Update version
    update_package_version "$new_version"
    update_readme_version "$new_version"

    # Generate changelog
    local changelog
    changelog=$(generate_changelog "$latest_tag" "HEAD" "$new_version")
    update_changelog_file "$changelog"

    # Create commit and tag
    create_release_commit "$new_version"
    create_tag "$new_version"

    echo
    read -r -p "  Push to origin? [y/N]: " push_confirm
    if [[ "$push_confirm" =~ ^[Yy] ]]; then
        push_release "$new_version"

        read -r -p "  Create GitHub release? [y/N]: " gh_confirm
        if [[ "$gh_confirm" =~ ^[Yy] ]]; then
            create_github_release "$new_version" "$changelog"
        fi
    fi

    echo
    log_success "Release v$new_version complete!"
    echo
    echo "  Next steps:"
    echo "    - Verify the release on GitHub"
    echo "    - Update any external documentation"
    echo "    - Announce the release"
    echo
}

# ============================================================================
# CLI Interface
# ============================================================================

show_usage() {
    cat << EOF
Usage: $(basename "$0") [COMMAND] [OPTIONS]

Release automation for the Version Manager Suite.

Commands:
    interactive     Interactive release wizard (default)
    bump TYPE       Bump version (patch|minor|major)
    changelog       Generate changelog from commits
    tag VERSION     Create a release tag
    check           Run pre-release checks
    github VERSION  Create GitHub release

Options:
    -v, --version VERSION   Specify version explicitly
    -d, --dry-run           Show what would be done
    -y, --yes               Skip confirmations
    --draft                 Create draft release
    --prerelease            Mark as prerelease
    -h, --help              Show this help

Examples:
    $(basename "$0")                     # Interactive release
    $(basename "$0") bump patch          # Bump patch version
    $(basename "$0") changelog           # Generate changelog only
    $(basename "$0") check               # Run pre-release checks

EOF
}

# ============================================================================
# Main
# ============================================================================

main() {
    local command="${1:-interactive}"
    shift || true

    case "$command" in
        interactive|-i)
            interactive_release
            ;;
        bump)
            local bump_type="${1:-patch}"
            local current
            current=$(get_current_version)
            local new_version
            new_version=$(bump_version "$current" "$bump_type")
            echo "$new_version"
            ;;
        changelog)
            local latest_tag
            latest_tag=$(get_latest_tag)
            local version
            version=$(get_current_version)
            generate_changelog "$latest_tag" "HEAD" "$version"
            ;;
        tag)
            local version="$1"
            if [[ -z "$version" ]]; then
                version=$(get_current_version)
            fi
            create_tag "$version"
            ;;
        check)
            run_checks
            ;;
        github)
            local version="${1:-$(get_current_version)}"
            local changelog
            changelog=$(generate_changelog "$(get_latest_tag)" "HEAD" "$version")
            create_github_release "$version" "$changelog" "${2:-false}" "${3:-false}"
            ;;
        version)
            get_current_version
            ;;
        -h|--help|help)
            show_usage
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
