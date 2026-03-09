#!/bin/bash
# =============================================================================
# pihole-to-clash-sync.sh
# Fetches Pi-hole v6 local DNS records and patches them into Clash hosts
# Optimized for Pi-hole v6 API structure and shell-to-python data safety
# =============================================================================

set -euo pipefail

# --- Configuration ---
PIHOLE_IP="${PIHOLE_IP:-192.168.8.145}"
PIHOLE_PASSWORD="${PIHOLE_PASSWORD:-correct horse battery staple}"
CLASH_API="${CLASH_API:-http://192.168.8.146:9090}"
CLASH_SECRET="${CLASH_SECRET:-changeme}"

LOG_FILE="/var/log/pihole-clash-sync.log"
LOCKFILE="/tmp/pihole-clash-sync.lock"
DEBUG=false  # Set to true to dump API responses to /tmp

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Prevent concurrent runs
exec 9>"$LOCKFILE"
flock -n 9 || { log "Already running, skipping."; exit 0; }

# --- Step 1: Authenticate with Pi-hole v6 ---
log "Authenticating with Pi-hole at ${PIHOLE_IP}..."

auth_response=$(curl -sk --max-time 10 \
  -X POST "http://${PIHOLE_IP}/api/auth" \
  -H "Content-Type: application/json" \
  -d "{\"password\":\"${PIHOLE_PASSWORD}\"}" ) || {
  log "ERROR: Could not reach Pi-hole"
  exit 1
}

SID=$(echo "$auth_response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    session = data.get('session', {})
    if session.get('valid'):
        print(session['sid'])
    else:
        print('ERROR', file=sys.stderr)
except:
    sys.exit(1)
") || { log "ERROR: Auth failed. Check password."; exit 1; }

# --- Step 2: Fetch DNS Records ---
# Using the specific v6 config path from your example
dns_response=$(curl -sk --max-time 10 \
  -X GET "http://${PIHOLE_IP}/api/config/dns/hosts?detailed=true" \
  -H "X-FTL-SID: ${SID}")

if [ "$DEBUG" = true ]; then echo "$dns_response" > /tmp/pihole_dns_debug.json; fi

# --- Step 3: Process and Merge (Python Logic) ---
# Export to Env Var to avoid "Invalid control character" shell expansion errors
export PIHOLE_DATA="$dns_response"

merged_payload=$(python3 - <<PYEOF
import sys, json, os, urllib.request

def run():
    raw_json = os.environ.get('PIHOLE_DATA', '{}')
    clash_url = '${CLASH_API}'
    clash_key = '${CLASH_SECRET}'

    try:
        data = json.loads(raw_json)
        # Navigate to: config -> dns -> hosts -> value
        # Format is: ["192.168.8.135 jellyfin.pc.local", ...]
        raw_records = data.get('config', {}).get('dns', {}).get('hosts', {}).get('value', [])
        
        pihole_hosts = {}
        for entry in raw_records:
            parts = entry.split()
            if len(parts) >= 2:
                ip = parts[0]
                for domain in parts[1:]:
                    pihole_hosts[domain] = ip
    except Exception as e:
        print(f"PYTHON_ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    if not pihole_hosts:
        print("EMPTY")
        return

    # Get current Clash config to merge
    try:
        req = urllib.request.Request(f"{clash_url}/configs", 
            headers={'Authorization': f'Bearer {clash_key}'})
        with urllib.request.urlopen(req, timeout=5) as r:
            current = json.loads(r.read()).get('hosts', {})
    except:
        current = {}

    # Merge (Pi-hole records take priority)
    final_hosts = {**current, **pihole_hosts}
    print(json.dumps({"hosts": final_hosts}))

run()
PYEOF
)

# --- Step 4: Logout (Cleanup) ---
curl -sk -X DELETE "http://${PIHOLE_IP}/api/auth" -H "X-FTL-SID: ${SID}" >/dev/null 2>&1 || true

# --- Step 5: Patch Clash ---
if [[ "$merged_payload" == "EMPTY" ]]; then
    log "No DNS records found to sync."
    exit 0
fi

if [[ "$merged_payload" == *"PYTHON_ERROR"* ]]; then
    log "Script failed during JSON processing."
    exit 1
fi

code=$(curl -sf --max-time 10 \
  -X PATCH \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${CLASH_SECRET}" \
  -d "$merged_payload" \
  -w "%{http_code}" -o /dev/null \
  "${CLASH_API}/configs") || code="ERR"

if [[ "$code" == "204" || "$code" == "200" ]]; then
    log "SUCCESS: Local DNS synced to Clash (HTTP $code)"
else
    log "FAILED: Clash API returned $code"
fi
