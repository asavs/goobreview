#!/usr/bin/env node
// Mint a GitHub App installation access token and fetch the App's slug,
// caching both on disk until shortly before expiry. Prints the requested
// field to stdout based on argv[2]: "token" (default), "slug",
// "discover", or "discover-target".
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
const GITHUB_FETCH_TIMEOUT_SECONDS = Number(process.env.REVIEWER_GITHUB_FETCH_TIMEOUT || 60);

function githubFetchTimeoutMs() {
  if (!Number.isFinite(GITHUB_FETCH_TIMEOUT_SECONDS) || GITHUB_FETCH_TIMEOUT_SECONDS <= 0) {
    die(`REVIEWER_GITHUB_FETCH_TIMEOUT must be a positive number of seconds; got ${process.env.REVIEWER_GITHUB_FETCH_TIMEOUT}`);
  }
  return GITHUB_FETCH_TIMEOUT_SECONDS * 1000;
}

function die(msg) {
  process.stderr.write(`[app-token] ${msg}\n`);
  process.exit(1);
}

function redactSensitive(value) {
  if (Array.isArray(value)) {
    return value.map(redactSensitive);
  }
  if (!value || typeof value !== "object") {
    return value;
  }

  return Object.fromEntries(
    Object.entries(value).map(([key, entry]) => [
      key,
      /token/i.test(key) ? "[REDACTED]" : redactSensitive(entry),
    ]),
  );
}

function safeJsonForLog(value) {
  return JSON.stringify(redactSensitive(value));
}

function nextActionForHttpStatus(status, operation) {
  if (status === 401) {
    return "Next action: verify REVIEWER_APP_ID belongs to the downloaded private key, then re-upload or re-paste the matching .pem.";
  }
  if (status === 404 && operation === "mint-installation-token") {
    return "Next action: verify REVIEWER_APP_INSTALLATION_ID is the installation for this App and target repository, then re-run scripts/configure.sh.";
  }
  if (status === 404) {
    return "Next action: verify the App is installed on the target repository and re-run scripts/configure.sh to rediscover the installation ID.";
  }
  return "";
}

function dieHttp(operation, label, status, body) {
  const guidance = nextActionForHttpStatus(status, operation);
  const suffix = guidance ? `\n${guidance}` : "";
  die(`${label} failed (${status}): ${body.slice(0, 500)}${suffix}`);
}

function requireEnv(name) {
  const v = process.env[name];
  if (!v) die(`missing required env: ${name}`);
  return v;
}

function usage(exitCode = 1) {
  process.stderr.write(`[app-token] usage:
  app-token.mjs [token|slug] [--app-id ID] [--installation-id ID] [--key-path PATH] [--state DIR]
  app-token.mjs discover <owner/repo> [--app-id ID] [--key-path PATH]
  app-token.mjs discover-target [--app-id ID] [--installation-id ID] [--key-path PATH]\n`);
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
if (!["token", "slug", "discover", "discover-target"].includes(what)) {
  die(`unknown query: ${what}; expected 'token', 'slug', 'discover', or 'discover-target'`);
}

const appId = configuredValue("REVIEWER_APP_ID", opts.appId);
const keyPath = configuredValue("REVIEWER_APP_PRIVATE_KEY_PATH", opts.keyPath);
if (!existsSync(keyPath)) die(`private key not found: ${keyPath}`);

// Discovery only needs App ID + key. `discover-target` may optionally use
// REVIEWER_APP_INSTALLATION_ID to constrain which installation to inspect.
let installationId, stateDir, cachePath;
if (!["discover", "discover-target"].includes(what)) {
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

async function githubFetch(operation, url, options) {
  const controller = new AbortController();
  const timeoutMs = githubFetchTimeoutMs();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } catch (err) {
    if (err && err.name === "AbortError") {
      die(`${operation} timed out after ${GITHUB_FETCH_TIMEOUT_SECONDS}s: ${url}`);
    }
    die(`${operation} failed before response: ${err && err.message ? err.message : String(err)}`);
  } finally {
    clearTimeout(timeout);
  }
}

async function ghJson(url, jwt) {
  const resp = await githubFetch("GET GitHub JSON", url, {
    headers: {
      Authorization: `Bearer ${jwt}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "goobreview-app-token",
    },
  });
  if (!resp.ok) {
    const body = await resp.text();
    dieHttp("get-app-json", `GET ${url}`, resp.status, body);
  }
  return resp.json();
}

async function ghJsonWithToken(url, token) {
  const resp = await githubFetch("GET GitHub installation JSON", url, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "goobreview-app-token",
    },
  });
  if (!resp.ok) {
    const body = await resp.text();
    dieHttp("get-installation-json", `GET ${url}`, resp.status, body);
  }
  return resp.json();
}

async function mintInstallationToken(jwt, id) {
  const tokenUrl = `https://api.github.com/app/installations/${id}/access_tokens`;
  const tokenResp = await githubFetch("POST GitHub installation token", tokenUrl, {
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
    dieHttp("mint-installation-token", "token mint", tokenResp.status, body);
  }
  const tokenJson = await tokenResp.json();
  if (!tokenJson.token || !tokenJson.expires_at) {
    die(`unexpected token response: ${safeJsonForLog(tokenJson).slice(0, 300)}`);
  }
  return tokenJson;
}

async function refresh() {
  const pem = readFileSync(keyPath, "utf8");
  const jwt = signJwt(pem);

  const appInfo = await ghJson("https://api.github.com/app", jwt);
  if (typeof appInfo.slug !== "string") {
    die(`unexpected /app response: ${JSON.stringify(appInfo).slice(0, 300)}`);
  }

  const tokenJson = await mintInstallationToken(jwt, installationId);

  writeCache(tokenJson.token, tokenJson.expires_at, appInfo.slug);
  return { token: tokenJson.token, slug: appInfo.slug };
}

async function discoverTarget() {
  const pem = readFileSync(keyPath, "utf8");
  const jwt = signJwt(pem);
  const constrainedId = opts.installationId || process.env.REVIEWER_APP_INSTALLATION_ID || "";
  if (constrainedId && !/^\d+$/.test(constrainedId)) {
    die(`REVIEWER_APP_INSTALLATION_ID must be numeric; got '${constrainedId}'`);
  }

  let installations;
  if (constrainedId) {
    installations = [{ id: Number(constrainedId) }];
  } else {
    const data = await ghJson("https://api.github.com/app/installations?per_page=100", jwt);
    if (!Array.isArray(data)) {
      die(`unexpected /app/installations response: ${JSON.stringify(data).slice(0, 300)}`);
    }
    installations = data;
  }

  const candidates = [];
  for (const installation of installations) {
    if (typeof installation.id !== "number") continue;
    const tokenJson = await mintInstallationToken(jwt, installation.id);
    const repos = await ghJsonWithToken("https://api.github.com/installation/repositories?per_page=100", tokenJson.token);
    if (!Array.isArray(repos.repositories)) {
      die(`unexpected /installation/repositories response: ${JSON.stringify(repos).slice(0, 300)}`);
    }
    if (typeof repos.total_count === "number" && repos.total_count > repos.repositories.length) {
      die(`installation ${installation.id} exposes ${repos.total_count} repositories; set REVIEWER_REPO or pass --repo`);
    }
    for (const repo of repos.repositories) {
      if (typeof repo.full_name === "string") {
        candidates.push({ repo: repo.full_name, installation_id: String(installation.id) });
      }
    }
  }

  const unique = [];
  const seen = new Set();
  for (const candidate of candidates) {
    const key = `${candidate.installation_id}:${candidate.repo}`;
    if (seen.has(key)) continue;
    seen.add(key);
    unique.push(candidate);
  }

  if (unique.length === 0) {
    die("no repositories found for this GitHub App installation");
  }
  if (unique.length > 1) {
    const preview = unique.slice(0, 10).map((candidate) => candidate.repo).join(", ");
    const suffix = unique.length > 10 ? `, ... (+${unique.length - 10} more)` : "";
    die(`multiple repositories found (${preview}${suffix}); set REVIEWER_REPO or pass --repo`);
  }

  process.stdout.write(JSON.stringify(unique[0]));
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
} else if (what === "discover-target") {
  await discoverTarget();
} else {
  const data = readCache() || (await refresh());
  process.stdout.write(what === "slug" ? data.slug : data.token);
}
