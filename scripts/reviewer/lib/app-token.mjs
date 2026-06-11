#!/usr/bin/env node
// Mint a GitHub App installation access token and fetch the App's slug,
// caching both on disk until shortly before expiry. Prints the requested
// field to stdout based on argv[2]: "token" (default) or "slug".
//
// Inputs (env by default; direct CLI flags are accepted for diagnostics):
//   REVIEWER_APP_ID                  Numeric App ID from the App settings page.
//   REVIEWER_APP_INSTALLATION_ID     Installation ID (per-account or per-repo).
//   REVIEWER_APP_PRIVATE_KEY_PATH    Path to the App's .pem private key.
//   REVIEWER_STATE                   Where to cache between ticks.
//
// Exits non-zero with a message to stderr on any failure.

import { createSign } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";

const REFRESH_BEFORE_EXPIRY_SECONDS = 300;

function die(msg) {
  process.stderr.write(`[app-token] ${msg}\n`);
  process.exit(1);
}

function requireEnv(name) {
  const v = process.env[name];
  if (!v) die(`missing required env: ${name}`);
  return v;
}

function usage(exitCode = 1) {
  process.stderr.write(`[app-token] usage:
  app-token.mjs [token|slug] [--app-id ID] [--installation-id ID] [--key-path PATH] [--state DIR]
  app-token.mjs discover <owner/repo> [--app-id ID] [--key-path PATH]\n`);
  process.exit(exitCode);
}

function parseArgs(argv) {
  const args = [...argv];
  let what = "token";
  let target = "";
  const opts = {};

  if (args[0] && !args[0].startsWith("--")) {
    what = args.shift();
  }

  while (args.length > 0) {
    const arg = args.shift();
    switch (arg) {
      case "--app-id":
        opts.appId = args.shift() || "";
        break;
      case "--installation-id":
        opts.installationId = args.shift() || "";
        break;
      case "--key-path":
        opts.keyPath = args.shift() || "";
        break;
      case "--state":
        opts.stateDir = args.shift() || "";
        break;
      case "-h":
      case "--help":
        usage(0);
        break;
      default:
        if (arg.startsWith("--")) die(`unknown option: ${arg}`);
        if (!target) {
          target = arg;
        } else {
          die(`unexpected argument: ${arg}`);
        }
    }
  }

  return { what, target, opts };
}

function configuredValue(name, value) {
  return value || requireEnv(name);
}

const { what, target, opts } = parseArgs(process.argv.slice(2));
if (!["token", "slug", "discover"].includes(what)) {
  die(`unknown query: ${what}; expected 'token', 'slug', or 'discover'`);
}

const appId = configuredValue("REVIEWER_APP_ID", opts.appId);
const keyPath = configuredValue("REVIEWER_APP_PRIVATE_KEY_PATH", opts.keyPath);
if (!existsSync(keyPath)) die(`private key not found: ${keyPath}`);

// `discover` only needs App ID + key (no installation, no cache).
let installationId, stateDir, cachePath;
if (what !== "discover") {
  installationId = configuredValue("REVIEWER_APP_INSTALLATION_ID", opts.installationId);
  stateDir = configuredValue("REVIEWER_STATE", opts.stateDir);
  mkdirSync(stateDir, { recursive: true });
  cachePath = join(stateDir, "app_token.json");
}

function b64url(input) {
  const b = Buffer.isBuffer(input) ? input : Buffer.from(input);
  return b.toString("base64").replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function signJwt(privateKeyPem) {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const payload = { iat: now - 30, exp: now + 540, iss: String(appId) };
  const headerB64 = b64url(JSON.stringify(header));
  const payloadB64 = b64url(JSON.stringify(payload));
  const signingInput = `${headerB64}.${payloadB64}`;
  const signer = createSign("RSA-SHA256");
  signer.update(signingInput);
  const signature = b64url(signer.sign(privateKeyPem));
  return `${signingInput}.${signature}`;
}

function readCache() {
  if (!existsSync(cachePath)) return null;
  try {
    const raw = JSON.parse(readFileSync(cachePath, "utf8"));
    if (raw.app_id !== appId) return null;
    if (raw.installation_id !== installationId) return null;
    if (typeof raw.token !== "string" || typeof raw.expires_at !== "number") return null;
    if (typeof raw.slug !== "string") return null;
    const remaining = raw.expires_at - Math.floor(Date.now() / 1000);
    if (remaining < REFRESH_BEFORE_EXPIRY_SECONDS) return null;
    return raw;
  } catch {
    return null;
  }
}

function writeCache(token, expiresAtIso, slug) {
  const data = {
    app_id: appId,
    installation_id: installationId,
    slug,
    token,
    expires_at: Math.floor(new Date(expiresAtIso).getTime() / 1000),
  };
  writeFileSync(cachePath, JSON.stringify(data), { mode: 0o600 });
}

async function ghJson(url, jwt) {
  const resp = await fetch(url, {
    headers: {
      Authorization: `Bearer ${jwt}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "goobreview-app-token",
    },
  });
  if (!resp.ok) {
    const body = await resp.text();
    die(`GET ${url} failed (${resp.status}): ${body.slice(0, 500)}`);
  }
  return resp.json();
}

async function refresh() {
  const pem = readFileSync(keyPath, "utf8");
  const jwt = signJwt(pem);

  const appInfo = await ghJson("https://api.github.com/app", jwt);
  if (typeof appInfo.slug !== "string") {
    die(`unexpected /app response: ${JSON.stringify(appInfo).slice(0, 300)}`);
  }

  const tokenUrl = `https://api.github.com/app/installations/${installationId}/access_tokens`;
  const tokenResp = await fetch(tokenUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${jwt}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "goobreview-app-token",
    },
  });
  if (!tokenResp.ok) {
    const body = await tokenResp.text();
    die(`token mint failed (${tokenResp.status}): ${body.slice(0, 500)}`);
  }
  const tokenJson = await tokenResp.json();
  if (!tokenJson.token || !tokenJson.expires_at) {
    die(`unexpected token response: ${JSON.stringify(tokenJson).slice(0, 300)}`);
  }

  writeCache(tokenJson.token, tokenJson.expires_at, appInfo.slug);
  return { token: tokenJson.token, slug: appInfo.slug };
}

if (what === "discover") {
  if (!target || !/^[^/]+\/[^/]+$/.test(target)) {
    usage();
  }
  const pem = readFileSync(keyPath, "utf8");
  const jwt = signJwt(pem);
  const info = await ghJson(`https://api.github.com/repos/${target}/installation`, jwt);
  if (typeof info.id !== "number") {
    die(`unexpected /installation response: ${JSON.stringify(info).slice(0, 300)}`);
  }
  process.stdout.write(String(info.id));
} else {
  const data = readCache() || (await refresh());
  process.stdout.write(what === "slug" ? data.slug : data.token);
}
