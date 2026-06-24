#!/usr/bin/env node
// Smoke test for register-server.mjs. Mocks GitHub's API (api.github.com) and
// drives the real server over localhost, asserting the registration lifecycle:
// query-param tolerance, key verification, and repo auto-detection.
//
// Runs in two modes, selected by GOOBREVIEW_TARGET_REPO (the same env the
// server reads):
//   unset  -> no --repo: auto-detect whichever single repo is installed
//   set    -> --repo filter: only an install matching that repo is accepted
//
// Network-free and self-contained; intended for CI (Linux Node) and local runs.
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, '../../..');
const PORT = Number(process.env.GOOBREVIEW_REGISTER_PORT || 8771);
const FILTER = process.env.GOOBREVIEW_TARGET_REPO || ''; // '' => no --repo mode
const BASE = `http://localhost:${PORT}`;

const OUT = fs.mkdtempSync(path.join(os.tmpdir(), 'reg-smoke-'));
process.env.GOOBREVIEW_REGISTER_OUTPUT = OUT;
process.env.GOOBREVIEW_MANIFEST = path.join(REPO_ROOT, 'config/app-manifest.json');
process.env.GOOBREVIEW_REGISTER_PORT = String(PORT);

let failed = false;
function check(name, cond) {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}`);
  if (!cond) failed = true;
}
function finish() {
  console.log(failed ? `\nRESULT: FAILED (mode=${FILTER || 'no-repo'})` : `\nRESULT: OK (mode=${FILTER || 'no-repo'})`);
  process.exit(failed ? 1 : 0);
}

// A real RSA key so the server's RS256 JWT signing succeeds.
const { privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const PEM = privateKey.export({ type: 'pkcs1', format: 'pem' });

// Mutable mock state so one server instance can walk the whole lifecycle.
let installations = []; // e.g. [{ id: 555 }]
let reposByInstallation = {}; // id -> [{ full_name }]

const realFetch = globalThis.fetch;
globalThis.fetch = async (url, opts = {}) => {
  const u = String(url);
  if (u.startsWith(BASE)) return realFetch(url, opts); // let test traffic through
  const json = (obj, status = 200) =>
    new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json' } });
  if (u === 'https://api.github.com/app') {
    return json({ id: 123, slug: 'goob-linus', name: 'Goob Linus', owner: { login: 'asa' }, html_url: 'https://github.com/apps/goob-linus' });
  }
  if (u.startsWith('https://api.github.com/app/installations?')) {
    return json(installations);
  }
  const tok = u.match(/\/app\/installations\/(\d+)\/access_tokens$/);
  if (tok) return json({ token: `ghs_${tok[1]}` });
  if (u.startsWith('https://api.github.com/installation/repositories')) {
    // Identify the installation from the bearer token (ghs_<id>).
    const auth = String(opts.headers?.Authorization || '');
    const id = auth.replace('Bearer ghs_', '');
    const repos = reposByInstallation[id] || [];
    return json({ total_count: repos.length, repositories: repos });
  }
  throw new Error(`unexpected fetch: ${u}`);
};

async function getJson(url) {
  const resp = await fetch(`${BASE}${url}`);
  let body = null;
  try { body = await resp.json(); } catch { /* non-JSON */ }
  return { status: resp.status, body };
}

async function uploadKey(appId, pem) {
  const fd = new FormData();
  fd.set('app_id', appId);
  fd.set('pem_file', new Blob([pem], { type: 'application/x-pem-file' }), 'app-key.pem');
  return fetch(`${BASE}/complete`, { method: 'POST', body: fd });
}

await import(pathToFileURL(path.join(REPO_ROOT, 'scripts/lib/register-server.mjs')).href);
await new Promise((r) => setTimeout(r, 200)); // let the server bind

// 1. Cloud Shell appends query params; the root route must still answer 200.
check('GET /?authuser=0 -> 200', (await fetch(`${BASE}/?authuser=0`)).status === 200);

// 2. /installation before the key is verified -> 409.
check('GET /installation pre-verify -> 409', (await getJson('/installation')).status === 409);

// 3. A non-PEM upload is rejected.
check('POST /complete bad key -> 400', (await uploadKey('123', 'not a pem')).status === 400);

// 4. A valid key + App ID verifies.
check('POST /complete valid -> 200', (await uploadKey('123', PEM)).status === 200);

// 5. No installation yet -> pending.
installations = [];
check('GET /installation, none installed -> pending', (await getJson('/installation?authuser=0')).body?.status === 'pending');

if (!FILTER) {
  // 6. Two repos under one installation -> disambiguation, no auto-pick.
  installations = [{ id: 555 }];
  reposByInstallation = { 555: [{ full_name: 'someuser/repo-a' }, { full_name: 'someuser/repo-b' }] };
  const multi = (await getJson('/installation')).body;
  check('two repos -> multiple', multi?.status === 'multiple');
  check('multiple lists both repos', Array.isArray(multi?.repos) && multi.repos.length === 2);

  // 7. Narrowed to one repo -> auto-detected and persisted. (Triggers exit.)
  reposByInstallation = { 555: [{ full_name: 'someuser/their-repo' }] };
  const ok = (await getJson('/installation')).body;
  check('one repo -> installed', ok?.status === 'installed');
  check('detected repo = someuser/their-repo', ok?.repo === 'someuser/their-repo');
  check('installation_id = 555', ok?.installation_id === '555');
} else {
  // 6. With --repo set, an install on a different repo is ignored (still pending).
  installations = [{ id: 555 }];
  reposByInstallation = { 555: [{ full_name: 'someone/unrelated' }] };
  check('--repo filter, non-match -> pending', (await getJson('/installation')).body?.status === 'pending');

  // 7. An install on the requested repo is accepted. (Triggers exit.)
  reposByInstallation = { 555: [{ full_name: FILTER }] };
  const ok = (await getJson('/installation')).body;
  check('--repo filter, match -> installed', ok?.status === 'installed');
  check(`detected repo = ${FILTER}`, ok?.repo === FILTER);
}

// app.json must carry repo + installation_id for register-app.sh to consume.
const appJson = JSON.parse(fs.readFileSync(path.join(OUT, 'app.json'), 'utf8'));
const expectedRepo = FILTER || 'someuser/their-repo';
check('app.json.repo persisted', appJson.repo === expectedRepo);
check('app.json.installation_id persisted', appJson.installation_id === '555');

finish();
