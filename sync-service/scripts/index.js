#!/usr/bin/env node
// =============================================================================
// pihole-to-clash-sync — Node.js daemon
// Replaces pihole-to-clash-sync.sh with a persistent setInterval loop
// Networks: attaches to clash_net + pihole_net via docker-compose
// =============================================================================

"use strict";

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const https = require("https");
const http = require("http");
const yaml = require("js-yaml");

// ---------------------------------------------------------------------------
// Config from environment (mirrors .env values)
// ---------------------------------------------------------------------------
const cfg = {
  PIHOLE_IP: process.env.PIHOLE_IP || "192.168.8.145",
  PIHOLE_PASSWORD: process.env.PIHOLE_PASSWORD || "",
  CLASH_API: process.env.CLASH_API || "http://192.168.8.146:9090",
  CLASH_SECRET: process.env.CLASH_SECRET || "changeme",
  BUILD_JS: process.env.BUILD_JS || "/scripts/build.js",
  PROFILES_DIR: process.env.PROFILES_DIR || "/profiles",
  CONFIG_OUTPUT: process.env.CONFIG_OUTPUT || "/root/.config/mihomo/config.yaml",
  SYNC_INTERVAL_MS: parseInt(process.env.SYNC_INTERVAL_MS || "60000", 10), // default 60s
  POLICY_HASH_FILE: "/var/lib/clash-sync/policy.hash",
  DEBUG: process.env.DEBUG === "true",
};

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------
const log = (msg) =>
  console.log(`[${new Date().toISOString().replace("T", " ").slice(0, 19)}] ${msg}`);

const debug = (msg) => cfg.DEBUG && log(`[DEBUG] ${msg}`);

// ---------------------------------------------------------------------------
// HTTP helpers (supports http + https, ignores self-signed certs for Pi-hole)
// ---------------------------------------------------------------------------
function request(url, options = {}, body = null) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const lib = parsed.protocol === "https:" ? https : http;
    const req = lib.request(
      {
        hostname: parsed.hostname,
        port: parsed.port || (parsed.protocol === "https:" ? 443 : 80),
        path: parsed.pathname + parsed.search,
        method: options.method || "GET",
        headers: options.headers || {},
        rejectUnauthorized: false, // Pi-hole uses self-signed cert
        timeout: options.timeout || 10000,
      },
      (res) => {
        let data = "";
        res.on("data", (chunk) => (data += chunk));
        res.on("end", () => resolve({ status: res.statusCode, body: data }));
      }
    );
    req.on("error", reject);
    req.on("timeout", () => {
      req.destroy();
      reject(new Error(`Request timed out: ${url}`));
    });
    if (body) req.write(typeof body === "string" ? body : JSON.stringify(body));
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Step 1: Authenticate with Pi-hole v6 API
// ---------------------------------------------------------------------------
async function piholeAuth() {
  log(`Authenticating with Pi-hole at ${cfg.PIHOLE_IP}...`);
  const res = await request(
    `https://${cfg.PIHOLE_IP}/api/auth`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
    },
    JSON.stringify({ password: cfg.PIHOLE_PASSWORD })
  );

  const data = JSON.parse(res.body);
  const session = data?.session;
  if (!session?.valid) {
    throw new Error("Pi-hole auth failed — check PIHOLE_PASSWORD");
  }
  log("Authenticated OK");
  return session.sid;
}

// ---------------------------------------------------------------------------
// Step 2: Fetch DNS hosts from Pi-hole
// ---------------------------------------------------------------------------
async function fetchDnsHosts(sid) {
  const res = await request(
    `https://${cfg.PIHOLE_IP}/api/config/dns/hosts?detailed=true`,
    { headers: { "X-FTL-SID": sid } }
  );
  return JSON.parse(res.body);
}

// ---------------------------------------------------------------------------
// Step 3: Logout from Pi-hole
// ---------------------------------------------------------------------------
async function piholeLogout(sid) {
  try {
    await request(`https://${cfg.PIHOLE_IP}/api/auth`, {
      method: "DELETE",
      headers: { "X-FTL-SID": sid },
    });
  } catch (_) {
    // non-fatal
  }
}

// ---------------------------------------------------------------------------
// Step 4: Parse hosts + derive nameserver-policy patterns
// ---------------------------------------------------------------------------
const KNOWN_LOCAL_TLDS = new Set([
  "lan", "local", "internal", "home", "intranet", "corp", "private", "vpn", "lab",
]);

function parseDnsHosts(dnsData) {
  const rawRecords =
    dnsData?.config?.dns?.hosts?.value ?? [];

  const piholeHosts = {}; // domain → ip
  const allDomains = [];

  for (const entry of rawRecords) {
    const parts = entry.trim().split(/\s+/);
    if (parts.length < 2) continue;
    const ip = parts[0];
    for (const domain of parts.slice(1)) {
      piholeHosts[domain] = ip;
      allDomains.push(domain);
    }
  }

  // Build nameserver-policy patterns
  const patterns = new Set([
    "*.lan", "*.local", "*.internal", "*.home", "pi.hole",
  ]);

  for (const domain of allDomains) {
    const parts = domain.toLowerCase().split(".");
    const tld = parts[parts.length - 1];
    if (KNOWN_LOCAL_TLDS.has(tld)) {
      patterns.add(`*.${tld}`);
      if (parts.length > 2) {
        patterns.add(`*.${parts.slice(-2).join(".")}`);
      }
    } else {
      patterns.add(domain);
      if (parts.length >= 2) {
        patterns.add(`*.${parts.slice(-2).join(".")}`);
      }
    }
  }

  debug(`Parsed ${Object.keys(piholeHosts).length} hosts, ${patterns.size} policy patterns`);
  return { piholeHosts, policyPatterns: [...patterns].sort() };
}

// ---------------------------------------------------------------------------
// Step 5: Patch Clash runtime hosts via API
// ---------------------------------------------------------------------------
async function patchClashHosts(piholeHosts) {
  // Get existing Clash hosts first
  let currentHosts = {};
  try {
    const res = await request(cfg.CLASH_API + "/configs", {
      headers: { Authorization: `Bearer ${cfg.CLASH_SECRET}` },
    });
    currentHosts = JSON.parse(res.body)?.hosts ?? {};
  } catch (_) {
    // Non-fatal — proceed with empty
  }

  const merged = { ...currentHosts, ...piholeHosts };
  const res = await request(
    cfg.CLASH_API + "/configs",
    {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${cfg.CLASH_SECRET}`,
      },
    },
    JSON.stringify({ hosts: merged })
  );

  if (res.status === 200 || res.status === 204) {
    log(`OK: Synced ${Object.keys(merged).length} host(s) into Clash (HTTP ${res.status})`);
  } else {
    log(`WARN: Clash hosts PATCH returned HTTP ${res.status}`);
  }
}

// ---------------------------------------------------------------------------
// Step 6: Rebuild config if nameserver-policy changed
// ---------------------------------------------------------------------------
function hashPolicy(patterns) {
  return crypto
    .createHash("md5")
    .update(JSON.stringify(patterns))
    .digest("hex");
}

function loadSavedHash() {
  try {
    return fs.readFileSync(cfg.POLICY_HASH_FILE, "utf8").trim();
  } catch (_) {
    return "";
  }
}

function saveHash(hash) {
  fs.mkdirSync(path.dirname(cfg.POLICY_HASH_FILE), { recursive: true });
  fs.writeFileSync(cfg.POLICY_HASH_FILE, hash);
}

function updateNameserverPolicyInBuildJs(policyPatterns) {
  const content = fs.readFileSync(cfg.BUILD_JS, "utf8");

  const lines = ["    'nameserver-policy': {"];
  for (const pattern of policyPatterns) {
    lines.push(`      '${pattern}': PIHOLE_IP,`);
  }
  lines.push("    },");
  const newBlock = lines.join("\n");

  const updated = content.replace(
    /'nameserver-policy':\s*\{[^}]*\},/s,
    newBlock
  );

  fs.writeFileSync(cfg.BUILD_JS, updated);
  log(`Updated nameserver-policy: ${policyPatterns.length} patterns`);
}

async function rebuildAndReloadClash() {
  log("Rebuilding Clash config...");

  // Run build.js as a child process with NODE_PATH pointing to our node_modules
  // so js-yaml is resolvable even though build.js lives in /scripts
  await new Promise((resolve, reject) => {
    const { execFile } = require("child_process");
    execFile(
      process.execPath, // same node binary
      [cfg.BUILD_JS],
      { env: { ...process.env, NODE_PATH: "/app/node_modules" } },
      (err, stdout, stderr) => {
        if (stdout) stdout.trim().split("\n").forEach((l) => log(`[build] ${l}`));
        if (err) return reject(new Error(stderr || err.message));
        resolve();
      }
    );
  });

  // Hot-reload Clash
  const res = await request(
    `${cfg.CLASH_API}/configs?force=true`,
    {
      method: "PUT",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${cfg.CLASH_SECRET}`,
      },
    },
    JSON.stringify({ path: cfg.CONFIG_OUTPUT })
  );

  if (res.status === 200 || res.status === 204) {
    log(`OK: Clash hot-reloaded (HTTP ${res.status})`);
    return true;
  } else {
    log(`WARN: Clash reload returned HTTP ${res.status}`);
    return false;
  }
}

// ---------------------------------------------------------------------------
// Main sync cycle
// ---------------------------------------------------------------------------
let syncRunning = false;

async function runSync() {
  if (syncRunning) {
    log("Previous sync still running — skipping this tick");
    return;
  }
  syncRunning = true;

  let sid = null;
  try {
    // 1. Auth
    sid = await piholeAuth();

    // 2. Fetch
    const dnsData = await fetchDnsHosts(sid);
    if (cfg.DEBUG) {
      fs.writeFileSync("/tmp/pihole_dns_debug.json", JSON.stringify(dnsData, null, 2));
    }

    // 3. Logout (fire and forget)
    piholeLogout(sid).catch(() => {});
    sid = null;

    // 4. Parse
    const { piholeHosts, policyPatterns } = parseDnsHosts(dnsData);

    // 5. Patch Clash hosts at runtime
    await patchClashHosts(piholeHosts);

    // 6. Check if policy changed → rebuild config
    const currentHash = hashPolicy(policyPatterns);
    const savedHash = loadSavedHash();

    if (currentHash === savedHash) {
      log("Nameserver-policy unchanged, no rebuild needed.");
    } else {
      log("Nameserver-policy changed — updating build.js and rebuilding...");
      updateNameserverPolicyInBuildJs(policyPatterns);
      const ok = await rebuildAndReloadClash();
      if (ok) saveHash(currentHash);
    }

    log("Sync complete.");
  } catch (err) {
    log(`ERROR: ${err.message}`);
    if (cfg.DEBUG) console.error(err);
    // Ensure logout on error
    if (sid) piholeLogout(sid).catch(() => {});
  } finally {
    syncRunning = false;
  }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
log(`=== pihole-to-clash-sync starting (interval: ${cfg.SYNC_INTERVAL_MS}ms) ===`);
log(`Pi-hole: ${cfg.PIHOLE_IP} | Clash API: ${cfg.CLASH_API}`);

// Run immediately on startup, then on interval
runSync();
setInterval(runSync, cfg.SYNC_INTERVAL_MS);

// Graceful shutdown
process.on("SIGTERM", () => {
  log("Received SIGTERM — shutting down.");
  process.exit(0);
});
process.on("SIGINT", () => {
  log("Received SIGINT — shutting down.");
  process.exit(0);
});
