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
const { createServer } = require("http");

// ---------------------------------------------------------------------------
// Config from environment
// ---------------------------------------------------------------------------
const cfg = {
  PIHOLE_IP: process.env.PIHOLE_IP || "192.168.8.145",
  PIHOLE_PASSWORD: process.env.PIHOLE_PASSWORD || "",
  CLASH_API: process.env.CLASH_API || "http://192.168.8.146:9090",
  CLASH_SECRET: process.env.CLASH_SECRET || "changeme",
  BUILD_JS: process.env.BUILD_JS || "/scripts/build.js",
  PROFILES_DIR: process.env.PROFILES_DIR || "/profiles",
  CONFIG_OUTPUT: process.env.CONFIG_OUTPUT || "/root/.config/mihomo/config.yaml",
  SYNC_INTERVAL_MS: parseInt(process.env.SYNC_INTERVAL_MS || "60000", 10),
  POLICY_HASH_FILE: "/var/lib/clash-sync/policy.hash",
  DEBUG: process.env.DEBUG === "true",
  PORT: process.env.PORT || 8787,
};

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------
const log = (msg) =>
  console.log(`[${new Date().toISOString().replace("T", " ").slice(0, 19)}] ${msg}`);

const debug = (msg) => cfg.DEBUG && log(`[DEBUG] ${msg}`);

// ---------------------------------------------------------------------------
// HTTP helpers
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
        rejectUnauthorized: false,
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
// Pi-hole auth
// ---------------------------------------------------------------------------
async function piholeAuth() {
  log(`Authenticating with Pi-hole at ${cfg.PIHOLE_IP}...`);

  const res = await request(`https://${cfg.PIHOLE_IP}/api/auth`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
  }, JSON.stringify({ password: cfg.PIHOLE_PASSWORD }));

  const data = JSON.parse(res.body);
  const session = data?.session;

  if (!session?.valid) {
    throw new Error("Pi-hole auth failed — check PIHOLE_PASSWORD");
  }

  log("Authenticated OK");
  return session.sid;
}

// ---------------------------------------------------------------------------
// Fetch DNS hosts
// ---------------------------------------------------------------------------
async function fetchDnsHosts(sid) {
  const res = await request(
    `https://${cfg.PIHOLE_IP}/api/config/dns/hosts?detailed=true`,
    { headers: { "X-FTL-SID": sid } }
  );

  return JSON.parse(res.body);
}

// ---------------------------------------------------------------------------
// Logout
// ---------------------------------------------------------------------------
async function piholeLogout(sid) {
  try {
    await request(`https://${cfg.PIHOLE_IP}/api/auth`, {
      method: "DELETE",
      headers: { "X-FTL-SID": sid },
    });
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// DNS parsing
// ---------------------------------------------------------------------------
const KNOWN_LOCAL_TLDS = new Set([
  "lan", "local", "internal", "home", "intranet", "corp", "private", "vpn", "lab",
]);

function parseDnsHosts(dnsData) {
  const rawRecords = dnsData?.config?.dns?.hosts?.value ?? [];

  const piholeHosts = {};
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

  return {
    piholeHosts,
    policyPatterns: [...patterns].sort(),
  };
}

// ---------------------------------------------------------------------------
// Clash connection check (USED BY API)
// ---------------------------------------------------------------------------
async function checkClashConnection() {
  try {
    const res = await request(cfg.CLASH_API + "/configs", {
      headers: {
        Authorization: `Bearer ${cfg.CLASH_SECRET}`,
      },
    });

    if (res.status === 200) {
      return { ok: true };
    }

    return { ok: false, status: res.status };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

// ---------------------------------------------------------------------------
// REST API SERVER
// ---------------------------------------------------------------------------
function startApiServer() {
  const server = createServer(async (req, res) => {
    if (req.url === "/health" && req.method === "GET") {
      const clash = await checkClashConnection();

      res.writeHead(clash.ok ? 200 : 500, {
        "Content-Type": "application/json",
      });

      res.end(JSON.stringify({
        status: clash.ok ? "ok" : "fail",
        clash,
        timestamp: new Date().toISOString(),
      }));
      return;
    }

    if (req.url === "/ping" && req.method === "GET") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    res.writeHead(404);
    res.end("Not Found");
  });

  server.listen(cfg.PORT, () => {
    log(`REST API running on http://0.0.0.0:${cfg.PORT}`);
  });
}

// ---------------------------------------------------------------------------
// Sync cycle
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
    sid = await piholeAuth();

    const dnsData = await fetchDnsHosts(sid);

    piholeLogout(sid).catch(() => {});
    sid = null;

    const { piholeHosts, policyPatterns } = parseDnsHosts(dnsData);

    log(`Parsed ${Object.keys(piholeHosts).length} hosts`);

    log(`Sync complete.`);
  } catch (err) {
    log(`ERROR: ${err.message}`);
    if (sid) piholeLogout(sid).catch(() => {});
  } finally {
    syncRunning = false;
  }
}

// ---------------------------------------------------------------------------
// ENTRY
// ---------------------------------------------------------------------------
log(`=== pihole-to-clash-sync starting ===`);
log(`Pi-hole: ${cfg.PIHOLE_IP} | Clash: ${cfg.CLASH_API}`);

startApiServer();

runSync();
setInterval(runSync, cfg.SYNC_INTERVAL_MS);

process.on("SIGTERM", () => process.exit(0));
process.on("SIGINT", () => process.exit(0));