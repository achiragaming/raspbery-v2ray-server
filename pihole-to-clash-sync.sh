#!/bin/bash
# =============================================================================
# pihole-to-clash-sync.sh
# Syncs Pi-hole v6 local DNS hosts + auto-updates nameserver-policy in build.js
# =============================================================================
set -euo pipefail

PIHOLE_IP="${PIHOLE_IP:-192.168.8.145}"
PIHOLE_PASSWORD="${PIHOLE_PASSWORD:-}"
CLASH_API="${CLASH_API:-http://192.168.8.146:9090}"
CLASH_SECRET="${CLASH_SECRET:-changeme}"
STACK_DIR="${STACK_DIR:-/opt/clash-stack}"
BUILD_JS="${STACK_DIR}/clash/scripts/build.js"
POLICY_HASH_FILE="/tmp/clash-policy.hash"
DEBUG=false

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Lock
exec 9>/tmp/pihole-clash-sync.lock
flock -n 9 || { log "Already running, skipping."; exit 0; }

# =============================================================================
# Step 1: Authenticate
# =============================================================================
log "Authenticating with Pi-hole at ${PIHOLE_IP}..."

AUTH_RESP=$(curl -sk --max-time 10 \
  -X POST "https://${PIHOLE_IP}/api/auth" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"${PIHOLE_PASSWORD}\"}")

SID=$(echo "$AUTH_RESP" | python3 -c "
import sys,json
d=json.load(sys.stdin)
s=d.get('session',{})
if s.get('valid'): print(s['sid'])
else: sys.exit(1)
") || { log "ERROR: Auth failed — check PIHOLE_PASSWORD"; exit 1; }

log "Authenticated OK"

# =============================================================================
# Step 2: Fetch data from Pi-hole
# =============================================================================
DNS_HOSTS=$(curl -sk --max-time 10 \
  -X GET "https://${PIHOLE_IP}/api/config/dns/hosts?detailed=true" \
  -H "X-FTL-SID: ${SID}")

CUSTOM_DNS=$(curl -sk --max-time 10 \
  -X GET "https://${PIHOLE_IP}/api/customdns" \
  -H "X-FTL-SID: ${SID}")

[ "$DEBUG" = true ] && {
  echo "$DNS_HOSTS"  > /tmp/pihole_dns_debug.json
  echo "$CUSTOM_DNS" > /tmp/pihole_customdns_debug.json
}

# =============================================================================
# Step 3: Logout
# =============================================================================
curl -sk -X DELETE "https://${PIHOLE_IP}/api/auth" \
  -H "X-FTL-SID: ${SID}" >/dev/null 2>&1 || true

# =============================================================================
# Step 4: Process with Python — write results to temp files
# =============================================================================
export PIHOLE_DNS_HOSTS="$DNS_HOSTS"
export PIHOLE_CUSTOM_DNS="$CUSTOM_DNS"
export PIHOLE_IP CLASH_API CLASH_SECRET

python3 << 'PYEOF'
import json, os, urllib.request

dns_raw    = os.environ['PIHOLE_DNS_HOSTS']
custom_raw = os.environ['PIHOLE_CUSTOM_DNS']
clash_url  = os.environ.get('CLASH_API',    'http://192.168.8.146:9090')
clash_key  = os.environ.get('CLASH_SECRET', 'changeme')
pihole_ip  = os.environ.get('PIHOLE_IP',    '192.168.8.145')

# --- Parse hosts ---
try:
    data = json.loads(dns_raw)
    raw_records = data.get('config', {}).get('dns', {}).get('hosts', {}).get('value', [])
    pihole_hosts = {}
    for entry in raw_records:
        parts = entry.split()
        if len(parts) >= 2:
            ip = parts[0]
            for domain in parts[1:]:
                pihole_hosts[domain] = ip
except Exception as e:
    print(f'PARSE_ERROR: {e}', flush=True)
    raise SystemExit(1)

# --- Parse custom DNS domains for nameserver-policy ---
try:
    cdata   = json.loads(custom_raw)
    records = cdata.get('customdns', [])
    all_domains = [r['domain'] for r in records if 'domain' in r]
    for entry in raw_records:
        parts = entry.split()
        if len(parts) >= 2:
            all_domains.extend(parts[1:])

    known_local = {'lan','local','internal','home','intranet','corp','private','vpn','lab'}
    patterns = {'*.lan','*.local','*.internal','*.home','pi.hole'}
    for domain in all_domains:
        parts = domain.lower().split('.')
        if parts[-1] in known_local:
            patterns.add(f'*.{parts[-1]}')
            if len(parts) > 2:
                patterns.add(f'*.{".".join(parts[-2:])}')
        else:
            patterns.add(domain)
            if len(parts) >= 2:
                patterns.add(f'*.{".".join(parts[-2:])}')
except Exception as e:
    print(f'PARSE_ERROR: {e}', flush=True)
    raise SystemExit(1)

# --- Get current Clash hosts ---
try:
    req = urllib.request.Request(f'{clash_url}/configs',
        headers={'Authorization': f'Bearer {clash_key}'})
    with urllib.request.urlopen(req, timeout=5) as r:
        current_hosts = json.loads(r.read()).get('hosts', {})
except:
    current_hosts = {}

# Write results to temp files so bash can safely read them
merged = {**current_hosts, **pihole_hosts}
with open('/tmp/clash_hosts_payload.json', 'w') as f:
    json.dump({'hosts': merged}, f)

policy = {p: pihole_ip for p in sorted(patterns)}
with open('/tmp/clash_policy.json', 'w') as f:
    json.dump(policy, f)

print(f'hosts={len(pihole_hosts)} policy_patterns={len(policy)}')
PYEOF

# =============================================================================
# Step 5: Patch Clash hosts
# =============================================================================
if [ -s /tmp/clash_hosts_payload.json ]; then
    code=$(curl -sf --max-time 10 \
      -X PATCH \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${CLASH_SECRET}" \
      -d @/tmp/clash_hosts_payload.json \
      -w "%{http_code}" -o /dev/null \
      "${CLASH_API}/configs") || code="ERR"

    if [[ "$code" == "204" || "$code" == "200" ]]; then
        count=$(python3 -c "import json; print(len(json.load(open('/tmp/clash_hosts_payload.json')).get('hosts',{})))")
        log "OK: Synced $count host(s) into Clash (HTTP $code)"
    else
        log "FAILED: Clash hosts PATCH returned $code"
    fi
fi

# =============================================================================
# Step 6: Update nameserver-policy in build.js if changed
# =============================================================================
current_hash=$(md5sum /tmp/clash_policy.json | cut -d' ' -f1)
saved_hash=""
[ -f "$POLICY_HASH_FILE" ] && saved_hash=$(cat "$POLICY_HASH_FILE")

if [[ "$current_hash" == "$saved_hash" ]]; then
    log "Nameserver-policy unchanged, no rebuild needed."
else
    log "Nameserver-policy changed — updating build.js..."

    export BUILD_JS
    python3 << 'PYEOF'
import json, re, os

build_js_path = os.environ.get('BUILD_JS', '/opt/clash-stack/clash/scripts/build.js')
policy = json.load(open('/tmp/clash_policy.json'))

with open(build_js_path, 'r') as f:
    content = f.read()

lines = ["    'nameserver-policy': {"]
for pattern in sorted(policy.keys()):
    lines.append(f"      '{pattern}': PIHOLE_IP,")
lines.append("    },")
new_block = '\n'.join(lines)

updated = re.sub(
    r"'nameserver-policy':\s*\{[^}]*\},",
    new_block,
    content,
    flags=re.DOTALL
)

with open(build_js_path, 'w') as f:
    f.write(updated)

print(f"Updated nameserver-policy: {len(policy)} patterns")
PYEOF

    # Rebuild config inside container
    docker exec clash node /scripts/build.js && log "Config rebuilt OK" || {
        log "ERROR: Config rebuild failed"
        exit 1
    }

    # Hot-reload Clash
    code=$(curl -sf --max-time 10 \
      -X PUT \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${CLASH_SECRET}" \
      -d '{"path":"/root/.config/mihomo/config.yaml"}' \
      -w "%{http_code}" -o /dev/null \
      "${CLASH_API}/configs?force=true") || code="ERR"

    if [[ "$code" == "204" || "$code" == "200" ]]; then
        log "OK: Clash hot-reloaded (HTTP $code)"
        echo "$current_hash" > "$POLICY_HASH_FILE"
    else
        log "WARNING: Clash reload returned $code"
    fi
fi

log "Sync complete."
