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
    # Virtual desktop (Xvfb + Fluxbox + noVNC)
    xvfb \
    fluxbox \
    x11vnc \
    novnc \
    websockify \
    scrot \
    imagemagick \
    && rm -rf /var/lib/apt/lists/*

# Download pre-built ZeroClaw binary from fork releases (latest or pinned)
ARG ZEROCLAW_VERSION=""
ARG ZEROCLAW_REPO="1clawx/zeroclaw"
ARG TARGETARCH
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") && \
    if [ -z "$ZEROCLAW_VERSION" ]; then \
      ZEROCLAW_VERSION=$(curl -fsSL "https://api.github.com/repos/${ZEROCLAW_REPO}/releases/latest" | grep '"tag_name"' | cut -d'"' -f4); \
    fi && \
    echo "Installing zeroclaw ${ZEROCLAW_VERSION} from ${ZEROCLAW_REPO}" && \
    curl -fsSL --retry 3 --retry-delay 5 "https://github.com/${ZEROCLAW_REPO}/releases/download/${ZEROCLAW_VERSION}/zeroclaw-${ARCH}-unknown-linux-gnu.tar.gz" \
    | tar -xz -C /usr/local/bin zeroclaw \
    && chmod +x /usr/local/bin/zeroclaw

# Disable Claude Code auto-updater (installed conditionally at boot via start.sh)
ENV DISABLE_AUTOUPDATER=1

# Configure npm to use persistent storage (survives redeploys)
ENV NPM_CONFIG_PREFIX=/data/.npm-global
ENV PATH="/data/.npm-global/bin:$PATH"

# Pre-install Homebrew to persistent storage path (avoid 30-60s lazy install at boot)
ENV HOMEBREW_PREFIX=/data/.linuxbrew
ENV HOMEBREW_CELLAR=/data/.linuxbrew/Cellar
ENV HOMEBREW_REPOSITORY=/data/.linuxbrew/Homebrew
ENV PATH="/data/.linuxbrew/bin:/data/.linuxbrew/sbin:$PATH"

RUN mkdir -p /data/.linuxbrew/Homebrew \
    /data/.linuxbrew/bin \
    /data/.linuxbrew/etc \
    /data/.linuxbrew/include \
    /data/.linuxbrew/lib \
    /data/.linuxbrew/opt \
    /data/.linuxbrew/sbin \
    /data/.linuxbrew/share \
    /data/.linuxbrew/var && \
    git clone --depth=1 https://github.com/Homebrew/brew /data/.linuxbrew/Homebrew && \
    ln -sf /data/.linuxbrew/Homebrew/bin/brew /data/.linuxbrew/bin/brew

# Create data directories for persistent storage
RUN mkdir -p /data/.zeroclaw /data/.npm-global /data/.npm-cache

# Install agent-browser + Playwright browsers for browser automation
RUN NPM_CONFIG_PREFIX=/usr/local npm install -g agent-browser
ENV PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/playwright
RUN NPM_CONFIG_PREFIX=/usr/local npx playwright install --with-deps chromium

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

# Virtual display for browser & screenshot tools
ENV DISPLAY=:99
ENV SCREEN_WIDTH=1366
ENV SCREEN_HEIGHT=768
ENV SCREEN_DEPTH=24

# Expose ZeroClaw gateway port + noVNC web viewer
EXPOSE 8080 6080

WORKDIR /data

# No CMD — Railway's startCommand in railway.toml handles this.
# Having both CMD and startCommand can cause double execution.
