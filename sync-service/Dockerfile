# =============================================================================
# Dockerfile — pihole-to-clash-sync
# Lightweight Node.js daemon that syncs Pi-hole DNS hosts → Clash Meta
# Joins clash_net + pihole_net via docker-compose network_mode / extra_hosts
# =============================================================================

FROM node:20-alpine

# Non-root user for least-privilege
RUN addgroup -S clashsync && adduser -S clashsync -G clashsync

WORKDIR /app

# Install dependencies first (layer caching)
COPY package.json .
RUN npm install --omit=dev --silent

# Copy source
COPY src/ ./src/

# State dir for policy hash persistence (mapped to a named volume)
RUN mkdir -p /var/lib/clash-sync && chown clashsync:clashsync /var/lib/clash-sync

USER clashsync

# Healthcheck — confirms the process is alive
HEALTHCHECK --interval=60s --timeout=5s --start-period=10s \
  CMD pgrep -f "node src/index.js" || exit 1

CMD ["node", "src/index.js"]
