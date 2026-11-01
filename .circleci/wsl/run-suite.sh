#!/usr/bin/env bash
# WSL-3 (CircleCI lane) — the full test suite as the unprivileged user.
set -euo pipefail
cd /home/vmstest/vms
make test
