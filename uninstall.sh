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

PIHOLE_IP="${PIHOLE_IP:-192.168.8.202}"
CLASH_IP="${CLASH_IP:-192.168.8.206}"
STACK_DIR="${STACK_DIR:-/opt/clash-stack}"
HOST_IFACE="${HOST_IFACE:-enp2s0}"
PIHOLE_RANGE="${PIHOLE_RANGE:-192.168.8.201/30}"
CLASH_RANGE="${CLASH_RANGE:-192.168.8.205/30}"
APPS_RANGE="${APPS_RANGE:-192.168.8.209/29}"

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

for compose in \
  "$STACK_DIR/docker-compose.sync.yml" \
  "$STACK_DIR/docker-compose.pihole.yml" \
  "$STACK_DIR/docker-compose.clash.yml"; do
  if [[ -f "$compose" ]]; then
    docker compose -f "$compose" down 2>/dev/null \
      && log "Stopped: $(basename "$compose")" \
      || warn "Could not stop: $(basename "$compose")"
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
# 3. Remove Docker images
# =============================================================================

for image in clash-mihomo:latest pihole-custom:latest pihole-clash-sync:latest; do
  if docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -q "^${image}$"; then
    docker rmi "$image" && log "Removed image: $image" || warn "Could not remove image: $image"
  fi
done

# =============================================================================
# 4. Remove host routes
# =============================================================================

ip route del "${PIHOLE_RANGE}" 2>/dev/null \
  && log "Removed route: ${PIHOLE_RANGE}" \
  || warn "Route not found: ${PIHOLE_RANGE}"

ip route del "${CLASH_RANGE}" 2>/dev/null \
  && log "Removed route: ${CLASH_RANGE}" \
  || warn "Route not found: ${CLASH_RANGE}"

ip route del "${APPS_RANGE}" 2>/dev/null \
  && log "Removed route: ${APPS_RANGE}" \
  || warn "Route not found: ${APPS_RANGE}"

# =============================================================================
# 5. Remove macvlan interfaces
# =============================================================================

for iface in macvlan-pihole macvlan-clash macvlan-apps; do
  if ip link show "$iface" &>/dev/null; then
    ip link del "$iface" && log "Removed interface: $iface" || warn "Could not remove: $iface"
  fi
done

# =============================================================================
# 6. Remove systemd-networkd config
# =============================================================================

for f in \
  /etc/systemd/network/10-macvlan-pihole.netdev \
  /etc/systemd/network/10-macvlan-pihole.network \
  /etc/systemd/network/10-macvlan-clash.netdev \
  /etc/systemd/network/10-macvlan-clash.network \
  /etc/systemd/network/10-macvlan-apps.netdev \
  /etc/systemd/network/10-macvlan-apps.network \
  /etc/systemd/network/10-macvlan-parent.network; do
  [[ -f "$f" ]] && rm -f "$f" && log "Removed: $f" || warn "Not found: $f"
done

systemctl restart systemd-networkd 2>/dev/null || true
log "Restarted systemd-networkd"

# =============================================================================
# 7. Remove IP forwarding
# =============================================================================

sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
sysctl -p >/dev/null
log "IP forwarding disabled"

# =============================================================================
# 8. Remove fq_codel fair queuing
# =============================================================================

systemctl disable --now fq-codel.service 2>/dev/null && log "Disabled fq-codel.service" || warn "fq-codel.service not found"
rm -f /etc/systemd/system/fq-codel.service
systemctl daemon-reload

tc qdisc del dev "$HOST_IFACE" root 2>/dev/null && log "Removed fq_codel from $HOST_IFACE" || warn "No qdisc found on $HOST_IFACE"

# =============================================================================
# 9. Restore original file descriptor limits
# =============================================================================

SOFT_BAK="$STACK_DIR/.ulimit-soft.bak"
HARD_BAK="$STACK_DIR/.ulimit-hard.bak"

if [[ -f "$SOFT_BAK" && -f "$HARD_BAK" ]]; then
  ORIG_SOFT=$(cat "$SOFT_BAK")
  ORIG_HARD=$(cat "$HARD_BAK")

  sed -i '/nofile/d' /etc/security/limits.conf
  echo "* soft nofile $ORIG_SOFT" >> /etc/security/limits.conf
  echo "* hard nofile $ORIG_HARD" >> /etc/security/limits.conf
  log "Restored ulimits to original (soft=$ORIG_SOFT hard=$ORIG_HARD)"

  sed -i '/DefaultLimitNOFILE/d' /etc/systemd/system.conf
  systemctl daemon-reexec
  log "Restored systemd file descriptor limit"
else
  sed -i '/nofile/d' /etc/security/limits.conf
  sed -i '/DefaultLimitNOFILE/d' /etc/systemd/system.conf
  systemctl daemon-reexec
  warn "No ulimit backup found — removed entries without restoring"
fi

# =============================================================================
# 10. Remove stack directory + clash-sync state
# =============================================================================

if [[ -d "$STACK_DIR" ]]; then
  rm -rf "$STACK_DIR" && log "Removed: $STACK_DIR" || warn "Could not remove: $STACK_DIR"
fi

if [[ -d "/var/lib/clash-sync" ]]; then
  rm -rf /var/lib/clash-sync && log "Removed: /var/lib/clash-sync" || warn "Could not remove: /var/lib/clash-sync"
fi

echo ""
echo "  Uninstall complete — clean slate."
echo ""