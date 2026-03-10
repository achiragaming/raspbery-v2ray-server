#!/usr/bin/env node
// =============================================================================
// build.js
// Merges all /profiles/*.yml files and runs the same JS logic you had in
// Clash Verge/CFW — outputs a final config.yaml for Clash Meta to load
// Run automatically by Docker entrypoint before Clash starts
// =============================================================================

const fs = require("fs");
const path = require("path");

// yaml is bundled in the container via package.json
const yaml = require("js-yaml");

const PROFILES_DIR = process.env.PROFILES_DIR || "/profiles";
const OUTPUT = process.env.OUTPUT || "/root/.config/mihomo/config.yaml";

// =============================================================================
// HELPERS
// =============================================================================

function log(msg) {
  console.log(`[build] ${msg}`);
}

function deepMerge(base, override) {
  const result = { ...base };
  for (const [k, v] of Object.entries(override)) {
    if (Array.isArray(result[k]) && Array.isArray(v)) {
      // Merge arrays — deduplicate by `name` key if present
      const existingNames = new Set(
        result[k].filter((i) => i?.name).map((i) => i.name),
      );
      for (const item of v) {
        if (item?.name && existingNames.has(item.name)) {
          // Replace existing entry with same name
          result[k] = result[k].map((i) => (i?.name === item.name ? item : i));
        } else {
          result[k] = [...result[k], item];
        }
      }
    } else if (
      v &&
      typeof v === "object" &&
      !Array.isArray(v) &&
      result[k] &&
      typeof result[k] === "object"
    ) {
      result[k] = deepMerge(result[k], v);
    } else {
      result[k] = v;
    }
  }
  return result;
}

// =============================================================================
// STEP 1 — Load and merge all profile files
// =============================================================================

log(`Loading profiles from ${PROFILES_DIR}...`);

const profileFiles = fs
  .readdirSync(PROFILES_DIR)
  .filter((f) => f.endsWith(".yml") || f.endsWith(".yaml"))
  .sort() // 00-base first, then 01-, 02-, etc.
  .map((f) => path.join(PROFILES_DIR, f));

if (profileFiles.length === 0) {
  console.error("[build] ERROR: No profile files found in " + PROFILES_DIR);
  process.exit(1);
}

let merged = {};
for (const f of profileFiles) {
  log(`  Loading: ${path.basename(f)}`);
  const data = yaml.load(fs.readFileSync(f, "utf8")) || {};
  merged = deepMerge(merged, data);
}

log(
  `Merged ${profileFiles.length} profile(s) — ${(merged.proxies || []).length} proxies found`,
);

// =============================================================================
// STEP 2 — Run the main() preprocessor (same as your Clash Verge script)
// =============================================================================

function main(config) {
  // ── CONFIGURATION — all values come from .env via docker-compose ──────────
  const PIHOLE_IP = process.env.PIHOLE_IP || "192.168.8.145";
  const LAN_CIDR = process.env.LAN_SUBNET || "192.168.8.0/24";
  const CLASH_IP = process.env.CLASH_IP || "192.168.8.146";
  const SECRET = process.env.CLASH_SECRET || "changeme";
  const LAN_DNS = process.env.LAN_DNS || "192.168.8.1";
  const PROXY_GROUP = "🚀 Proxy";
  const VPS_PROFILE_NAME = process.env.VPS_PROFILE_NAME || "My-VPS-SG"; // must match the name of your main VPN node in the profiles
  const EXTRA_FAKE_IP_BYPASS = [
    "*.lan",
    "*.local",
    "*.internal",
    "*.home",
    "pi.hole",
    "host.docker.internal",
    "192.168.*",
    "10.*",
    "172.16.*",
    "127.0.0.1",
  ];
  // ── END CONFIGURATION ──────────────────────────────────────────────────────

  const isIP = (s) => /^\d+\.\d+\.\d+\.\d+$/.test(s);

  // Auto-detect all VPN server IPs/domains
  const vpnServers = [
    ...new Set(
      (config.proxies || [])
        .filter((p) =>
          [
            "vless",
            "vmess",
            "trojan",
            "hysteria2",
            "shadowsocks",
            "tuic",
          ].includes(p.type),
        )
        .map((p) => p.server),
    ),
  ];

  log(
    `Auto-detected ${vpnServers.length} VPN server(s): ${vpnServers.join(", ")}`,
  );

  // DNS
  config.dns = {
    enable: true,
    "enhanced-mode": "fake-ip",
    listen: `${CLASH_IP}:53`,
    nameserver: [
      "https://1.1.1.1/dns-query", // Cloudflare DoH
      "https://8.8.8.8/dns-query", // Google DoH
    ],
    "default-nameserver": [LAN_DNS],
      'nameserver-policy': {
    '*.lan':      PIHOLE_IP,
    '*.local':    PIHOLE_IP,
    '*.internal': PIHOLE_IP,
    '*.home':     PIHOLE_IP,
    'pi.hole':    PIHOLE_IP,
  },
    "fake-ip-filter": [
      ...new Set([
        ...vpnServers,
        ...EXTRA_FAKE_IP_BYPASS,
        ...((config.dns || {})["fake-ip-filter"] || []),
      ]),
    ],
    hosts: (config.dns || {}).hosts || {},
  };

  // TUN
  config.tun = {
    enable: true,
    stack: "system",
    "auto-route": true,
    "strict-route": false,
    "auto-detect-interface": true,
    "dns-hijack": ["any:53"],
    "route-exclude-address": [
      ...new Set([
        LAN_CIDR,
        PIHOLE_IP + "/32",
        "127.0.0.1/32",
        ...vpnServers.filter(isIP).map((s) => s + "/32"),
      ]),
    ],
  };

  // External controller
  config["external-controller"] = `${CLASH_IP}:9090`;
  config["secret"] = SECRET;

  // Auto-populate proxy groups with all nodes
  if (config["proxy-groups"]) {
    config["proxy-groups"].forEach((group) => {
      // Find the group with the Rocket or "Proxy" in the name
      if (group.name.includes("Proxy") || group.name.includes("🚀")) {
        log(`Configuring ${group.name} for Fallback (Priority: VPS)`);

        group.type = "fallback"; // Stays on VPS unless it's dead
        group.url = "http://www.gstatic.com/generate_204";
        group.interval = 180; // Check every 3 mins

        // Force VPS to index 0, DIRECT to last
        let otherNodes = group.proxies.filter(
          (p) => p !== VPS_PROFILE_NAME && p !== "DIRECT",
        );
        group.proxies = [VPS_PROFILE_NAME, ...otherNodes, "DIRECT"];
      }
    });
  }

  // Rules
  const vpnBypassRules = vpnServers.map((s) =>
    isIP(s)
      ? `IP-CIDR,${s}/32,DIRECT,no-resolve`
      : `DOMAIN,${s},DIRECT,no-resolve`,
  );
  const existingRules = (config.rules || []).filter(
    (r) => !r.startsWith("MATCH,"),
  );
  const matchRule =
    (config.rules || []).find((r) => r.startsWith("MATCH,")) ||
    `MATCH,${PROXY_GROUP}`;

  config.rules = [
    ...vpnBypassRules,
    `IP-CIDR,${LAN_CIDR},DIRECT,no-resolve`,
    "GEOIP,lan,DIRECT,no-resolve",
    ...existingRules,
    matchRule,
  ];

  return config;
}

const result = main(merged);

// =============================================================================
// STEP 3 — Write final config.yaml
// =============================================================================

fs.mkdirSync(path.dirname(OUTPUT), { recursive: true });
fs.writeFileSync(
  OUTPUT,
  yaml.dump(result, {
    lineWidth: -1, // don't wrap long lines
    noRefs: true, // no YAML anchors
    sortKeys: false, // preserve key order
  }),
);

log(`✓ Config written to ${OUTPUT}`);
log(`  Proxies : ${(result.proxies || []).length}`);
log(`  Rules   : ${(result.rules || []).length}`);
