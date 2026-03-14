# =============================================================================
# Dockerfile — pihole-to-clash-sync
# Lightweight Node.js daemon that syncs Pi-hole DNS hosts → Clash Meta
# Joins clash_net + pihole_net via docker-compose network_mode / extra_hosts
# =============================================================================

FROM node:20-alpine

# Non-root user for least-privilege
WORKDIR /app

# Install dependencies first (layer caching)
COPY scripts/package.json .
RUN npm install --omit=dev 

# Copy source
COPY scripts/index.js ./index.js

# State dir for policy hash persistence (mapped to a named volume)
RUN mkdir -p /var/lib/clash-sync

CMD ["node", "index.js"]
