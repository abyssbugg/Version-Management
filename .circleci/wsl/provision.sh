#!/usr/bin/env bash
# WSL-3 (CircleCI lane) — guest provisioning: build packages + the
# unprivileged user the suite runs as. Runs as root in the guest.
set -euo pipefail

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git make python3 shellcheck zsh

useradd --create-home --shell /bin/bash vmstest
echo "guest provisioned: $(git --version) / make $(make --version | head -1 | awk '{print $3}')"
