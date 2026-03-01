# syntax=docker/dockerfile:1.7

FROM debian:trixie-slim

# Install runtime tools (nano, vim, nodejs, npm, etc.)
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
    && rm -rf /var/lib/apt/lists/*

# Download pre-built ZeroClaw binary from GitHub releases
ARG ZEROCLAW_VERSION=v0.1.7
RUN curl -fsSL "https://github.com/zeroclaw-labs/zeroclaw/releases/download/${ZEROCLAW_VERSION}/zeroclaw-x86_64-unknown-linux-gnu.tar.gz" \
    | tar -xz -C /usr/local/bin zeroclaw \
    && chmod +x /usr/local/bin/zeroclaw

# Configure npm to use persistent storage (survives redeploys)
ENV NPM_CONFIG_PREFIX=/data/.npm-global
ENV PATH="/data/.npm-global/bin:$PATH"

# Configure Homebrew to use persistent storage
ENV HOMEBREW_PREFIX=/data/.linuxbrew
ENV HOMEBREW_CELLAR=/data/.linuxbrew/Cellar
ENV HOMEBREW_REPOSITORY=/data/.linuxbrew/Homebrew
ENV PATH="/data/.linuxbrew/bin:/data/.linuxbrew/sbin:$PATH"

# Create data directory for persistent storage
RUN mkdir -p /data/.zeroclaw /data/.npm-global /data/.npm-cache /data/.linuxbrew

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

# Copy startup script and health server
COPY start.sh /app/start.sh
COPY health-server.js /app/health-server.js
RUN chmod +x /app/start.sh

# Set environment - HOME=/data makes ZeroClaw use /data/.zeroclaw
ENV HOME=/data
ENV SHELL=/bin/bash

# Expose gateway port
EXPOSE 8080

WORKDIR /data

CMD ["/app/start.sh"]
