# syntax=docker/dockerfile:1.7

FROM debian:trixie-slim

# Install runtime tools + gettext-base (envsubst) + python3 + common CLI utils
RUN apt-get update && apt-get install -y \
    nano \
    vim \
    git \
    build-essential \
    procps \
    file \
    curl \
    wget \
    jq \
    ca-certificates \
    nodejs \
    npm \
    gettext-base \
    python3 \
    python3-pip \
    python3-venv \
    unzip \
    zip \
    less \
    htop \
    tree \
    tmux \
    rsync \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Download pre-built ZeroClaw binary from GitHub releases
ARG ZEROCLAW_VERSION=v0.1.7
ARG TARGETARCH
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") && \
    curl -fsSL "https://github.com/zeroclaw-labs/zeroclaw/releases/download/${ZEROCLAW_VERSION}/zeroclaw-${ARCH}-unknown-linux-gnu.tar.gz" \
    | tar -xz -C /usr/local/bin zeroclaw \
    && chmod +x /usr/local/bin/zeroclaw

# Configure npm to use persistent storage (survives redeploys)
ENV NPM_CONFIG_PREFIX=/data/.npm-global
ENV PATH="/data/.npm-global/bin:$PATH"

# Pre-install Homebrew to persistent storage path (avoid 30-60s lazy install at boot)
ENV HOMEBREW_PREFIX=/data/.linuxbrew
ENV HOMEBREW_CELLAR=/data/.linuxbrew/Cellar
ENV HOMEBREW_REPOSITORY=/data/.linuxbrew/Homebrew
ENV PATH="/data/.linuxbrew/bin:/data/.linuxbrew/sbin:$PATH"

RUN mkdir -p /data/.linuxbrew/Homebrew /data/.linuxbrew/{bin,etc,include,lib,opt,sbin,share,var} && \
    git clone --depth=1 https://github.com/Homebrew/brew /data/.linuxbrew/Homebrew && \
    ln -sf /data/.linuxbrew/Homebrew/bin/brew /data/.linuxbrew/bin/brew

# Create data directories for persistent storage
RUN mkdir -p /data/.zeroclaw /data/.npm-global /data/.npm-cache

# Add shell aliases for faster typing
RUN echo '# ZeroClaw aliases' >> /etc/bash.bashrc && \
    echo 'alias zc="zeroclaw"' >> /etc/bash.bashrc && \
    echo 'alias zrc="nano /data/.zeroclaw/config.toml"' >> /etc/bash.bashrc && \
    echo 'alias zst="zeroclaw status"' >> /etc/bash.bashrc && \
    echo 'alias zag="zeroclaw agent"' >> /etc/bash.bashrc && \
    echo 'alias zch="zeroclaw channel"' >> /etc/bash.bashrc && \
    echo 'alias npm-global="npm install -g"' >> /etc/bash.bashrc && \
    echo 'alias npx-install="npx install -g"' >> /etc/bash.bashrc && \
    echo 'alias brew-install="brew install"' >> /etc/bash.bashrc && \
    echo 'eval "$(/data/.linuxbrew/bin/brew shellenv)"' >> /etc/bash.bashrc

# Copy config templates + startup script
COPY templates/ /app/templates/
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# Set environment - HOME=/data makes ZeroClaw use /data/.zeroclaw
ENV HOME=/data
ENV SHELL=/bin/bash

# Expose ZeroClaw gateway port
EXPOSE 8080

WORKDIR /data

# No CMD — Railway's startCommand in railway.toml handles this.
# Having both CMD and startCommand can cause double execution.
