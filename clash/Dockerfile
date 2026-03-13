# =============================================================================
# Dockerfile
# Stage 1: pull the official mihomo binary
# Stage 2: node:20-alpine runtime — build.js + entrypoint + mihomo
# The entrypoint sets the default gateway and wires DNS hijack to Pi-hole
# before handing off to mihomo.
# =============================================================================

FROM metacubex/mihomo:latest AS mihomo
FROM node:20-alpine

# ── System deps ───────────────────────────────────────────────────────────────
# iproute2  → ip route / ip link (gateway fixup)
# iptables  → NAT rules for DNS hijack + transparent proxy
RUN apk add --no-cache iproute2 iptables

# ── Copy mihomo binary from official image ────────────────────────────────────
COPY --from=mihomo /mihomo /usr/local/bin/mihomo

# ── Node deps (js-yaml for build.js) ─────────────────────────────────────────
WORKDIR /scripts
COPY scripts/package.json .
RUN npm install --omit=dev 

# ── Scripts ───────────────────────────────────────────────────────────────────
COPY scripts/build.js      /scripts/build.js
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
