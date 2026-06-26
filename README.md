# VM Setup for Autonomous AI Agents

Scripts to initialise an Ubuntu 26.04 VM for running autonomous AI agents (Claude Code).

## Overview

The setup is split into three scripts that must be run in order:

| Script | Run as | Purpose |
|--------|--------|---------|
| `install-system-tools.sh` | root | System-level tools that require a SUID binary (Apptainer) |
| `setup-ai-user.sh` | root | Creates and hardens the `claude` agent user |
| `setup-ubuntu-user.sh` | ubuntu | Sets up the interactive shell environment for the ubuntu user |

## Usage

### 1. System tools (root)

```bash
sudo ./install-system-tools.sh
```

Installs Apptainer via the official PPA. Must be system-level because unprivileged user namespaces are disabled as part of the hardening in the next step.

### 2. Agent user setup (root)

```bash
sudo ./setup-ai-user.sh
```

- Creates a non-privileged `claude` user with no sudo access
- Creates `/workspace` (owned by `claude`, mode 700)
- Installs shared tools for the `claude` user (see below)
- Installs Claude Code via native installer
- Applies security hardening:
  - Disables unprivileged user namespaces
  - Blocks the cloud metadata endpoint (169.254.169.254) via nftables
  - Denies cron and at access

### 3. Ubuntu user setup (ubuntu user)

```bash
./setup-ubuntu-user.sh
```

Run from the repo root as the `ubuntu` user (not root). Sets up:

- zsh + Powerlevel10k prompt
- Dotfiles symlinked from `dotfiles/` into `~`
- Shared tools (see below)

After running, log out and back in, then run `p10k configure` to set up your prompt. A [Nerd Font](https://www.nerdfonts.com/) is required in your local terminal emulator for glyphs to render correctly.

## Shared tools (`install-user-tools.sh`)

Run automatically for both the `ubuntu` and `claude` users. Installs:

- **SDKMAN! + Java LTS** — user-scoped JVM version management
- **uv** — Python package/project manager
- **Nextflow** — workflow orchestration
- **gh** — GitHub CLI
- **nvm + Node LTS** — Node version management
- **Rust** — via rustup

All tools are installed to `~/.local/bin`, `~/.sdkman`, `~/.nvm`, or `~/.cargo` — no root required and no system paths modified.

## Dotfiles

`dotfiles/` contains the ubuntu user's shell config, symlinked into `~` by `setup-ubuntu-user.sh`:

| File | Purpose |
|------|---------|
| `.zshrc` | Main zsh config — tools, completions, p10k |
| `.zaliases` | Shell and git aliases |
| `.zlocal.example` | Template for machine-local secrets (copy to `~/.zlocal`, never commit) |

`dotfiles-claude/` contains the `claude` user's bash config, copied into `~` by `setup-ai-user.sh`:

| File | Purpose |
|------|---------|
| `.bashrc.local` | PATH, tool init, auto-cd to `/workspace` |

## Security model

The hardening in `setup-ai-user.sh` reduces blast radius *inside* the VM. It does not make the account unescapable — the VM itself is the security boundary. Treat it as disposable and assume the agent could become root inside it.

For additional containment (resource limits, cgroup caps), see the commented-out section at the bottom of `setup-ai-user.sh`.
