#!/usr/bin/env bash
# WSL-3 (CircleCI lane) — stage an unprivileged clone in the Linux
# filesystem. The Windows checkout is translated via WSLENV
# (CIRCLE_WORKING_DIRECTORY/p, set at job level).
set -euo pipefail

: "${CIRCLE_WORKING_DIRECTORY:?WSLENV did not translate CIRCLE_WORKING_DIRECTORY}"
git config --global --add safe.directory "$CIRCLE_WORKING_DIRECTORY"
useradd --create-home --shell /bin/bash vmstest
git clone --quiet --no-local "$CIRCLE_WORKING_DIRECTORY" /home/vmstest/vms
chown -R vmstest:vmstest /home/vmstest/vms
echo "clone staged at /home/vmstest/vms ($(cd /home/vmstest/vms && git rev-parse --short HEAD))"
