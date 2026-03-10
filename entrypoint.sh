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

# Hijack DNS — redirect any client DNS not going to Pi-hole, force it there
# This ensures ad blocking works even if clients hardcode their own DNS
if [ -n "${PIHOLE_IP:-}" ]; then
  echo "[entrypoint] Setting up DNS hijack to Pi-hole ($PIHOLE_IP)..."
  iptables -t nat -A PREROUTING -p udp --dport 53 ! -d "$PIHOLE_IP" ! -s "$PIHOLE_IP" -j DNAT --to-destination "$PIHOLE_IP":53
  iptables -t nat -A PREROUTING -p tcp --dport 53 ! -d "$PIHOLE_IP" ! -s "$PIHOLE_IP" -j DNAT --to-destination "$PIHOLE_IP":53
  echo "[entrypoint] DNS hijack rules added"
fi

# Build Clash config from profiles
echo "[entrypoint] Building config..."
node /scripts/build.js

# Start mihomo
echo "[entrypoint] Starting mihomo..."
exec /usr/local/bin/mihomo -d /root/.config/mihomo
