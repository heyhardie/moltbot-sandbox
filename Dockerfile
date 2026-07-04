FROM docker.io/cloudflare/sandbox:0.7.20

# Install Node.js 22 (required by OpenClaw)
# The base image has Node 20, we need to replace it with Node 22
# Using direct binary download for reliability
# Note: rclone is no longer needed — persistence uses Sandbox SDK backup/restore API
ENV NODE_VERSION=22.22.1
RUN ARCH="$(dpkg --print-architecture)" \
    && case "${ARCH}" in \
         amd64) NODE_ARCH="x64" ;; \
         arm64) NODE_ARCH="arm64" ;; \
         *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;; \
       esac \
    && apt-get update && apt-get install -y xz-utils ca-certificates \
    && rm -rf /usr/local/lib/node_modules /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
    && curl -fsSLk https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz -o /tmp/node.tar.xz \
    && rm -rf /usr/local/lib/node_modules /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && node --version \
    && npm --version

# Install OpenClaw
# Pin to specific version for reproducible builds
RUN npm install -g openclaw@2026.6.11 \
    && openclaw --version

# Use /home/openclaw as the home directory instead of /root.
# The Sandbox SDK backup API only allows directories under /home, /workspace,
# /tmp, or /var/tmp — not /root.
ENV HOME=/home/openclaw
# NOTE: the base image already ships /root/.openclaw (containing state/), so
# a plain `ln -s /home/openclaw/.openclaw /root/.openclaw` lands INSIDE it as
# /root/.openclaw/.openclaw instead of replacing it. Guard the link creation
# so it either becomes a real symlink or is skipped; nothing may rely on
# /root/.openclaw resolving to the config dir.
RUN mkdir -p /home/openclaw/.openclaw \
    && mkdir -p /home/openclaw/clawd \
    && mkdir -p /home/openclaw/clawd/skills \
    && rm -f /root/.openclaw/.openclaw \
    && { [ -e /root/.openclaw ] || ln -s /home/openclaw/.openclaw /root/.openclaw; } \
    && { [ -e /root/clawd ] || ln -s /home/openclaw/clawd /root/clawd; }

# Discord channel support is a separate plugin as of openclaw 2026.6.x
# (no longer bundled with the core npm package). Installed at build time
# into ~/.openclaw so it survives container rebuilds; enabled via config
# in start-openclaw.sh.
RUN openclaw plugins install @openclaw/discord

# Copy startup script
# Build cache bust: 2026-03-26-v32-home-dir
COPY start-openclaw.sh /usr/local/bin/start-openclaw.sh
RUN chmod +x /usr/local/bin/start-openclaw.sh

# Copy custom skills
COPY skills/ /home/openclaw/clawd/skills/

# Ensure all files are readable for mksquashfs (Sandbox SDK backup).
# OpenClaw and other tools may create restrictive config files at runtime,
# but we fix build-time permissions here; runtime permissions are fixed
# before each backup via sandbox.exec("chmod -R a+rX /home/openclaw").
RUN chmod -R a+rX /home/openclaw

# Set working directory
WORKDIR /home/openclaw/clawd

# Expose the gateway port
EXPOSE 18789