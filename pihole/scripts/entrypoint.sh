#!/bin/sh
# =============================================================================
# pihole/entrypoint.sh
# Runs before the official Pi-hole init (/s6-init).
# macvlan networks don't inject a default gateway, so we set it here.
# GATEWAY_IP is passed via docker-compose environment.
# =============================================================================
set -e

# ── 1. Fix default gateway ────────────────────────────────────────────────────
if [ -n "${GATEWAY_IP:-}" ]; then
  echo "[pihole-entrypoint] Setting default gateway → $GATEWAY_IP"
  ip route del default 2>/dev/null || true
  ip route add default via "$GATEWAY_IP" dev eth0
  echo "[pihole-entrypoint] Default route: $(ip route show default)"
else
  echo "[pihole-entrypoint] WARNING: GATEWAY_IP not set — upstream DNS may be unreachable"
fi

# ── 2. Hand off to the official Pi-hole supervisor ───────────────────────────
echo "[pihole-entrypoint] Starting Pi-hole..."
exec start.sh
