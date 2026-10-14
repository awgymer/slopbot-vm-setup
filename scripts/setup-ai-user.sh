#!/usr/bin/env bash
#
# Sets up a locked-down, non-privileged user for running AI agents in a VM.
# Run as a sudo-capable user:  sudo ./setup-ai-user.sh <username>
#
# NOTE ON THREAT MODEL:
#   This script reduces blast radius *inside* the VM. It does NOT make the
#   account "unescapable" — that's a kernel/hypervisor property. Treat the VM
#   itself as the security boundary: keep it patched, treat it as disposable,
#   and assume the agent could become root inside it.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME="${1:-}"
if [[ -z "$USER_NAME" ]]; then
    echo "Usage: sudo $(basename "$0") <username>" >&2
    exit 2
fi
if [[ ! "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "ERROR: '${USER_NAME}' is not a valid user name" >&2
    exit 2
fi
WORKSPACE_ROOT="/workspace"
USER_HOME="/home/${USER_NAME}"
USER_WORKSPACE="${WORKSPACE_ROOT}/${USER_NAME}"

# ---------------------------------------------------------------------------
# Create user
# ---------------------------------------------------------------------------
echo "==> Creating user"
if ! id "$USER_NAME" &>/dev/null; then
    adduser --disabled-password --gecos "" "$USER_NAME"
fi

# ---------------------------------------------------------------------------
# Strip privileged groups (belt-and-suspenders; a fresh adduser has none of
# these, but this protects against re-runs on an account that gained them).
# ---------------------------------------------------------------------------
echo "==> Removing privileged groups"
for grp in sudo docker lxd libvirt kvm adm; do
    if getent group "$grp" >/dev/null; then
        gpasswd -d "$USER_NAME" "$grp" 2>/dev/null || true
    fi
done

# ---------------------------------------------------------------------------
# Check for sudoers entries (group removal above doesn't cover these)
# ---------------------------------------------------------------------------
echo "==> Checking sudoers for ${USER_NAME}"
SUDOERS_HITS="$(grep -rE "^\s*${USER_NAME}\s" /etc/sudoers /etc/sudoers.d/ 2>/dev/null || true)"
if [ -n "$SUDOERS_HITS" ]; then
    echo "WARNING: sudoers entries found for ${USER_NAME} — review and remove manually:" >&2
    echo "$SUDOERS_HITS" >&2
fi

# ---------------------------------------------------------------------------
# Workspace
#
# WORKSPACE_ROOT belongs to ubuntu and holds one directory per agent user.
# Each agent owns its own directory, with its own group. ubuntu joins that
# group, so ubuntu has full access to every workspace, and no agent can
# reach the workspace of another.
# ---------------------------------------------------------------------------
echo "==> Creating ${USER_WORKSPACE}"
mkdir -p "$WORKSPACE_ROOT"

# An earlier version of this script gave the root itself to one agent. Take
# it over only when it holds nothing but agent directories, so that files
# from such a VM are left for a person to move.
STRAY=""
while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name="$(basename "$entry")"
    if [[ ! -d "$entry" ]] || ! id "$name" &>/dev/null; then
        STRAY="${STRAY}    ${entry}"$'\n'
    fi
done < <(find "$WORKSPACE_ROOT" -mindepth 1 -maxdepth 1 2>/dev/null)

if [[ -n "$STRAY" ]]; then
    echo "WARNING: ${WORKSPACE_ROOT} holds things that are not agent directories:" >&2
    printf '%s' "$STRAY" >&2
    echo "         Leaving ${WORKSPACE_ROOT} as it is. Move them into" >&2
    echo "         ${USER_WORKSPACE}/ and run this script again." >&2
else
    if id ubuntu &>/dev/null; then
        chown ubuntu:ubuntu "$WORKSPACE_ROOT"
    fi
    chmod 755 "$WORKSPACE_ROOT"
fi

# adduser makes a group for each user, so this is the agent's own group.
USER_GROUP="$(id -gn "$USER_NAME")"
MEMBERS="$(getent group "$USER_GROUP" | cut -d: -f4)"
if [[ -n "${MEMBERS//ubuntu/}" ]]; then
    echo "WARNING: group '${USER_GROUP}' has other members (${MEMBERS})." >&2
    echo "         They will reach ${USER_WORKSPACE} as well." >&2
fi

mkdir -p "$USER_WORKSPACE"
chown "${USER_NAME}:${USER_GROUP}" "$USER_WORKSPACE"
# 2770: setgid so new files take the agent's group, which ubuntu is in;
#       owner rwx, group rwx, other none.
chmod 2770 "$USER_WORKSPACE"

# ubuntu joins the agent's group, for full access to that workspace.
# A login that is already open picks the group up at the next login.
if id ubuntu &>/dev/null; then
    usermod -aG "$USER_GROUP" ubuntu
fi

# ---------------------------------------------------------------------------
# Lock down the default ubuntu home (if present)
# ---------------------------------------------------------------------------
echo "==> Locking down ubuntu home"
if id ubuntu &>/dev/null; then
    chmod 700 /home/ubuntu
    if [ -d /home/ubuntu/.ssh ]; then
        chmod 700 /home/ubuntu/.ssh
        find /home/ubuntu/.ssh -type f -exec chmod 600 {} \;
    fi
fi

# ---------------------------------------------------------------------------
# Lock down the agent's own home + .ssh
#   FIX: also tighten the home dir itself to 700 (adduser leaves it 755),
#   so no other unprivileged user can read it.
# ---------------------------------------------------------------------------
echo "==> Creating directories for ${USER_NAME}"
chmod 700 "$USER_HOME"
mkdir -p "${USER_HOME}/.ssh"
chown -R "$USER_NAME:$USER_NAME" "${USER_HOME}/.ssh"
chmod 700 "${USER_HOME}/.ssh"
# No authorized_keys is written, so there is no direct SSH login path in.
# Access is intended via `su - ${USER_NAME}` from your sudo user.
# If you DO want key-based SSH, drop a public key here:
#   install -m 600 -o "$USER_NAME" -g "$USER_NAME" /path/to/key.pub \
#       "${USER_HOME}/.ssh/authorized_keys"

# ---------------------------------------------------------------------------
# Default shell
# ---------------------------------------------------------------------------
echo "==> Setting default shell (bash)"
usermod -s /bin/bash "$USER_NAME"

# ---------------------------------------------------------------------------
# Environment + interactive niceties
# ---------------------------------------------------------------------------
echo "==> Setting global WORKSPACE_ROOT env var"
if ! grep -q '^WORKSPACE_ROOT=' /etc/environment 2>/dev/null; then
    echo "WORKSPACE_ROOT=${WORKSPACE_ROOT}" >> /etc/environment
fi

# Dotfiles are copies, not symlinks, because this repo is in the ubuntu home,
# which is mode 700. The sync script backs up any local changes.
bash "${SCRIPT_DIR}/sync-ai-user.sh" "$USER_NAME"

# ---------------------------------------------------------------------------
# User-scoped tools (SDKMAN!, Java, uv, Nextflow, gh, nvm, Node, Rust)
# ---------------------------------------------------------------------------
echo "==> Installing user-scoped tools for ${USER_NAME}"
sudo -u "$USER_NAME" bash -c "cd '${USER_HOME}' && bash -s" < "${SCRIPT_DIR}/install-user-tools.sh"

# ---------------------------------------------------------------------------
# Claude Code (native installer — no npm required, auto-updates)
# ---------------------------------------------------------------------------
echo "==> Installing Claude Code for ${USER_NAME}"
if [[ ! -f "${USER_HOME}/.local/bin/claude" ]]; then
    sudo -u "$USER_NAME" bash -c "cd '${USER_HOME}' && curl -fsSL https://claude.ai/install.sh | bash"
else
    echo "    Already installed"
fi

# ===========================================================================
# HARDENING
# ===========================================================================

# --- 1. Disable unprivileged user namespaces ---------------------------------
# Prevents the agent using namespace tricks as a kernel escape vector.
# Apptainer (used for Nextflow container processes) works without this via
# its SUID helper binary — ensure Apptainer is installed from the official
# Ubuntu package so the SUID binary is present.
echo "==> Disabling unprivileged user namespaces"
cat > /etc/sysctl.d/99-agent-hardening.conf <<'EOF'
kernel.unprivileged_userns_clone = 0
EOF
sysctl --system -q

# --- 2. Cloud metadata endpoint block ----------------------------------------
# 169.254.169.254 is the instance metadata service on AWS, GCP, Azure and
# most other cloud providers. From inside the VM it serves IAM credentials
# with no authentication required — a direct cloud-escape vector.
# The IPv6 address is the AWS IMDSv2 equivalent (fd00:ec2::254).
#
# The drop rules match a set of agent UIDs, so every agent shares them. The
# base file makes the table, the set and the rules. Each agent has its own
# file that adds its UID to the set, and those files are the record of which
# agents exist. The include in nftables.conf loads them in name order: the
# base file (80) before the agent files (90). Adding a set element is
# idempotent, and the chain flush in the base file leaves the set alone.
echo "==> Blocking cloud metadata endpoint for ${USER_NAME}"
UID_NUM="$(id -u "$USER_NAME")"
NFT_DIR="/etc/nftables.d"
NFT_BASE="${NFT_DIR}/80-agentfilter.nft"
mkdir -p "$NFT_DIR"

cat > "$NFT_BASE" <<'EOF'
add table inet agentfilter
add set inet agentfilter agent_uids { typeof meta skuid; }
add chain inet agentfilter out { type filter hook output priority 0; policy accept; }
flush chain inet agentfilter out
add rule inet agentfilter out ip  daddr 169.254.169.254 meta skuid @agent_uids drop
add rule inet agentfilter out ip6 daddr fd00:ec2::254   meta skuid @agent_uids drop
EOF

cat > "${NFT_DIR}/90-agent-user-${USER_NAME}.nft" <<EOF
add element inet agentfilter agent_uids { ${UID_NUM} }
EOF

# Load only the drop-in files. nftables.conf starts with `flush ruleset`, so
# loading it would remove every other table, such as those of ufw or Docker.
nft -f "$NFT_BASE"
for f in "${NFT_DIR}"/90-agent-user-*.nft; do
    nft -f "$f"
done

if ! grep -q 'nftables.d' /etc/nftables.conf 2>/dev/null; then
    printf '\ninclude "/etc/nftables.d/*.nft"\n' >> /etc/nftables.conf
fi
systemctl enable nftables 2>/dev/null || true

# To also restrict outbound to specific subnets (e.g. block internal network),
# add to the base file:
# add rule inet agentfilter out ip daddr 10.0.0.0/8 meta skuid @agent_uids drop

# --- 3. Deny scheduled-job persistence ---------------------------------------
echo "==> Denying cron/at for ${USER_NAME}"
grep -qxF "$USER_NAME" /etc/cron.deny 2>/dev/null || echo "$USER_NAME" >> /etc/cron.deny
grep -qxF "$USER_NAME" /etc/at.deny   2>/dev/null || echo "$USER_NAME" >> /etc/at.deny
# Leave systemd user-lingering disabled (default). To be explicit:
loginctl disable-linger "$USER_NAME" 2>/dev/null || true

# ===========================================================================
# OPTIONAL HARDENING — uncomment to enable
# ===========================================================================

# --- Resource limits (stop fork bombs / RAM / disk exhaustion) ---------------
# echo "==> Applying resource limits"
# cat > /etc/security/limits.d/90-${USER_NAME}.conf <<EOF
# ${USER_NAME}  hard  nproc   512      # max processes
# ${USER_NAME}  hard  nofile  4096     # max open files
# ${USER_NAME}  hard  fsize   2097152  # max file size (~2 GB, in KB)
# ${USER_NAME}  hard  as      4194304  # max address space (~4 GB, in KB)
# EOF
#
# Stronger alternative: run the agent under a systemd slice with cgroup caps,
# e.g. systemd-run --uid=${USER_NAME} -p MemoryMax=4G -p TasksMax=512 \
#        -p CPUQuota=200% /path/to/agent

# ===========================================================================
# Verification
# ===========================================================================
echo
echo "==> Verification"
echo
id "$USER_NAME"
echo
echo "Groups:"
groups "$USER_NAME"
echo
echo "Shell:"
getent passwd "$USER_NAME" | cut -d: -f7
echo
echo "Home perms:"
ls -ld "$USER_HOME"
echo
echo "Workspace root:"
ls -ld "$WORKSPACE_ROOT"
echo
echo "Workspace for ${USER_NAME}:"
ls -ld "$USER_WORKSPACE"
echo
echo "Members of group ${USER_GROUP} (ubuntu should be one):"
getent group "$USER_GROUP" || echo "  (not found)"
echo
echo "WORKSPACE_ROOT env (global):"
grep '^WORKSPACE_ROOT=' /etc/environment || echo "  (not set)"
echo
echo "Unprivileged user namespaces:"
sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo "  (sysctl not available)"
echo
echo "nftables (metadata block):"
nft list chain inet agentfilter out 2>/dev/null || echo "  (not loaded)"
nft list set inet agentfilter agent_uids 2>/dev/null || echo "  (no agent_uids set)"
echo
echo "Agents with a metadata block (one file each — every agent should be listed):"
for f in "${NFT_DIR}"/90-agent-user-*.nft; do
    [[ -e "$f" ]] || { echo "  (none)"; break; }
    echo "  $(basename "$f" .nft | sed 's/^90-agent-user-//'): $(grep -oE '[0-9]+' "$f" | tail -n 1)"
done
echo
echo "Done."
