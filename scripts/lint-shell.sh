#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2086,SC2155,SC2005,SC2207,SC2016
set -euo pipefail

# Runs shellcheck across all project shell scripts with sensible defaults.
# Allows overriding the shellcheck binary via SHELLCHECK or SHELLCHECK_BIN env vars.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_ARGS=(--severity=style --shell=bash --external-sources "--source-path=${REPO_ROOT}")
LIST_ONLY=false
SHOW_HELP=false
SHELLCHECK_ARGS=()

while (($#)); do
  case "$1" in
    --list-targets)
      LIST_ONLY=true
      ;;
    -h|--help)
      SHOW_HELP=true
      ;;
    --)
      shift
      if (($#)); then
        SHELLCHECK_ARGS+=("$@")
      fi
      break
      ;;
    *)
      SHELLCHECK_ARGS+=("$1")
      ;;
  esac
  shift
done

if [[ "$SHOW_HELP" == true ]]; then
  cat <<'USAGE'
Usage: scripts/lint-shell.sh [options] [-- shellcheck_args...]

Options:
  --list-targets       Print the files that would be linted and exit.
  -h, --help          Show this help message.

By default the script runs with: --severity=style --shell=bash --external-sources
You can pass additional arguments after "--" to override these defaults.
Set SHELLCHECK or SHELLCHECK_BIN to point to a custom shellcheck executable.
USAGE
  exit 0
fi

FILES=()
while IFS= read -r file; do
  FILES+=("$file")
done < <(
  cd "$REPO_ROOT" &&
  find . \
    -type f \
    -name '*.sh' \
    ! -path './backups/*' \
    ! -path './themes/*' \
    ! -path './lib/theme-ops.sh.old' \
    | sort
)

if [[ "${#FILES[@]}" -eq 0 ]]; then
  printf 'No shell scripts found to lint.\n'
  exit 0
fi

if [[ "$LIST_ONLY" == true ]]; then
  printf 'Shell scripts to lint (total %d):\n' "${#FILES[@]}"
  printf '  %s\n' "${FILES[@]}"
  exit 0
fi

SHELLCHECK_BIN="${SHELLCHECK_BIN:-${SHELLCHECK:-shellcheck}}"
if ! command -v "$SHELLCHECK_BIN" >/dev/null 2>&1; then
  printf 'Error: shellcheck not found. Install it (e.g. brew install shellcheck) or set SHELLCHECK_BIN.\n' >&2
  exit 127
fi

if [[ "${#SHELLCHECK_ARGS[@]}" -eq 0 ]]; then
  SHELLCHECK_ARGS=("${DEFAULT_ARGS[@]}")
fi

printf 'Running %s %s on %d scripts...\n' "$SHELLCHECK_BIN" "${SHELLCHECK_ARGS[*]}" "${#FILES[@]}"
"$SHELLCHECK_BIN" "${SHELLCHECK_ARGS[@]}" "${FILES[@]}"
