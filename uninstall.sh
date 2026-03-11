#!/bin/bash
# =============================================================================
# uninstall.sh — removes everything setup.sh created
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load variables from .env if available
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -o allexport
  source "$SCRIPT_DIR/.env"
  set +o allexport
elif [[ -f "/opt/clash-stack/.env" ]]; then
  set -o allexport
  source "/opt/clash-stack/.env"
  set +o allexport
fi

LAN_SUBNET="${LAN_SUBNET:-192.168.8.0/24}"
LAN_GATEWAY="${LAN_GATEWAY:-192.168.8.1}"
PIHOLE_IP="${PIHOLE_IP:-192.168.8.145}"
CLASH_IP="${CLASH_IP:-192.168.8.146}"
STACK_DIR="${STACK_DIR:-/opt/clash-stack}"

log()  { echo "  ✔ $*"; }
warn() { echo "  ⚠ $*"; }

echo ""
echo "┌─────────────────────────────────────────┐"
echo "│   Pi-hole + Clash Stack — Uninstall      │"
echo "└─────────────────────────────────────────┘"
echo ""

# =============================================================================
# 1. Stop and remove containers
# =============================================================================

for compose in "$STACK_DIR/docker-compose.pihole.yml" "$STACK_DIR/docker-compose.clash.yml"; do
  if [[ -f "$compose" ]]; then
    docker compose -f "$compose" down 2>/dev/null && log "Stopped: $(basename $compose)" || warn "Could not stop: $(basename $compose)"
  fi
done

# =============================================================================
# 2. Remove Docker networks
# =============================================================================

for net in pihole_net clash_net apps_net; do
  if docker network ls --format '{{.Name}}' | grep -q "^${net}$"; then
    docker network rm "$net" && log "Removed network: $net" || warn "Could not remove: $net"
  else
    warn "Network not found: $net"
  fi
done

# =============================================================================
# 3. Remove Docker image
# =============================================================================

if docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -q "^clash-mihomo:latest$"; then
  docker rmi clash-mihomo:latest && log "Removed image: clash-mihomo:latest" || warn "Could not remove image"
fi

# =============================================================================
# 4. Remove macvlan interfaces
# =============================================================================

for iface in macvlan-pihole macvlan-clash macvlan-host macvlan-apps; do
  if ip link show "$iface" &>/dev/null; then
    ip link del "$iface" && log "Removed interface: $iface" || warn "Could not remove: $iface"
  fi
done

# =============================================================================
# 5. Remove host routes
# =============================================================================

ip route del "${PIHOLE_IP}/32" 2>/dev/null && log "Removed route: ${PIHOLE_IP}/32" || warn "Route not found: ${PIHOLE_IP}/32"
ip route del "${CLASH_IP}/32"  2>/dev/null && log "Removed route: ${CLASH_IP}/32"  || warn "Route not found: ${CLASH_IP}/32"

# =============================================================================
# 6. Remove systemd-networkd config
# =============================================================================

for f in \
  /etc/systemd/network/10-macvlan-pihole.netdev \
  /etc/systemd/network/10-macvlan-pihole.network \
  /etc/systemd/network/10-macvlan-clash.netdev \
  /etc/systemd/network/10-macvlan-clash.network \
  /etc/systemd/network/10-macvlan-parent.network; do
  [[ -f "$f" ]] && rm -f "$f" && log "Removed: $f" || warn "Not found: $f"
done

systemctl restart systemd-networkd 2>/dev/null || true
log "Restarted systemd-networkd"

# =============================================================================
# 7. Remove sync script + systemd timer
# =============================================================================

systemctl disable --now pihole-clash-sync.timer 2>/dev/null && log "Disabled timer" || warn "Timer not found"

for f in \
  /etc/systemd/system/pihole-clash-sync.service \
  /etc/systemd/system/pihole-clash-sync.timer \
  /usr/local/bin/pihole-to-clash-sync.sh; do
  [[ -f "$f" ]] && rm -f "$f" && log "Removed: $f" || warn "Not found: $f"
done

systemctl daemon-reload

# =============================================================================
# 8. Remove IP forwarding
# =============================================================================

sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
sysctl -p >/dev/null
log "IP forwarding disabled"

# =============================================================================
# 9. Remove stack directory
# =============================================================================

if [[ -d "$STACK_DIR" ]]; then
  rm -rf "$STACK_DIR" && log "Removed: $STACK_DIR" || warn "Could not remove: $STACK_DIR"
fi

echo ""
echo "  Uninstall complete — clean slate."
echo ""
