#!/usr/bin/env bash
# WSL-3 (CircleCI lane) — fatal proof that the guest runs a WSL2 kernel.
# This is the feasibility verdict for CircleCI Windows executors: WSL2 needs
# nested virtualization; if the hypervisor is unavailable, this fails with
# the host's evidence in the log (loud, never fake green).
set -euo pipefail

cat /proc/version
if grep -q 'WSL2' /proc/sys/kernel/osrelease; then
    echo "WSL2 kernel confirmed: $(cat /proc/sys/kernel/osrelease)"
else
    echo "FEASIBILITY VERDICT: the guest kernel is NOT a WSL2 kernel"
    echo "  osrelease: $(cat /proc/sys/kernel/osrelease)"
    echo "  CircleCI's Windows executor very likely lacks nested virtualization;"
    echo "  the WSL-3 lane cannot run here. Revert to a lane host that can."
    exit 1
fi
