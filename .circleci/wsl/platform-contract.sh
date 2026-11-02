#!/usr/bin/env bash
# WSL-3 (CircleCI lane) — live platform contract: get_os reports wsl on a
# REAL WSL2 kernel (the seam tests could only fabricate this before WSL-1/2).
set -euo pipefail
cd /home/vmstest/vms
got="$(bash -c 'source lib/env.sh >/dev/null 2>&1; get_os')"
echo "get_os -> $got"
test "$got" = wsl
