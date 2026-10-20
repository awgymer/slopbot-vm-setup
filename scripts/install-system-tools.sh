#!/usr/bin/env bash
#
# Installs system-level tools that require root, and sets the system timezone.
# Run as a sudo-capable user: sudo ./install-system-tools.sh
#
# Tools installed:
#   - build-essential  (C toolchain required by Rust crates and other native builds)
#   - zip / unzip
#   - tzdata  (timezone database)
#   - apptainer-suid  (Apptainer with its SUID starter; must be system-level)
#
set -euo pipefail

# Override with: sudo VM_TIMEZONE=Europe/London ./install-system-tools.sh
VM_TIMEZONE="${VM_TIMEZONE:-Australia/Adelaide}"

# ---------------------------------------------------------------------------
# Common utilities
# ---------------------------------------------------------------------------
echo "==> Installing common utilities"
apt-get update -q
apt-get install -y build-essential zip unzip tzdata

# ---------------------------------------------------------------------------
# Timezone
#
# A new VM uses UTC. Set the timezone so that logs and shell timestamps show
# local time. The zone data includes the daylight saving rules.
# ---------------------------------------------------------------------------
echo "==> Setting timezone to ${VM_TIMEZONE}"
if [[ ! -f "/usr/share/zoneinfo/${VM_TIMEZONE}" ]]; then
    echo "ERROR: unknown timezone '${VM_TIMEZONE}' — see 'timedatectl list-timezones'" >&2
    exit 1
fi
if ! timedatectl set-timezone "$VM_TIMEZONE" 2>/dev/null; then
    # systemd is not available (for example, in a container). Set the files.
    echo "    timedatectl is not available — set /etc/localtime directly"
    ln -sf "/usr/share/zoneinfo/${VM_TIMEZONE}" /etc/localtime
    echo "$VM_TIMEZONE" > /etc/timezone
fi

# ---------------------------------------------------------------------------
# Apptainer
#
# The PPA has two builds. 'apptainer' is the non-setuid build, which creates
# a user namespace for every container and so fails once setup-ai-user.sh
# has disabled unprivileged user namespaces. 'apptainer-suid' adds the
# root-owned SUID starter, which needs no user namespace.
# ---------------------------------------------------------------------------
echo "==> Installing Apptainer (setuid build)"
add-apt-repository -y ppa:apptainer/ppa
apt-get update -q
apt-get install -y apptainer-suid

echo
echo "Done."
