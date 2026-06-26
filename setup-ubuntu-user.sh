#!/usr/bin/env bash
#
# Sets up the ubuntu user's interactive shell environment.
# Run as the ubuntu user from the root of this repo:
#   ./setup-ubuntu-user.sh
#
# What it does:
#   - Installs zsh
#   - Clones Powerlevel10k
#   - Symlinks dotfiles from this repo into ~
#   - Sets zsh as the default shell
#
# After running, log out and back in, then run `p10k configure` to set up
# your prompt. You'll need a Nerd Font in your terminal emulator locally
# for the glyphs to render correctly.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="${SCRIPT_DIR}/dotfiles"

# ---------------------------------------------------------------------------
# Install zsh
# ---------------------------------------------------------------------------
echo "==> Installing zsh"
sudo apt-get update -q
sudo apt-get install -y zsh

# ---------------------------------------------------------------------------
# Powerlevel10k
# ---------------------------------------------------------------------------
echo "==> Installing Powerlevel10k"
P10K_DIR="${HOME}/powerlevel10k"
if [[ -d "$P10K_DIR" ]]; then
    echo "    Already present — pulling latest"
    git -C "$P10K_DIR" pull --ff-only
else
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
fi

# ---------------------------------------------------------------------------
# Symlink dotfiles
# ---------------------------------------------------------------------------
echo "==> Symlinking dotfiles"
for src in "${DOTFILES_DIR}"/.*; do
    name="$(basename "$src")"
    [[ "$name" == "." || "$name" == ".." ]] && continue
    dest="${HOME}/${name}"
    if [[ -e "$dest" && ! -L "$dest" ]]; then
        echo "    Backing up existing ${dest} -> ${dest}.bak"
        mv "$dest" "${dest}.bak"
    fi
    ln -sfn "$src" "$dest"
    echo "    ${dest} -> ${src}"
done

# ---------------------------------------------------------------------------
# Default shell
# ---------------------------------------------------------------------------
echo "==> Setting zsh as default shell"
ZSH_BIN="$(which zsh)"
if [[ "$(getent passwd "$USER" | cut -d: -f7)" != "$ZSH_BIN" ]]; then
    sudo chsh -s "$ZSH_BIN" "$USER"
else
    echo "    Already set"
fi

# ---------------------------------------------------------------------------
echo
echo "Done. Log out and back in to start using zsh."
echo "Then run: p10k configure"
