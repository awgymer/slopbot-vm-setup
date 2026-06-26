#!/usr/bin/env bash
#
# Installs system-level tools that require root.
# Run as a sudo-capable user: sudo ./install-system-tools.sh
#
# Tools installed:
#   - build-essential  (C toolchain required by Rust crates and other native builds)
#   - zip / unzip
#   - apptainer  (requires SUID binary; must be system-level)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Common utilities
# ---------------------------------------------------------------------------
echo "==> Installing common utilities"
apt-get update -q
apt-get install -y build-essential zip unzip

# ---------------------------------------------------------------------------
# Apptainer
# ---------------------------------------------------------------------------
echo "==> Installing Apptainer"
add-apt-repository -y ppa:apptainer/ppa
apt-get update -q
apt-get install -y apptainer

echo
echo "Done."
