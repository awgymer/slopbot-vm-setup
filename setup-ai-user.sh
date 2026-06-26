#!/usr/bin/env bash
#
# Sets up a locked-down, non-privileged user for running AI agents in a VM.
# Run as a sudo-capable user (e.g. `sudo ./setup-ai-user.sh`).
#
# NOTE ON THREAT MODEL:
#   This script reduces blast radius *inside* the VM. It does NOT make the
#   account "unescapable" — that's a kernel/hypervisor property. Treat the VM
#   itself as the security boundary: keep it patched, treat it as disposable,
#   and assume the agent could become root inside it.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME="claude"
WORKSPACE="/workspace"
USER_HOME="/home/${USER_NAME}"

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
# ---------------------------------------------------------------------------
echo "==> Creating workspace"
mkdir -p "$WORKSPACE"
chown "$USER_NAME:$USER_NAME" "$WORKSPACE"
chmod 700 "$WORKSPACE"

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
echo "==> Creating claude directories"
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
echo "==> Setting global WORKSPACE env var"
if ! grep -q '^WORKSPACE=' /etc/environment 2>/dev/null; then
    echo "WORKSPACE=${WORKSPACE}" >> /etc/environment
fi

echo "==> Installing dotfiles for ${USER_NAME}"
for src in "${SCRIPT_DIR}/dotfiles-claude"/.*; do
    name="$(basename "$src")"
    [[ "$name" == "." || "$name" == ".." ]] && continue
    [[ "$name" == *.example ]] && continue
    install -m 644 -o "$USER_NAME" -g "$USER_NAME" "$src" "${USER_HOME}/${name}"
    echo "    ${USER_HOME}/${name}"
done

# Source it from .bashrc (only matters interactively, which is fine here).
#   FIX: if .bashrc had to be created by this append, it would be root-owned;
#   chown afterward to guarantee correct ownership.
if ! grep -q 'bashrc.local' "${USER_HOME}/.bashrc" 2>/dev/null; then
    echo 'source ~/.bashrc.local' >> "${USER_HOME}/.bashrc"
fi
chown "$USER_NAME:$USER_NAME" "${USER_HOME}/.bashrc"

# ---------------------------------------------------------------------------
# User-scoped tools (SDKMAN!, Java, uv, Nextflow, gh, nvm, Node, Rust)
# ---------------------------------------------------------------------------
echo "==> Installing user-scoped tools for ${USER_NAME}"
sudo -u "$USER_NAME" bash "${SCRIPT_DIR}/install-user-tools.sh"

# ---------------------------------------------------------------------------
# Claude Code (native installer — no npm required, auto-updates)
# ---------------------------------------------------------------------------
echo "==> Installing Claude Code for ${USER_NAME}"
if [[ ! -f "${USER_HOME}/.local/bin/claude" ]]; then
    sudo -u "$USER_NAME" bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
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
echo "==> Blocking cloud metadata endpoint for ${USER_NAME}"
UID_NUM="$(id -u "$USER_NAME")"
nft add table inet agentfilter 2>/dev/null || true
nft add chain inet agentfilter out '{ type filter hook output priority 0; policy accept; }' 2>/dev/null || true
nft flush chain inet agentfilter out 2>/dev/null || true
nft add rule inet agentfilter out ip  daddr 169.254.169.254 meta skuid "$UID_NUM" drop
nft add rule inet agentfilter out ip6 daddr fd00:ec2::254   meta skuid "$UID_NUM" drop

# Persist across reboots via a nftables drop-in file.
# The imperative 'add/flush' form is idempotent if the service restarts.
mkdir -p /etc/nftables.d
cat > /etc/nftables.d/90-agent-metadata.nft <<EOF
add table inet agentfilter
add chain inet agentfilter out { type filter hook output priority 0; policy accept; }
flush chain inet agentfilter out
add rule inet agentfilter out ip  daddr 169.254.169.254 meta skuid ${UID_NUM} drop
add rule inet agentfilter out ip6 daddr fd00:ec2::254   meta skuid ${UID_NUM} drop
EOF
if ! grep -q 'nftables.d' /etc/nftables.conf 2>/dev/null; then
    printf '\ninclude "/etc/nftables.d/*.nft"\n' >> /etc/nftables.conf
fi
systemctl enable nftables 2>/dev/null || true

# To also restrict outbound to specific subnets (e.g. block internal network):
# nft add rule inet agentfilter out ip daddr 10.0.0.0/8 meta skuid "$UID_NUM" drop

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
echo "Workspace:"
ls -ld "$WORKSPACE"
echo
echo "WORKSPACE env (global):"
grep '^WORKSPACE=' /etc/environment || echo "  (not set)"
echo
echo "Unprivileged user namespaces:"
sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo "  (sysctl not available)"
echo
echo "nftables (metadata block):"
nft list chain inet agentfilter out 2>/dev/null || echo "  (not loaded)"
echo
echo "Done."