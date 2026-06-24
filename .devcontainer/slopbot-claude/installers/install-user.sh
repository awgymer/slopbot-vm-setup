#!/usr/bin/env bash
# User-phase installers. Invoked from the Dockerfile while USER=$USERNAME.
set -euo pipefail
IFS=$'\n\t'


# ── uv ────────────────────────────────────────────────────────────────
curl -LsSf https://astral.sh/uv/install.sh | sh
# Make uv visible to later steps in this script (non-interactive shell).
export PATH="$HOME/.local/bin:$PATH"













