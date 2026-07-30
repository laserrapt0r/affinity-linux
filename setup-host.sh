#!/usr/bin/env bash
# One-off host preparation for NVIDIA GPU passthrough.
#
# Run this once, and again after every NVIDIA driver update -- the CDI spec
# pins driver library paths and goes stale otherwise.
#
#   sudo ./setup-host.sh
set -euo pipefail

msg()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[setup]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "Please run as root (sudo ./setup-host.sh)."

# ---------------------------------------------------------------------------
# Rootless Podman prerequisites.
#
# Rootless containers need a range of subordinate UIDs/GIDs. Debian and Ubuntu
# populate these when the user is created; Arch and some minimal installs do
# not, and podman then fails with a rather opaque error.
# ---------------------------------------------------------------------------
TARGET_USER="${SUDO_USER:-}"
if [ -n "$TARGET_USER" ] && command -v podman >/dev/null 2>&1; then
    if ! grep -q "^${TARGET_USER}:" /etc/subuid 2>/dev/null || \
       ! grep -q "^${TARGET_USER}:" /etc/subgid 2>/dev/null; then
        warn "No subuid/subgid range for '$TARGET_USER' -- rootless Podman will not work."
        if command -v usermod >/dev/null 2>&1; then
            msg "Adding one now..."
            usermod --add-subuids 100000-165535 --add-subgids 100000-165535 \
                "$TARGET_USER" 2>/dev/null \
                || warn "Failed. Add manually:
     echo '$TARGET_USER:100000:65536' | sudo tee -a /etc/subuid /etc/subgid
     podman system migrate"
        fi
    else
        msg "subuid/subgid ranges present for '$TARGET_USER'."
    fi
fi

command -v nvidia-smi >/dev/null 2>&1 || {
    warn "No NVIDIA driver found -- nothing else to do."
    warn "AMD/Intel GPUs need no host setup; /dev/dri is passed through directly."
    exit 0
}

if ! command -v nvidia-ctk >/dev/null 2>&1; then
    hint="install the nvidia-container-toolkit package"
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}${ID_LIKE:-}" in
            *arch*)   hint="sudo pacman -S nvidia-container-toolkit" ;;
            *fedora*|*rhel*)
                      hint="sudo dnf install nvidia-container-toolkit" ;;
            *debian*|*ubuntu*)
                      hint="sudo apt install nvidia-container-toolkit" ;;
            *suse*)   hint="sudo zypper install nvidia-container-toolkit" ;;
        esac
    fi
    die "nvidia-container-toolkit is missing. Install it with:
     $hint"
fi

msg "Generating CDI specification..."
mkdir -p /etc/cdi
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

# ---------------------------------------------------------------------------
# Compatibility fixups for older CDI implementations.
#
# nvidia-ctk emits a CDI 0.7.0 spec. Podman 4.x (Ubuntu 24.04 ships 4.9.3) only
# understands up to 0.6.0 and hard-fails on the 0.7-only 'additionalGids' field
# with a rather unhelpful "unresolvable CDI devices" message.
# ---------------------------------------------------------------------------
CDI_MAJOR_OK=1
if command -v podman >/dev/null 2>&1; then
    PODMAN_MAJOR=$(podman version --format '{{.Client.Version}}' 2>/dev/null | cut -d. -f1)
    [ "${PODMAN_MAJOR:-0}" -lt 5 ] && CDI_MAJOR_OK=0
fi

if [ "$CDI_MAJOR_OK" = "0" ]; then
    msg "Podman < 5 detected -- downgrading the spec to CDI 0.6.0."
    sed -i 's/^cdiVersion: 0\.7\.[0-9]*/cdiVersion: 0.6.0/' /etc/cdi/nvidia.yaml
    python3 - <<'PY'
import re
path = '/etc/cdi/nvidia.yaml'
out, skip = [], False
for line in open(path).read().split('\n'):
    if re.match(r'^\s*additionalGids:\s*$', line):
        skip = True
        continue
    if skip:
        if re.match(r'^\s*-\s*\d+\s*$', line):
            continue
        skip = False
    out.append(line)
open(path, 'w').write('\n'.join(out))
PY
fi

# nvidia-container-toolkit also drops a copy in /var/run/cdi. If that one is
# left at 0.7.0 it re-breaks the registry, so keep only /etc/cdi.
rm -f /var/run/cdi/nvidia.yaml

msg "Verifying..."
if command -v podman >/dev/null 2>&1; then
    if podman run --rm --device nvidia.com/gpu=all ubuntu:24.04 \
            nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null; then
        msg "NVIDIA passthrough works."
    else
        warn "Verification failed -- check 'podman --log-level=debug run --device nvidia.com/gpu=all ...'"
    fi
fi

msg "Done. You can now run ./run-affinity.sh"
