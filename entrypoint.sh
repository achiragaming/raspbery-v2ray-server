#!/bin/sh
set -e

# =============================================================================
# entrypoint.sh
# 1. Fixes the default gateway (Docker macvlan doesn't set it correctly)
# 2. Runs build.js to generate config.yaml from profiles
# 3. Starts mihomo
# =============================================================================

# Fix default gateway — Docker macvlan ignores --gateway flag for routing
# GATEWAY_IP is passed in via docker-compose environment
if [ -n "${GATEWAY_IP:-}" ]; then
  echo "[entrypoint] Setting default gateway to $GATEWAY_IP..."
  ip route del default 2>/dev/null || true
  ip route add default via "$GATEWAY_IP" dev eth0
  echo "[entrypoint] Default route: $(ip route show default)"
fi

# Build Clash config from profiles
echo "[entrypoint] Building config..."
node /scripts/build.js

# Start mihomo
echo "[entrypoint] Starting mihomo..."
exec /usr/local/bin/mihomo -d /root/.config/mihomo
