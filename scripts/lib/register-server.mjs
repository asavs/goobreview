#!/usr/bin/env node
// Local helper for register-app.sh. Renders a page with a pre-filled link to
// GitHub's App-creation form (URL params, same-origin so cookies work in any
// browser); accepts the resulting .pem and App ID from the user; signs a JWT
// to derive the App slug; writes app-key.pem + app.json to
// GOOBREVIEW_REGISTER_OUTPUT and exits.

import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const PORT = Number(process.env.GOOBREVIEW_REGISTER_PORT || 8080);
const OUTPUT_DIR = process.env.GOOBREVIEW_REGISTER_OUTPUT;
const MANIFEST_PATH = process.env.GOOBREVIEW_MANIFEST;
const GH_OWNER_ORG = process.env.GOOBREVIEW_GH_ORG || '';
const TARGET_REPO = process.env.GOOBREVIEW_TARGET_REPO || '';

function die(msg) {
  console.error(`[register-server] ${msg}`);
  process.exit(1);
}

if (!OUTPUT_DIR) die('GOOBREVIEW_REGISTER_OUTPUT not set');
if (!MANIFEST_PATH) die('GOOBREVIEW_MANIFEST not set');
if (!fs.existsSync(MANIFEST_PATH)) die(`manifest file not found: ${MANIFEST_PATH}`);
if (TARGET_REPO && !/^[^/]+\/[^/]+$/.test(TARGET_REPO)) die(`invalid GOOBREVIEW_TARGET_REPO: ${TARGET_REPO}`);

const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'));
let verifiedApp = null;

function htmlEscape(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function buildGitHubFormUrl() {
  const base = GH_OWNER_ORG
    ? `https://github.com/organizations/${encodeURIComponent(GH_OWNER_ORG)}/settings/apps/new`
    : `https://github.com/settings/apps/new`;
  const params = new URLSearchParams();
  if (manifest.name) params.set('name', manifest.name);
  if (manifest.url) params.set('url', manifest.url);
  if (manifest.description) params.set('description', manifest.description);
  if (typeof manifest.public === 'boolean') params.set('public', String(manifest.public));
  const webhookActive = manifest.hook_attributes?.active;
  if (typeof webhookActive === 'boolean') params.set('webhook_active', String(webhookActive));
  for (const [perm, level] of Object.entries(manifest.default_permissions || {})) {
    params.set(perm, level);
  }
  for (const event of manifest.default_events || []) {
    params.append('events[]', event);
  }
  return `${base}?${params.toString()}`;
}

function renderForm() {
  const githubUrl = buildGitHubFormUrl();
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Register GoobReview App</title>
  <style>
    body { font: 15px/1.5 system-ui, sans-serif; max-width: 640px; margin: 3rem auto; padding: 0 1rem; color: #222; }
    h1 { margin-top: 0; }
    h2 { font-size: 17px; margin: 2em 0 0.5em; }
    a.btn, button { display: inline-block; font-size: 16px; padding: 0.6em 1.2em; background: #2da44e; color: white; text-decoration: none; border: 0; border-radius: 6px; cursor: pointer; font: inherit; font-weight: 500; }
    a.btn:hover, button:hover { background: #2c974b; }
    .upload { background: #f6f8fa; border-radius: 6px; padding: 1.2em 1.5em; margin: 1em 0; }
    .field { margin: 0.8em 0; }
    .field label { display: block; font-weight: 600; margin-bottom: 0.2em; }
    .field input { width: 100%; padding: 0.5em; box-sizing: border-box; font: inherit; }
    .muted { color: #57606a; font-size: 13px; }
    code { background: #f6f8fa; padding: 1px 5px; border-radius: 3px; font-size: 13px; }
  </style>
</head>
<body>
  <h1>Register your GoobReview App</h1>

  <h2>1. Create the App on GitHub</h2>
  <p>Open the pre-filled GitHub form in the tab where you're already signed in. Name, homepage, description, webhook setting, and all five permissions are already populated &mdash; scroll to the bottom and click <strong>Create GitHub App</strong>.</p>
  <p><a class="btn" href="${htmlEscape(githubUrl)}" target="_blank" rel="noopener">Open pre-filled GitHub form &rarr;</a></p>
  <p class="muted">If <code>${htmlEscape(manifest.name)}</code> is taken, change the name on the GitHub form &mdash; it has to be globally unique. Then on the App's settings page, scroll to <strong>Private keys</strong> &rarr; <strong>Generate a private key</strong> to download the <code>.pem</code>, and note the <strong>App ID</strong> at the top.</p>

  <h2>2. Upload the key</h2>
  <p>Submit the downloaded <code>.pem</code> and the App ID below. <code>register-app.sh</code> forwards the key to your VM; after success, delete the browser download.</p>
  ${TARGET_REPO ? `<p class="muted">After the key is verified, this page will ask you to install the App on <code>${htmlEscape(TARGET_REPO)}</code> and will detect the installation ID automatically.</p>` : ''}
  <div class="upload">
    <form method="POST" action="/complete" enctype="multipart/form-data">
      <div class="field">
        <label for="app_id">App ID</label>
        <input type="number" id="app_id" name="app_id" required placeholder="e.g. 1234567" autofocus>
      </div>
      <div class="field">
        <label for="pem_file">Private key (.pem)</label>
        <input type="file" id="pem_file" name="pem_file" accept=".pem,application/x-pem-file,text/plain" required>
      </div>
      <button type="submit">Finish setup &rarr;</button>
    </form>
  </div>
</body>
</html>`;
}

function renderSuccess(summary) {
  const installUrl = `https://github.com/apps/${encodeURIComponent(summary.slug)}/installations/new`;
  const repoHtml = TARGET_REPO ? `<code>${htmlEscape(TARGET_REPO)}</code>` : 'your target repo';
  const pollingHtml = TARGET_REPO ? `
  <p><strong>Final step:</strong> install the App on ${repoHtml}, then keep this tab open. The helper will detect the installation ID and exit.</p>
  <p><a class="btn" href="${htmlEscape(installUrl)}" target="_blank" rel="noopener">Install ${htmlEscape(summary.name)} on ${repoHtml} &rarr;</a></p>
  <p id="install-status" class="muted">Waiting for installation on ${repoHtml}...</p>
  <script>
    const statusEl = document.getElementById('install-status');
    async function pollInstallation() {
      try {
        const resp = await fetch('/installation');
        const data = await resp.json();
        if (data.status === 'installed') {
          statusEl.innerHTML = 'Installation detected. Installation ID <code>' + data.installation_id + '</code> was saved for configure.sh.';
          return;
        }
        statusEl.textContent = data.message || 'Still waiting for installation...';
      } catch (err) {
        statusEl.textContent = 'Still waiting for installation...';
      }
      setTimeout(pollInstallation, 5000);
    }
    setTimeout(pollInstallation, 2000);
  </script>` : `
  <p><strong>One step left:</strong> install the App on your target repo.</p>
  <p><a class="btn" href="${htmlEscape(installUrl)}" target="_blank" rel="noopener">Install ${htmlEscape(summary.name)} on a repo &rarr;</a></p>
  <p class="muted">Pick "Only select repositories" and choose the repo GoobReview will review. After install, return to your terminal &mdash; the register script has already exited and printed the next command to run.</p>`;
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>GoobReview App registered</title>
  <style>
    body { font: 15px/1.5 system-ui, sans-serif; max-width: 640px; margin: 4rem auto; padding: 0 1rem; color: #222; }
    h1 { margin-top: 0; }
    a.btn { display: inline-block; font-size: 16px; padding: 0.75em 1.5em; background: #2da44e; color: white; text-decoration: none; border-radius: 6px; }
    a.btn:hover { background: #2c974b; }
    code { background: #f6f8fa; padding: 1px 5px; border-radius: 3px; font-size: 13px; }
    .muted { color: #57606a; font-size: 13px; }
  </style>
</head>
<body>
  <h1>App registered: ${htmlEscape(summary.name)}</h1>
  <p>App ID <code>${htmlEscape(summary.id)}</code>, slug <code>${htmlEscape(summary.slug)}</code>. The private key is on the VM; delete the downloaded <code>.pem</code> from this browser.</p>
  ${pollingHtml}
</body>
</html>`;
}

function renderError(message) {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Registration failed</title>
  <style>
    body { font: 15px/1.5 system-ui, sans-serif; max-width: 640px; margin: 4rem auto; padding: 0 1rem; color: #222; }
    h1 { margin-top: 0; color: #b62324; }
    code { background: #f6f8fa; padding: 1px 5px; border-radius: 3px; font-size: 13px; }
    a { color: #0969da; }
  </style>
</head>
<body>
  <h1>Registration failed</h1>
  <p>${htmlEscape(message)}</p>
  <p><a href="/">&larr; Back to the form</a></p>
</body>
</html>`;
}

function base64Url(input) {
  const buf = Buffer.isBuffer(input) ? input : Buffer.from(input);
  return buf.toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function signAppJwt(appId, privateKeyPem) {
  const now = Math.floor(Date.now() / 1000);
  const header = base64Url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const payload = base64Url(JSON.stringify({ iat: now - 30, exp: now + 540, iss: String(appId) }));
  const signingInput = `${header}.${payload}`;
  const signer = crypto.createSign('RSA-SHA256');
  signer.update(signingInput);
  const sig = base64Url(signer.sign(privateKeyPem));
  return `${signingInput}.${sig}`;
}

async function fetchAppMeta(jwt) {
  const resp = await fetch('https://api.github.com/app', {
    headers: {
      Authorization: `Bearer ${jwt}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'goobreview-register',
      'X-GitHub-Api-Version': '2022-11-28',
    },
  });
  if (!resp.ok) {
    const body = await resp.text();
    throw new Error(`GitHub rejected the App ID + key combination (${resp.status}): ${body.slice(0, 200)}`);
  }
  return resp.json();
}

async function fetchRepoInstallation(jwt, repo) {
  const resp = await fetch(`https://api.github.com/repos/${repo}/installation`, {
    headers: {
      Authorization: `Bearer ${jwt}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'goobreview-register',
      'X-GitHub-Api-Version': '2022-11-28',
    },
  });
  if (resp.status === 404) return null;
  if (!resp.ok) {
    const body = await resp.text();
    throw new Error(`GitHub installation lookup failed (${resp.status}): ${body.slice(0, 200)}`);
  }
  return resp.json();
}

async function parseMultipart(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = Buffer.concat(chunks);
  const request = new Request('http://localhost/', {
    method: 'POST',
    headers: { 'content-type': req.headers['content-type'] || '' },
    body,
  });
  return request.formData();
}

function saveResult(meta, pemContent, installation = null) {
  fs.mkdirSync(OUTPUT_DIR, { recursive: true, mode: 0o700 });
  fs.writeFileSync(path.join(OUTPUT_DIR, 'app-key.pem'), pemContent, { mode: 0o600 });
  const summary = {
    id: String(meta.id),
    slug: meta.slug,
    name: meta.name || meta.slug,
    owner: meta.owner?.login || '',
    html_url: meta.html_url || '',
  };
  if (TARGET_REPO) summary.repo = TARGET_REPO;
  if (installation?.id) summary.installation_id = String(installation.id);
  fs.writeFileSync(path.join(OUTPUT_DIR, 'app.json'), JSON.stringify(summary, null, 2));
  return summary;
}

function sendHtml(res, status, html) {
  res.writeHead(status, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(html);
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === 'GET' && req.url === '/') {
      sendHtml(res, 200, renderForm());
      return;
    }

    if (req.method === 'GET' && req.url === '/installation') {
      if (!TARGET_REPO) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'disabled' }));
        return;
      }
      if (!verifiedApp) {
        res.writeHead(409, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'pending', message: 'Upload and verify the App key first.' }));
        return;
      }

      let installation;
      try {
        installation = await fetchRepoInstallation(verifiedApp.jwt, TARGET_REPO);
      } catch (err) {
        res.writeHead(502, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'error', message: err.message }));
        return;
      }

      if (!installation?.id) {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          status: 'pending',
          message: `Waiting for ${verifiedApp.summary.name} to be installed on ${TARGET_REPO}...`,
        }));
        return;
      }

      const summary = saveResult(verifiedApp.meta, verifiedApp.pemContent, installation);
      verifiedApp.summary = summary;
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'installed', installation_id: summary.installation_id }));
      console.error(`[register-server] Installation ${summary.installation_id} detected for ${TARGET_REPO}.`);
      setTimeout(() => server.close(() => process.exit(0)), 1500);
      return;
    }

    if (req.method === 'POST' && req.url === '/complete') {
      const form = await parseMultipart(req);
      const appId = String(form.get('app_id') || '').trim();
      const pemFile = form.get('pem_file');

      if (!/^\d+$/.test(appId)) {
        sendHtml(res, 400, renderError('App ID must be a positive integer.'));
        return;
      }
      if (!pemFile || typeof pemFile.text !== 'function') {
        sendHtml(res, 400, renderError('Choose a .pem file before submitting.'));
        return;
      }

      const pemContent = await pemFile.text();
      if (!/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(pemContent)) {
        sendHtml(res, 400, renderError('That file does not look like a PEM private key.'));
        return;
      }

      let jwt;
      try {
        jwt = signAppJwt(appId, pemContent);
      } catch (err) {
        sendHtml(res, 400, renderError(`Could not sign with that key: ${err.message}`));
        return;
      }

      let meta;
      try {
        meta = await fetchAppMeta(jwt);
      } catch (err) {
        sendHtml(res, 400, renderError(err.message));
        return;
      }

      const summary = saveResult(meta, pemContent);
      verifiedApp = { meta, pemContent, jwt, summary };
      sendHtml(res, 200, renderSuccess(summary));
      console.error(`[register-server] App ${summary.name} (id=${summary.id}) verified; key written to ${OUTPUT_DIR}/app-key.pem`);
      if (!TARGET_REPO) {
        // Let the browser finish receiving the response before we exit.
        setTimeout(() => server.close(() => process.exit(0)), 1500);
      }
      return;
    }

    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
  } catch (err) {
    res.writeHead(500, { 'Content-Type': 'text/plain' });
    res.end(`Internal error: ${err.message}`);
    console.error(`[register-server] unhandled: ${err.stack || err.message}`);
  }
});

server.listen(PORT, () => {
  console.error(`[register-server] Listening on port ${PORT}.`);
});
