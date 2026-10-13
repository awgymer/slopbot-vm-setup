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
sync-ai-user bob
setup-ai-user bob                # create and harden a new one
```

Both scripts need `ucf`, which `install-system-tools.sh` installs, and both must be run from a terminal, because ucf may ask questions. `--dry-run` asks nothing and changes nothing.

Changes made on the VM are kept. `ucf` compares three versions — the one in the repo, the one it supplied last time, and the file on disk — which lets it tell a local change from an out-of-date file, and offer a three-way merge. This matters because `gh auth setup-git` writes credential settings into `~/.gitconfig` at each login.

| Result | What happens |
|--------|--------------|
| No local changes | The repo version is installed |
| Local changes, and no new repo version | Nothing — your file stays as it is |
| Local changes, and a new repo version | ucf asks what to do — see [Answering ucf](#answering-ucf) |
| File deleted on the VM | The repo version is installed again. To remove a dotfile for good, take it out of the repo — see [Removing a dotfile](#removing-a-dotfile) |

### Answering ucf

When a file has local changes and the repo has a new version, ucf asks what to do with it. ucf is made for Debian packages, so it calls the repo version "the package maintainer's version". The choices are:

| Choice | What happens |
|--------|--------------|
| Keep the local version currently installed | Your file stays. The repo version is saved as `<file>.ucf-dist` for reference. This is the default |
| Install the package maintainer's version | The repo version is installed. Your file is saved as `<file>.ucf-old` |
| Show the differences, side by side, or 3-way | Shows a diff, or a three-way diff, then asks again |
| Do a 3-way merge between available versions | Merges your changes into the repo version. If it works, your old file is saved as `<file>.ucf-old`. If it conflicts, the result goes to `<file>.merge-error` with diff3 conflict markers, your file stays as it is, and ucf asks again |
| Start a new shell to examine the situation | Opens a shell to look at the files, then asks again |

Whatever you choose is recorded, and ucf does not ask about that file again until the repo version changes again. If you keep your version and want some of the repo changes as well, copy them in by hand from `<file>.ucf-dist`.

On a VM set up before ucf was used, there is no record of the version supplied last. The first run asks about every file that differs from the repo, without the merge choice, because a merge needs that record. From the next run on, the merge is there.

#### Files left behind

| File | Written when |
|------|--------------|
| `<file>.ucf-dist` | You kept your version. Holds the repo version |
| `<file>.ucf-old` | The repo version or a merge was installed. Holds your file from before |
| `<file>.merge-error` | A merge conflicted |

Each run lists these at the end. Delete each one when you are done with it.

#### Removing a dotfile

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
