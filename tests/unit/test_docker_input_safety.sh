#!/usr/bin/env bash
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/../helpers.sh"
ROOT="${VMS_TEST_SOURCE_ROOT:-$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)}"
source "$ROOT/version-advanced.sh"
failures=0
mkdir -p "$HOME/project"
cd "$HOME/project"
for language in node python go rust java; do
    printf 'original\n' > "Dockerfile.$language"
    for bad in $'1.2\nRUN echo injected' '1.2 AS injected' $'1.2\r' $'1.2\t' 'x#comment' ':invalid'; do
        if "generate_dockerfile_$language" "$bad"; then failures=$((failures + 1)); fi
        if [[ "$(cat "Dockerfile.$language")" != original ]]; then failures=$((failures + 1)); fi
        printf 'original\n' > "Dockerfile.$language"
    done
    "generate_dockerfile_$language" 1.2.3 || failures=$((failures + 1))
    grep -q '1.2.3' "Dockerfile.$language" || failures=$((failures + 1))
done
printf 'Docker input failures: %s\n' "$failures"
exit "$failures"
