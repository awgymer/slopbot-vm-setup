# VM Setup for Autonomous AI Agents

Scripts to initialise an Ubuntu 26.04 VM for running autonomous AI agents (Claude Code).

## Overview

The setup is split into three scripts that must be run in order:

| Script | Run as | Purpose |
|--------|--------|---------|
| `scripts/install-system-tools.sh` | root | System-level tools that require a SUID binary (Apptainer), and the system timezone |
| `scripts/setup-ai-user.sh` | root | Creates and hardens an agent user |
| `scripts/setup-ubuntu-user.sh` | ubuntu | Sets up the interactive shell environment for the ubuntu user |

`scripts/sync-ai-user.sh` installs an agent user's dotfiles. `setup-ai-user.sh` calls it. Run it on its own to pick up repo changes later — see [Updating an agent user's dotfiles](#updating-an-agent-users-dotfiles).

## Usage

### 1. System tools (root)

```bash
sudo ./scripts/install-system-tools.sh
```

Installs Apptainer via the official PPA. Must be system-level because unprivileged user namespaces are disabled as part of the hardening in the next step.

The script also sets the system timezone. A new VM uses UTC. The default is `Australia/Adelaide`. To use a different zone, give `VM_TIMEZONE` to `sudo`:

```bash
sudo VM_TIMEZONE=Europe/London ./scripts/install-system-tools.sh
```

Run `timedatectl list-timezones` to see the valid names. Docker containers do not use the timezone of the host. Give the `TZ` environment variable to each container, as `.devcontainer/` does.

### 2. Agent user setup (root)

```bash
sudo ./scripts/setup-ai-user.sh claude
```

- Creates a non-privileged agent user with no sudo access. The name is required — `claude` unless you choose another
- Installs the agent user dotfiles, keeping any local changes
- Creates `/workspace`, owned by the agent user and the `workspace` group, mode 2770. A second agent user takes ownership of it, and shares it through the group
- Installs shared tools for the agent user (see below)
- Installs Claude Code via native installer
- Applies security hardening:
  - Disables unprivileged user namespaces
  - Blocks the cloud metadata endpoint (169.254.169.254) via nftables
  - Denies cron and at access

### 3. Ubuntu user setup (ubuntu user)

```bash
./scripts/setup-ubuntu-user.sh
```

Run from the repo root as the `ubuntu` user (not root). Sets up:

- zsh + Powerlevel10k prompt
- Dotfiles symlinked from `dotfiles/` into `~`
- Shared tools (see below)

After running, log out and back in, then run `p10k configure` to set up your prompt. A [Nerd Font](https://www.nerdfonts.com/) is required in your local terminal emulator for glyphs to render correctly.

## Shared tools (`install-user-tools.sh`)

Run automatically for both the `ubuntu` user and the agent user. Installs:

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
| `.zfuncs` | Shell functions — `become`, plus the `setup-ai-user` and `sync-ai-user` wrappers |
| `.screenrc` | GNU screen config — scrollback, status bar, keybindings |
| `.zlocal.example` | Template for machine-local secrets — copied to `~/.zlocal` automatically, never commit `~/.zlocal` |

`dotfiles-ai/` contains the agent user's config, installed into `~` by `sync-ai-user.sh`. `.example` files are skipped and serve as templates only:

| File | Purpose |
|------|---------|
| `.bashrc.local` | PATH, tool init, auto-cd to `/workspace`, sources `~/.bash_secrets` |
| `.gitconfig` | Git defaults (no user identity — set via `~/.bash_secrets`) |
| `.claude/CLAUDE.md` | Global agent guidelines — loaded by Claude Code for every session |
| `.bash_secrets.example` | Template for credentials — copy to `~/.bash_secrets` and fill in |

### Updating an agent user's dotfiles

The agent user gets copies, not symlinks, because this repo lives in the `ubuntu` home, which is mode `700`. To pick up repo changes on a VM that is already set up:

```bash
git pull
sudo ./scripts/sync-ai-user.sh --dry-run claude   # show what would change
sudo ./scripts/sync-ai-user.sh claude             # apply
```

The `.zfuncs` wrappers do the same from anywhere, and find the repo themselves:

```bash
sync-ai-user --dry-run claude
sync-ai-user --review bob
setup-ai-user bob                # create and harden a new one
```

Changes made on the VM are kept. `ucf` compares three versions — the one in the repo, the one it supplied last time, and the file on disk — which lets it tell a local change from an out-of-date file, and offer a three-way merge. This matters because `gh auth setup-git` writes credential settings into `~/.gitconfig` at each login.

| Result | What happens |
|--------|--------------|
| No local changes | The repo version is installed |
| Local changes | The file on disk stays. The repo version goes to `<file>.ucf-dist`, and the script lists it |
| Local changes, with `--review` | ucf asks what to do, offering a three-way merge. A merge that conflicts goes to `<file>.merge-error` and the file on disk stays |

A merge is never automatic — the default answer is always to keep the local file, so a run never blocks and never overwrites. Without `ucf` installed the behaviour is the same, minus the merge option.

To tell a local change from a file that is merely out of date, the file on disk is compared with every version of it in this repo's git history. A file matching any of them holds no local changes, so a VM set up before this script existed picks up the new version on its first run, with no prompt and nothing left to review.

One thing to note: `--dry-run` does not change the dotfiles, but ucf still writes the `.ucf-dist` copies.

### Resolving a conflict

A run that finds local changes keeps your file, and puts the repo version next to it:

```
==> These files have local changes and a newer version in the repo:
    diff /home/claude/.bashrc.local /home/claude/.bashrc.local.ucf-dist
```

To resolve it:

```bash
sudo -u claude diff /home/claude/.bashrc.local /home/claude/.bashrc.local.ucf-dist
sudo -u claude nano /home/claude/.bashrc.local   # take the changes you want
sudo rm /home/claude/.bashrc.local.ucf-dist
```

The next run is quiet, and the `.ucf-dist` file does not come back. The run above recorded the repo version as the one supplied, so your file can stay different from the repo for as long as you want.

For the same reason, the warning comes once. If you delete the `.ucf-dist` file without taking the changes, nothing tells you about them again. Keep it until you have finished with it.

With `--review`, a merge that works replaces your file, and saves the file from before the merge as `<file>.ucf-old`. A merge that conflicts writes `<file>.merge-error`, which holds the diff3 conflict markers, and leaves your file as it is.

#### Files left behind

| File | Written when |
|------|--------------|
| `<file>.ucf-dist` | Your version is kept. `--dry-run` writes these as well |
| `<file>.ucf-old` | A `--review` merge worked. Holds the file from before the merge |
| `<file>.merge-error` | A `--review` merge conflicted |

Each run lists the `.ucf-dist` and `.merge-error` files at the end. To find all three:

```bash
sudo find /home/claude \( -name '*.ucf-dist' -o -name '*.ucf-old' -o -name '*.merge-error' \)
```

A dotfile taken out of the repo is not removed from the VM. Remove it by hand, and take out the ucf record with it:

```bash
sudo ucf --purge /home/claude/.thefile
sudo rm /home/claude/.thefile
```

### Setting up credentials for the claude user

`setup-ai-user.sh` copies `.bash_secrets.example` to `~/.bash_secrets` automatically (if not already present). Edit it to fill in your values:

```bash
sudo -u claude nano /home/claude/.bash_secrets
```

The file is sourced on every login. When `GH_TOKEN` is set, `gh auth setup-git` is run automatically to configure git credential helpers.

## Security model

The hardening in `setup-ai-user.sh` reduces blast radius *inside* the VM. It does not make the account unescapable — the VM itself is the security boundary. Treat it as disposable and assume the agent could become root inside it.

For additional containment (resource limits, cgroup caps), see the commented-out section at the bottom of `setup-ai-user.sh`.
