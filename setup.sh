#!/bin/bash
# =============================================================================
# setup.sh — run once as root to bootstrap the whole stack
# Creates two macvlan sub-interfaces on the physical NIC so each container
# gets its own physically separate virtual interface — no shared binding
# =============================================================================
set -euo pipefail

HOST_IFACE="${HOST_IFACE:-enp2s0}"   # your physical NIC
LAN_SUBNET="192.168.8.0/24"
LAN_GATEWAY="192.168.8.1"
PIHOLE_IP="192.168.8.145"
CLASH_IP="192.168.8.146"
STACK_DIR="/opt/clash-stack"

# Non-overlapping IP ranges within the subnet for Docker's pool manager
PIHOLE_RANGE="192.168.8.144/28"
CLASH_RANGE="192.168.8.160/28"

log()  { echo "  ✔ $*"; }
warn() { echo "  ⚠ $*"; }

echo ""
echo "┌─────────────────────────────────────────┐"
echo "│   Pi-hole + Clash Stack — Setup          │"
echo "└─────────────────────────────────────────┘"
echo ""

# =============================================================================
# 1. Create macvlan sub-interfaces on the physical NIC
# =============================================================================

for iface in macvlan-pihole macvlan-clash; do
  if ip link show "$iface" &>/dev/null; then
    warn "$iface already exists, skipping"
  else
    ip link add "$iface" link "$HOST_IFACE" type macvlan mode bridge
    ip link set "$iface" up
    log "Created interface: $iface"
  fi
done

# NOTE: We do NOT assign the container IPs to the host-side macvlan interfaces
# Doing so causes the host to answer ARP for those IPs, stealing them from
# the containers and making them unreachable from the LAN.
# Macvlan host↔container isolation is a known limitation — access Pi-hole
# and Clash dashboards from another LAN device (phone, other PC).

# Routes so the host can route traffic toward the macvlan interfaces
# (used by the sync script to reach Pi-hole/Clash from the host)
ip route add "${PIHOLE_IP}/32" dev macvlan-pihole metric 50 2>/dev/null \
  || warn "${PIHOLE_IP}/32 route already exists"
ip route add "${CLASH_IP}/32"  dev macvlan-clash  metric 50 2>/dev/null \
  || warn "${CLASH_IP}/32 route already exists"

log "Host-side routes configured"

# =============================================================================
# 2. Persist macvlan interfaces across reboots via systemd-networkd
# =============================================================================

cat > /etc/systemd/network/10-macvlan-pihole.netdev <<EOF
[NetDev]
Name=macvlan-pihole
Kind=macvlan

[MACVLAN]
Mode=bridge
EOF

cat > /etc/systemd/network/10-macvlan-pihole.network <<EOF
[Match]
Name=macvlan-pihole

[Network]
# No address assigned — assigning the container IP here steals it from the container

[Route]
Destination=${PIHOLE_IP}/32
Metric=50
EOF

cat > /etc/systemd/network/10-macvlan-clash.netdev <<EOF
[NetDev]
Name=macvlan-clash
Kind=macvlan

[MACVLAN]
Mode=bridge
EOF

cat > /etc/systemd/network/10-macvlan-clash.network <<EOF
[Match]
Name=macvlan-clash

[Network]
# No address assigned — assigning the container IP here steals it from the container

[Route]
Destination=${CLASH_IP}/32
Metric=50
EOF

cat > /etc/systemd/network/10-macvlan-parent.network <<EOF
[Match]
Name=${HOST_IFACE}

[Network]
MACVLAN=macvlan-pihole
MACVLAN=macvlan-clash
EOF

systemctl enable --now systemd-networkd 2>/dev/null || true
log "Macvlan interfaces will persist across reboots"

# =============================================================================
# 3. Create Docker networks
#    Each uses its own macvlan interface as parent — different parents allow
#    same subnet. Non-overlapping --ip-range satisfies Docker's pool manager.
# =============================================================================

if docker network ls --format '{{.Name}}' | grep -q "^pihole_net$"; then
  warn "pihole_net already exists"
else
  docker network create \
    --driver macvlan \
    --subnet "$LAN_SUBNET" \

    --gateway "$LAN_GATEWAY" \
    --ip-range "$PIHOLE_RANGE" \
    --opt parent=macvlan-pihole \
    pihole_net
  log "Created Docker network: pihole_net (parent: macvlan-pihole, range: $PIHOLE_RANGE)"
fi

if docker network ls --format '{{.Name}}' | grep -q "^clash_net$"; then
  warn "clash_net already exists"
else
  docker network create \
    --driver macvlan \
    --subnet "$LAN_SUBNET" \
    --ip-range "$CLASH_RANGE" \
    --opt parent=macvlan-clash \
    clash_net
  log "Created Docker network: clash_net (parent: macvlan-clash, range: $CLASH_RANGE)"
fi

# =============================================================================
# 4. Directory structure + copy files
# =============================================================================

# 4. Directory structure + copy files
mkdir -p "$STACK_DIR/clash/config" "$STACK_DIR/clash/profiles" "$STACK_DIR/clash/scripts"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp "$SCRIPT_DIR/docker-compose.pihole.yml" "$STACK_DIR/"
cp "$SCRIPT_DIR/docker-compose.clash.yml"  "$STACK_DIR/"
cp "$SCRIPT_DIR/Dockerfile"       "$STACK_DIR/"
cp "$SCRIPT_DIR/entrypoint.sh"       "$STACK_DIR/clash/scripts/"
cp "$SCRIPT_DIR/scripts/build.js"       "$STACK_DIR/clash/scripts/"
cp "$SCRIPT_DIR/scripts/package.json"   "$STACK_DIR/clash/scripts/"

for f in "$SCRIPT_DIR/profiles/"*.yml; do
  dest="$STACK_DIR/clash/profiles/$(basename "$f")"
  [[ ! -f "$dest" ]] && cp "$f" "$dest" && log "Copied profile: $(basename "$f")"
done

[[ ! -f "$STACK_DIR/.env" ]] && cp "$SCRIPT_DIR/.env" "$STACK_DIR/" && log "Copied .env"

# =============================================================================
# 5. Sync script + systemd timer
# =============================================================================

cp "$SCRIPT_DIR/pihole-to-clash-sync.sh" /usr/local/bin/
chmod +x /usr/local/bin/pihole-to-clash-sync.sh
log "Installed sync script"

cp "$SCRIPT_DIR/pihole-clash-sync.service" /etc/systemd/system/
cp "$SCRIPT_DIR/pihole-clash-sync.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now pihole-clash-sync.timer
log "Systemd timer enabled (every 60s)"

# =============================================================================
# 6. IP forwarding
# =============================================================================

grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || {
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  sysctl -p >/dev/null
  log "IP forwarding enabled"
}

echo ""
echo "  Interface layout:"
echo "    ${HOST_IFACE} (physical, host IP: $(ip -4 addr show ${HOST_IFACE} | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1))"
echo "    ├── macvlan-pihole → pihole_net → ${PIHOLE_IP} (Pi-hole)"
echo "    └── macvlan-clash  → clash_net  → ${CLASH_IP}  (Clash)"
echo ""
echo "  ⚠  Host cannot reach containers directly (macvlan isolation)"
echo "     Access dashboards from another LAN device (phone, other PC)"
echo "     Pi-hole: https://${PIHOLE_IP}"
echo "     Clash:   http://${CLASH_IP}:9090"
echo ""
echo "  Next steps:"
echo "  1. Edit $STACK_DIR/.env"
echo "       → set CLASH_SECRET and PIHOLE_TOKEN"
echo "  2. Edit $STACK_DIR/clash/config/config.yaml"
echo "       → set secret: to match CLASH_SECRET"
echo "  3. docker compose -f $STACK_DIR/docker-compose.pihole.yml up -d"
echo "  4. docker compose -f $STACK_DIR/docker-compose.clash.yml up -d"
echo ""
echo "  Add nodes: drop a .yml into $STACK_DIR/clash/profiles/"
echo ""
