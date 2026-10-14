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
- Installs the agent user dotfiles, backing up any local changes
- Creates `/workspace/<username>`, owned by the agent user and its own group, mode 2770. `/workspace` itself belongs to `ubuntu`
- Adds `ubuntu` to the agent group, so `ubuntu` has full access to every agent workspace while no agent can reach another one
- Installs shared tools for the agent user (see below)
- Installs Claude Code via native installer
- Applies security hardening:
  - Disables unprivileged user namespaces, with `kernel.unprivileged_userns_clone` and the AppArmor keys `kernel.apparmor_restrict_unprivileged_userns` and `kernel.apparmor_restrict_unprivileged_unconfined`. Only the keys that the kernel has are written
  - Blocks the cloud metadata endpoint (169.254.169.254) via nftables, for every agent user. Each agent has a file `/etc/nftables.d/90-agent-user-<username>.nft` that adds its UID to the blocked set. To remove an agent, delete its file and run `sudo nft delete element inet agentfilter agent_uids '{ <uid> }'`
  - Denies cron and at access
  - Hides the processes of other users. `/proc` is mounted with `hidepid=invisible`, so an agent sees only its own processes in `ps`. Root and the `adm` group see everything, and `ubuntu` is added to `adm`. The setting is written to `/etc/fstab`, and a login that is already open picks up the group at the next login
  - Gives each agent a private `/tmp` and `/var/tmp`. `pam_namespace` mounts an instance of each over the real one for every session of a listed agent. Only agents are listed, in `/etc/security/namespace.d/agent-users.conf`, which the script rebuilds from the metadata files on every run. `ubuntu` and root keep the real directories and can look into an instance at `/tmp/.inst/<username>`. The module is added to `common-session` through a `pam-auth-update` profile
  - Gives the agent its own network namespace, so it cannot reach the local services of other agents or of the VM — see [Network namespaces](#network-namespaces)

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
| `.bashrc.local` | PATH, tool init, auto-cd to `$WORKSPACE_ROOT/<username>`, sources `~/.bash_secrets` |
| `.config/git/config` | Git defaults (no user identity — set via `~/.bash_secrets`). `~/.gitconfig` is left to the VM — see below |
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

Every run installs the repo version of each file. A file you changed on the VM is moved to a backup folder first, so nothing is lost and nothing asks questions. `--dry-run` changes nothing.

The script reads and writes the home directory as the agent user, not as root. A symlink that the agent puts in its home cannot make the script write outside the home.

To tell a local change from a file that is only out of date, the script keeps a copy of each version it installs, in `/var/lib/slopbot/dotfiles/<user>/`.

| Result | What happens |
|--------|--------------|
| No local changes | The repo version is installed |
| Local changes | The file moves to `~/.dotfile-backups/<date>/`, next to `<file>.base`, the version you changed. The repo version is installed |
| No copy kept yet — the first run on a VM set up before this script | As for local changes, since the two cannot be told apart. This happens once per file |
| File deleted on the VM | The repo version is installed again |

Each run lists what it backed up, with a `diff` command for each file. Only the 2 newest backup folders are kept (`BACKUP_KEEP` in the script).

To take your changes into the new version:

```bash
B=/home/claude/.dotfile-backups/<date>
sudo -u claude diff $B/.bashrc.local /home/claude/.bashrc.local
sudo -u claude nano /home/claude/.bashrc.local   # copy across what you want
```

Or merge the three versions — yours, the one you changed, and the new one — with `git merge-file`. Conflicts are marked in the file, as in a git merge:

```bash
sudo -u claude git merge-file -p $B/.bashrc.local $B/.bashrc.local.base /home/claude/.bashrc.local > merged
```

#### `~/.gitconfig`

`~/.gitconfig` belongs to the VM, not the repo. `.bashrc.local` runs `gh auth setup-git` at each login, which writes credential settings into it. The repo's git settings go to `~/.config/git/config` instead. Git reads both, and settings in `~/.gitconfig` win.

The first run on a VM set up before this change backs up `~/.gitconfig` and leaves it empty, because it still holds the old repo settings, which would override the new file. `gh auth setup-git` puts its settings back at the next login.

#### Removing a dotfile

A dotfile taken out of the repo is not removed from the VM. Remove it by hand, with the copy the script keeps:

```bash
sudo rm /home/claude/.thefile /var/lib/slopbot/dotfiles/claude/.thefile
```

### Workspaces

Each agent user gets its own directory. `WORKSPACE_ROOT` is set in `/etc/environment`, and each agent shell sets `WORKSPACE` from it:

```
/workspace              ubuntu:ubuntu    755
/workspace/claude       claude:claude    2770
/workspace/bob          bob:bob          2770
```

`ubuntu` is a member of the `claude` and `bob` groups, so it can read and write both. `claude` is not in `bob`'s group, so the agents are kept apart. The setgid bit makes new files take the directory group, and the agent's `umask 007` leaves them writable by that group.

A new group takes effect at the next login, so log out and back in after adding an agent.

On a VM set up by an earlier version, `/workspace` belongs to one agent and holds its files. The script does not take the directory over while anything other than agent directories is in it. Move the files into `/workspace/<username>/` first, then run it again.

### Setting up credentials for the claude user

`setup-ai-user.sh` copies `.bash_secrets.example` to `~/.bash_secrets` automatically (if not already present). Edit it to fill in your values:

```bash
sudo -u claude nano /home/claude/.bash_secrets
```

The file is sourced on every login. When `GH_TOKEN` is set, `gh auth setup-git` is run automatically to configure git credential helpers.

### Network namespaces

Without a namespace, every user on the VM shares the loopback address and the VM address. One agent can connect to a dev server, a Jupyter kernel or an MCP server that another agent started, and can list them with `ss`. So each agent runs in its own network namespace, with its own loopback.

`setup-ai-user.sh` installs `scripts/agent-netns.sh` as `/usr/local/sbin/agent-netns`, and a systemd unit `agent-netns@<username>` that makes the namespace at boot. Each agent gets a /24 under `10.200.0.0/16`:

```
agent-claude    eth0 10.200.1.2  <->  veth-agent1 10.200.1.1 on the VM
agent-bob       eth0 10.200.2.2  <->  veth-agent2 10.200.2.1 on the VM
```

The VM forwards and masquerades the traffic of the agents. The nftables rules in `/etc/nftables.d/80-agentfilter.nft` drop traffic between agents, drop traffic from an agent to the VM except DNS, and block the cloud metadata endpoint on that path too. `systemd-resolved` answers DNS for the agents on `10.200.0.1`.

`become` enters the namespace when one exists for the user, so `become claude` has the network of the agent. A shell started another way, such as `sudo -iu claude`, has the network of the VM and only the metadata block applies to it.

The agent side is reachable from the VM. To open a dev server that `claude` runs on port 8000:

```bash
curl http://10.200.1.2:8000
```

To manage the namespaces:

```bash
sudo agent-netns status                        # every agent, up or down, with its address
sudo systemctl restart agent-netns@claude      # remake the namespace
sudo systemctl disable --now agent-netns@bob   # remove it, now and at boot
sudo rm /etc/slopbot/netns/bob                 # free the subnet of a removed agent
```

`agent-netns down <username>` removes a namespace by hand, but the unit makes it again at the next boot.

The subnet is `10.200.0.0/16` by default. If that clashes with your network, give `AGENT_NET_PREFIX` to the first run: `sudo AGENT_NET_PREFIX=10.201 ./scripts/setup-ai-user.sh claude`. The value is kept in `/etc/default/agent-netns` and wins after that.

Known limits:

- The agents have IPv4 only.
- If `ufw` is active, its default forward policy is `DROP`, which stops the agents. Set `DEFAULT_FORWARD_POLICY="ACCEPT"` in `/etc/default/ufw`, or add route rules for the agent subnet. The script warns when it sees `ufw` active.
- To let an agent reach a service on the VM, such as a model server, add an accept rule for that port before the final drop in the `in` chain of the base file.

## Security model

The hardening in `setup-ai-user.sh` reduces blast radius *inside* the VM. It does not make the account unescapable — the VM itself is the security boundary. Treat it as disposable and assume the agent could become root inside it.

For additional containment (resource limits, cgroup caps), see the commented-out section at the bottom of `setup-ai-user.sh`.
