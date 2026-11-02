#!/usr/bin/env bash
# WSL-3 (CircleCI lane) — copy the test manifest out of the guest onto the
# Windows side (store_artifacts picks it up from the working directory).
set -u
dest="${CIRCLE_WORKING_DIRECTORY:?}/test-results-wsl2"
mkdir -p "$dest"
if [ -d /home/vmstest/vms/test-results ]; then
    cp -R /home/vmstest/vms/test-results/. "$dest/"
    echo "manifest copied"
else
    echo "no test-results directory was produced"
fi
exit 0
