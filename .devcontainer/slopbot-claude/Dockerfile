FROM debian:12

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=stable
ARG GIT_DELTA_VERSION=0.18.2
ARG USERNAME=claude

# Install basic development tools and iptables/ipset
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  curl \
  wget \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install gh cli latest stable
RUN mkdir -p -m 755 /etc/apt/keyrings \
	&& out=$(mktemp) \
  && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
	&& cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
	&& chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
	&& mkdir -p -m 755 /etc/apt/sources.list.d \
	&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
	&& apt-get update \
	&& apt-get install gh -y

# Create claude user
RUN useradd -m -s /bin/zsh $USERNAME

# Persist bash history
RUN mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions
RUN mkdir -p /workspace /home/$USERNAME/.claude && \
  chown -R $USERNAME:$USERNAME /workspace /home/$USERNAME/.claude

WORKDIR /workspace

# Install git-delta
RUN ARCH=$(dpkg --print-architecture) && \
  curl -fsSL "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" \
    -o /tmp/git-delta.deb && \
  dpkg -i /tmp/git-delta.deb && \
  rm /tmp/git-delta.deb


# ── Optional tool installers (root phase) ─────────────────────────────
ARG NEXTFLOW_VERSION=25.10.4
COPY installers /tmp/installers
RUN NEXTFLOW_VERSION="$NEXTFLOW_VERSION" \
    bash /tmp/installers/install-root.sh


COPY --chown=$USERNAME:$USERNAME zshrc /home/$USERNAME/.zshrc
COPY --chown=$USERNAME:$USERNAME p10k.zsh /home/$USERNAME/.p10k.zsh
COPY --chown=$USERNAME:$USERNAME gitconfig /home/$USERNAME/.gitconfig

USER $USERNAME
ENV HOME=/home/$USERNAME

# Install Claude Code
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}"


# ── Optional tool installers (user phase) ─────────────────────────────
ARG NODE_VERSION=22
ARG NFCORE_VERSION=3.5.1
ARG NFT_VERSION=0.9.5
RUN NODE_VERSION="$NODE_VERSION" \
    NFCORE_VERSION="$NFCORE_VERSION" \
    NFT_VERSION="$NFT_VERSION" \
    bash /tmp/installers/install-user.sh


ENV SHELL=/bin/zsh

# Install powerlevel10k theme
RUN git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ~/powerlevel10k

# Copy and set up firewall and startup scripts
COPY init-firewall.sh startup.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/startup.sh && \
  echo "$USERNAME ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/$USERNAME-firewall && \
  chmod 0440 /etc/sudoers.d/$USERNAME-firewall

USER $USERNAME
