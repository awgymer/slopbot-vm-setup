#!/usr/bin/env bash
#
# Installs user-scoped tools for the current user.
# Run as the target user — called for both ubuntu and claude.
#
# Tools installed:
#   - SDKMAN! + Java (LTS)
#   - uv
#   - Nextflow
#   - gh CLI
#   - nvm + Node LTS
#   - Rust (rustup)
#
set -euo pipefail

LOCAL_BIN="${HOME}/.local/bin"
mkdir -p "$LOCAL_BIN"

# ---------------------------------------------------------------------------
# SDKMAN! + Java
# ---------------------------------------------------------------------------
echo "==> Installing SDKMAN!"
if [[ ! -d "${HOME}/.sdkman" ]]; then
    SDKMAN_CONFIGURE_PROFILE=false curl -s "https://get.sdkman.io" | bash
else
    echo "    Already present"
fi
source "${HOME}/.sdkman/bin/sdkman-init.sh"

echo "==> Installing Java"
if ! sdk current java &>/dev/null; then
    SDKMAN_AUTO_ANSWER=true sdk install java
else
    echo "    Already installed: $(sdk current java)"
fi

# ---------------------------------------------------------------------------
# uv
# ---------------------------------------------------------------------------
echo "==> Installing uv"
if ! command -v uv &>/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh -s -- --no-modify-path
else
    echo "    Already installed: $(uv --version)"
fi

# ---------------------------------------------------------------------------
# Nextflow
# ---------------------------------------------------------------------------
echo "==> Installing Nextflow"
if [[ ! -f "${LOCAL_BIN}/nextflow" ]]; then
    TMP=$(mktemp -d)
    (cd "$TMP" && curl -s https://get.nextflow.io | bash)
    mv "${TMP}/nextflow" "${LOCAL_BIN}/"
    chmod +x "${LOCAL_BIN}/nextflow"
    rm -rf "$TMP"
else
    echo "    Already installed: $(nextflow -version 2>&1 | head -1)"
fi

# ---------------------------------------------------------------------------
# gh CLI
# ---------------------------------------------------------------------------
echo "==> Installing gh"
if [[ ! -f "${LOCAL_BIN}/gh" ]]; then
    GH_VERSION=$(curl -s https://api.github.com/repos/cli/cli/releases/latest \
        | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    ARCH=$(dpkg --print-architecture)
    TMP=$(mktemp -d)
    curl -L "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.tar.gz" \
        | tar -xz -C "$TMP"
    mv "${TMP}/gh_${GH_VERSION}_linux_${ARCH}/bin/gh" "${LOCAL_BIN}/"
    rm -rf "$TMP"
else
    echo "    Already installed: $(gh --version | head -1)"
fi

# ---------------------------------------------------------------------------
# nvm + Node LTS
# ---------------------------------------------------------------------------
echo "==> Installing nvm"
NVM_VERSION=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest \
    | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
NVM_DIR="${HOME}/.nvm"
if [[ ! -d "$NVM_DIR" ]]; then
    curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" \
        | PROFILE=/dev/null bash
else
    echo "    Already present"
fi

echo "==> Installing Node LTS"
source "${NVM_DIR}/nvm.sh"
nvm install --lts

# ---------------------------------------------------------------------------
# Rust (rustup)
# ---------------------------------------------------------------------------
echo "==> Installing Rust"
if [[ ! -d "${HOME}/.cargo" ]]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --no-modify-path
else
    echo "    Already installed: $(${HOME}/.cargo/bin/rustup --version 2>/dev/null | head -1)"
fi

# ---------------------------------------------------------------------------
echo
echo "Done. Tools installed to ${LOCAL_BIN} and ~/.sdkman."
echo "Ensure ~/.local/bin is on your PATH."
