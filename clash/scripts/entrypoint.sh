#!/bin/sh
# =============================================================================
# clash/scripts/entrypoint.sh
# 1. Fix default gateway  — macvlan gives no gateway, we set it ourselves
# 2. DNS hijack           — force ALL client DNS (port 53) to Pi-hole
# 3. SNAT (Masquerade)    — Fix asymmetric routing for DNS
# 4. Build config.yaml    — node build.js merges profiles → mihomo config
# 5. Start mihomo
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
if [ -n "${PIHOLE_IP:-}" ]; then
  echo "[entrypoint] Wiring DNS hijack → Pi-hole ($PIHOLE_IP)"

  # -- STEP A: DNAT (Intercept queries from LAN) --
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

  # -- STEP B: SNAT / MASQUERADE (Fix Asymmetric Routing) --
  # This forces Pi-hole to reply to THIS container instead of the client.
  # Otherwise, the client drops the packet because the source IP doesn't match.
  iptables -t nat -A POSTROUTING \
    -p udp -d "$PIHOLE_IP" --dport 53 \
    -j MASQUERADE

  iptables -t nat -A POSTROUTING \
    -p tcp -d "$PIHOLE_IP" --dport 53 \
    -j MASQUERADE

  echo "[entrypoint] DNS hijack & MASQUERADE rules added"
fi

# ── 3. Build Clash config from profiles ──────────────────────────────────────
echo "[entrypoint] Building config..."
node /scripts/build.js

# ── 4. Start mihomo ───────────────────────────────────────────────────────────
echo "[entrypoint] Starting mihomo..."
# Ensure the config directory exists
mkdir -p /root/.config/mihomo
exec /usr/local/bin/mihomo -d /root/.config/mihomo