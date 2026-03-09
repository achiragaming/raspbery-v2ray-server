# =============================================================================
# Dockerfile
# Uses the official mihomo image as base, adds Node.js + js-yaml on top
# No binary download needed — mihomo is already in the base image
# =============================================================================

FROM metacubex/mihomo:latest AS mihomo
FROM node:20-alpine

# Copy mihomo binary from official image
COPY --from=mihomo /mihomo /usr/local/bin/mihomo

# Install system deps
RUN apk add --no-cache iproute2

# Pre-install js-yaml
WORKDIR /scripts
COPY clash/scripts/package.json .
RUN npm install --silent

# Copy scripts
COPY clash/scripts/build.js /scripts/
COPY clash/scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
