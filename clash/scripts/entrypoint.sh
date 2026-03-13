#!/bin/sh
# =============================================================================
# clash/scripts/entrypoint.sh
# 1. Fix default gateway  — macvlan gives no gateway, we set it ourselves
# 2. DNS hijack           — force ALL client DNS (port 53) to Pi-hole
# 3. Transparent proxy    — TPROXY redirect LAN TCP/UDP into Clash
# 4. Build config.yaml   — node build.js merges profiles → mihomo config
# 5. Start mihomo
#
# Environment variables (all come from .env via docker-compose):
#   GATEWAY_IP   — LAN router IP   (e.g. 192.168.8.1)
#   PIHOLE_IP    — Pi-hole IP      (e.g. 192.168.8.145)
#   CLASH_IP     — this container  (e.g. 192.168.8.146)
#   LAN_SUBNET   — LAN CIDR        (e.g. 192.168.8.0/24)
# =============================================================================
set -e

# ── 1. Default gateway ────────────────────────────────────────────────────────
if [ -n "${GATEWAY_IP:-}" ]; then
  echo "[entrypoint] Setting default gateway → $GATEWAY_IP"
  ip route del default 2>/dev/null || true
  ip route add default via "$GATEWAY_IP" dev eth0
  echo "[entrypoint] Default route: $(ip route show default)"
else
  echo "[entrypoint] WARNING: GATEWAY_IP not set"
fi

# ── 2. DNS hijack → Pi-hole ───────────────────────────────────────────────────
# Any DNS query arriving at Clash from a LAN client that is NOT already
# addressed to Pi-hole gets DNAT'd to Pi-hole:53.
# Pi-hole then forwards upstream to Clash's DNS listener (port 5353 or 53
# as configured in build.js), completing the chain:
#   LAN client → Clash (hijack) → Pi-hole (filter) → Clash DNS → DoH
if [ -n "${PIHOLE_IP:-}" ]; then
  echo "[entrypoint] Wiring DNS hijack → Pi-hole ($PIHOLE_IP)"

  # UDP DNS
  iptables -t nat -A PREROUTING \
    -p udp --dport 53 \
    ! -d "$PIHOLE_IP" \
    ! -s "$PIHOLE_IP" \
    -j DNAT --to-destination "${PIHOLE_IP}:53"

  # TCP DNS
  iptables -t nat -A PREROUTING \
    -p tcp --dport 53 \
    ! -d "$PIHOLE_IP" \
    ! -s "$PIHOLE_IP" \
    -j DNAT --to-destination "${PIHOLE_IP}:53"

  echo "[entrypoint] DNS hijack rules added"
fi

# ── 3. Build Clash config from profiles ──────────────────────────────────────
echo "[entrypoint] Building config..."
node /scripts/build.js

# ── 5. Start mihomo ───────────────────────────────────────────────────────────
echo "[entrypoint] Starting mihomo..."
exec /usr/local/bin/mihomo -d /root/.config/mihomo
