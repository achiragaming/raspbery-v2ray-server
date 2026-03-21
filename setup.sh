#!/bin/bash
# =============================================================================
# setup.sh — run once as root to bootstrap the whole stack
# Creates two macvlan sub-interfaces on the physical NIC so each container
# gets its own physically separate virtual interface — no shared binding.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load variables from .env
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -o allexport
  source "$SCRIPT_DIR/.env"
  set +o allexport
else
  echo "ERROR: .env file not found in $SCRIPT_DIR"
  exit 1
fi

# Defaults in case .env is missing any
STACK_DIR="${STACK_DIR:-/opt/clash-stack}"
HOST_IFACE="${HOST_IFACE:-enp2s0}"
LAN_SUBNET="${LAN_SUBNET:-192.168.8.0/24}"
LAN_GATEWAY="${LAN_GATEWAY:-192.168.8.1}"
PIHOLE_IP="${PIHOLE_IP:-192.168.8.202}"
CLASH_IP="${CLASH_IP:-192.168.8.206}"
PIHOLE_RANGE="${PIHOLE_RANGE:-192.168.8.201/30}"
CLASH_RANGE="${CLASH_RANGE:-192.168.8.205/30}"
APPS_RANGE="${APPS_RANGE:-192.168.8.208/29}"
# Host shim IPs — unused IPs in each range so the host can reach containers
log()  { echo "  ✔ $*"; }
warn() { echo "  ⚠ $*"; }

echo ""
echo "┌─────────────────────────────────────────┐"
echo "│   Pi-hole + Clash Stack — Setup          │"
echo "└─────────────────────────────────────────┘"
echo ""

# =============================================================================
# 0. Check and install required packages
# =============================================================================

echo "  Checking dependencies..."

apt_updated=false

apt_install() {
  local pkg="$1"
  if ! dpkg -s "$pkg" &>/dev/null; then
    if [[ "$apt_updated" == false ]]; then
      apt-get update -qq
      apt_updated=true
    fi
    apt-get install -y --no-install-recommends "$pkg" -qq
    log "Installed: $pkg"
  else
    log "Already installed: $pkg"
  fi
}

apt_install iproute2
apt_install iptables
apt_install curl
apt_install ca-certificates

if ! command -v docker &>/dev/null; then
  warn "Docker not found — installing via get.docker.com..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  log "Docker installed"
else
  log "Already installed: docker ($(docker --version | cut -d' ' -f3 | tr -d ','))"
fi

if ! docker compose version &>/dev/null; then
  warn "Docker Compose plugin not found — installing..."
  apt_install docker-compose-plugin
else
  log "Already installed: docker compose ($(docker compose version --short))"
fi

# =============================================================================
# 1. Create macvlan sub-interfaces on the physical NIC
# =============================================================================

for iface in macvlan-pihole macvlan-clash macvlan-apps; do
  if ip link show "$iface" &>/dev/null; then
    warn "$iface already exists, skipping"
  else
    ip link add "$iface" link "$HOST_IFACE" type macvlan mode bridge
    ip link set "$iface" up
    log "Created interface: $iface"
  fi
done

# Routes — /32 for pihole/clash to override enp2s0 connected route
# apps uses subnet route since macvlan-apps is a dedicated interface
ip route add "${PIHOLE_IP}/32" dev macvlan-pihole metric 10 2>/dev/null \
  || warn "${PIHOLE_IP}/32 route already exists"
ip route add "${CLASH_IP}/32" dev macvlan-clash metric 10 2>/dev/null \
  || warn "${CLASH_IP}/32 route already exists"
ip route add "${APPS_RANGE}" dev macvlan-apps metric 10 2>/dev/null \
  || warn "${APPS_RANGE} route already exists"

log "Host-side shim IPs and routes configured"

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
# No address assigned — /32 host route handles host-to-container reachability

[Route]
Destination=${PIHOLE_IP}/32
Metric=10
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
# No address assigned — /32 host route handles host-to-container reachability

[Route]
Destination=${CLASH_IP}/32
Metric=10
EOF

cat > /etc/systemd/network/10-macvlan-apps.netdev <<EOF
[NetDev]
Name=macvlan-apps
Kind=macvlan

[MACVLAN]
Mode=bridge
EOF

cat > /etc/systemd/network/10-macvlan-apps.network <<EOF
[Match]
Name=macvlan-apps

[Network]
# No address assigned — subnet route handles host access to app containers

[Route]
Destination=${APPS_RANGE}
Metric=10
EOF

cat > /etc/systemd/network/10-macvlan-parent.network <<EOF
[Match]
Name=${HOST_IFACE}

[Network]
MACVLAN=macvlan-pihole
MACVLAN=macvlan-clash
MACVLAN=macvlan-apps
EOF

systemctl enable --now systemd-networkd 2>/dev/null || true
log "Macvlan interfaces will persist across reboots"

# =============================================================================
# 3. Create Docker networks
#    Each uses its own macvlan interface as parent — different parents allow
#    same subnet. Non-overlapping --ip-range satisfies Docker's pool manager.
#    No --gateway: containers set their own default route via their entrypoints.
# =============================================================================

if docker network ls --format '{{.Name}}' | grep -q "^pihole_net$"; then
  warn "pihole_net already exists"
else
  docker network create \
    --driver macvlan \
    --subnet "$LAN_SUBNET" \
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

if docker network ls --format '{{.Name}}' | grep -q "^apps_net$"; then
  warn "apps_net already exists"
else
  docker network create \
    --driver macvlan \
    --subnet "$LAN_SUBNET" \
    --ip-range "$APPS_RANGE" \
    --opt parent=macvlan-apps \
    apps_net
  log "Created Docker network: apps_net (parent: macvlan-apps, range: $APPS_RANGE)"
fi

# =============================================================================
# 4. Directory structure + copy files
# =============================================================================

mkdir -p "$STACK_DIR/clash/config" \
         "$STACK_DIR/clash/profiles" \
         "$STACK_DIR/clash/scripts" \
         "$STACK_DIR/pihole/scripts" \
         "$STACK_DIR/sync-service/scripts"

cp "$SCRIPT_DIR/docker-compose.clash.yml"  "$STACK_DIR/"
cp "$SCRIPT_DIR/docker-compose.pihole.yml" "$STACK_DIR/"
cp "$SCRIPT_DIR/docker-compose.sync.yml"   "$STACK_DIR/"
cp "$SCRIPT_DIR/clash/Dockerfile"          "$STACK_DIR/clash/"
cp "$SCRIPT_DIR/pihole/Dockerfile"         "$STACK_DIR/pihole/"

cp "$SCRIPT_DIR/clash/scripts/entrypoint.sh" "$STACK_DIR/clash/scripts/"
cp "$SCRIPT_DIR/clash/scripts/build.js"      "$STACK_DIR/clash/scripts/"
cp "$SCRIPT_DIR/clash/scripts/package.json"  "$STACK_DIR/clash/scripts/"

cp "$SCRIPT_DIR/pihole/scripts/entrypoint.sh" "$STACK_DIR/pihole/scripts/"

cp "$SCRIPT_DIR/sync-service/Dockerfile"           "$STACK_DIR/sync-service/"
cp "$SCRIPT_DIR/sync-service/scripts/package.json" "$STACK_DIR/sync-service/scripts/"
cp "$SCRIPT_DIR/sync-service/scripts/index.js"     "$STACK_DIR/sync-service/scripts/"

for f in "$SCRIPT_DIR/clash/profiles/"*.yml; do
  dest="$STACK_DIR/clash/profiles/$(basename "$f")"
  [[ ! -f "$dest" ]] && cp "$f" "$dest" && log "Copied profile: $(basename "$f")"
done

[[ ! -f "$STACK_DIR/.env" ]] && cp "$SCRIPT_DIR/.env" "$STACK_DIR/" && chmod 600 "$STACK_DIR/.env" && log "Copied .env"

# =============================================================================
# 5. Build all containers
# =============================================================================

log "Building Clash image..."
docker compose -f "$STACK_DIR/docker-compose.clash.yml" build

log "Building Pi-hole image..."
docker compose -f "$STACK_DIR/docker-compose.pihole.yml" build

log "Building sync service image..."
docker compose -f "$STACK_DIR/docker-compose.sync.yml" build

# =============================================================================
# 6. Enable IP forwarding (required before containers start)
# =============================================================================

grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || {
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  sysctl -p >/dev/null
  log "IP forwarding enabled"
}

# =============================================================================
# 7. File descriptor limits
#    Default 1024 is too low for Clash under heavy load — connections time out
# =============================================================================

# Save original values before we change anything so uninstall can restore them
ORIG_SOFT=$(ulimit -Sn)
ORIG_HARD=$(ulimit -Hn)
mkdir -p "$STACK_DIR"
echo "$ORIG_SOFT" > "$STACK_DIR/.ulimit-soft.bak"
echo "$ORIG_HARD" > "$STACK_DIR/.ulimit-hard.bak"
log "Saved original ulimits (soft=$ORIG_SOFT hard=$ORIG_HARD)"

grep -q "nofile" /etc/security/limits.conf || {
  echo "* soft nofile 1000000" >> /etc/security/limits.conf
  echo "* hard nofile 1000000" >> /etc/security/limits.conf
  log "File descriptor limits set to 1000000"
}

grep -q "DefaultLimitNOFILE" /etc/systemd/system.conf || {
  echo "DefaultLimitNOFILE=1000000" >> /etc/systemd/system.conf
  systemctl daemon-reexec
  log "Systemd file descriptor limit set to 1000000"
}

# =============================================================================
# 8. Fair queuing (fq_codel)
#    Automatically shares bandwidth fairly between devices — no per-device
#    config needed. High-usage devices get throttled when others need bandwidth,
#    and get full speed back when others are idle.
# =============================================================================

tc qdisc replace dev "$HOST_IFACE" root fq_codel 2>/dev/null && \
  log "fq_codel applied to $HOST_IFACE" || \
  warn "Could not apply fq_codel to $HOST_IFACE"

cat > /etc/systemd/system/fq-codel.service << EOF
[Unit]
Description=Apply fq_codel fair queuing to $HOST_IFACE
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/tc qdisc replace dev $HOST_IFACE root fq_codel
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now fq-codel.service 2>/dev/null && \
  log "fq-codel.service enabled (persists across reboots)" || \
  warn "Could not enable fq-codel.service"

# =============================================================================
# 9. Start all containers
# =============================================================================

log "Starting Clash..."
docker compose -f "$STACK_DIR/docker-compose.clash.yml" up -d

log "Starting Pi-hole..."
docker compose -f "$STACK_DIR/docker-compose.pihole.yml" up -d

log "Starting sync service..."
docker compose -f "$STACK_DIR/docker-compose.sync.yml" up -d

echo ""
echo "  Interface layout:"
echo "    ${HOST_IFACE} (physical, host IP: $(ip -4 addr show "${HOST_IFACE}" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1))"
echo "    ├── macvlan-pihole → pihole_net → ${PIHOLE_IP} (Pi-hole)  "
echo "    ├── macvlan-clash  → clash_net  → ${CLASH_IP}  (Clash)    "
echo "    └── macvlan-apps   → apps_net   → ${APPS_RANGE} (Apps)    [subnet route: ${APPS_RANGE}]"
echo ""
echo "     Pi-hole : https://${PIHOLE_IP}"
echo "     Clash   : http://${CLASH_IP}:9090"
echo "     Sync    : docker logs -f pihole-clash-sync"
echo ""
echo "  DNS traffic flow:"
echo "    LAN client → Pi-hole:53 (filter) → Clash:53 (resolve) → Cloudflare DoH"
echo "    Clients with hardcoded DNS → iptables DNAT → Pi-hole:53 (hijacked)"
echo ""
echo "  Next steps:"
echo "  1. Edit $STACK_DIR/.env — set CLASH_SECRET and PIHOLE_PASSWORD"
echo "  2. Drop proxy nodes into $STACK_DIR/clash/profiles/"
echo ""