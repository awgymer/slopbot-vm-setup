#!/usr/bin/env bash
#
# Installs system-level tools that require root.
# Run as a sudo-capable user: sudo ./install-system-tools.sh
#
# Tools installed:
#   - zip / unzip
#   - apptainer  (requires SUID binary; must be system-level)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Common utilities
# ---------------------------------------------------------------------------
echo "==> Installing common utilities"
apt-get update -q
apt-get install -y zip unzip

# ---------------------------------------------------------------------------
# Apptainer
# ---------------------------------------------------------------------------
echo "==> Installing Apptainer"
add-apt-repository -y ppa:apptainer/ppa
apt-get update -q
apt-get install -y apptainer

echo
echo "Done."
