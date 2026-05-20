#!/usr/bin/env node
// GitHub App Manifest Flow server. Run from Cloud Shell; user clicks Web
// Preview on port 8080, then "Create App" — GitHub redirects back to /callback
// with a one-time code, we exchange it for the App's private key, and write
// app-key.pem + app.json to GOOBREVIEW_REGISTER_OUTPUT.
//
// https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest

import http from 'node:http';
import https from 'node:https';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const PORT = Number(process.env.GOOBREVIEW_REGISTER_PORT || 8080);
const OUTPUT_DIR = process.env.GOOBREVIEW_REGISTER_OUTPUT;
const MANIFEST_PATH = process.env.GOOBREVIEW_MANIFEST;
const GH_OWNER_ORG = process.env.GOOBREVIEW_GH_ORG || '';
const STATE_TOKEN = crypto.randomBytes(16).toString('hex');

if (!OUTPUT_DIR) die('GOOBREVIEW_REGISTER_OUTPUT not set');
if (!MANIFEST_PATH) die('GOOBREVIEW_MANIFEST not set');
if (!fs.existsSync(MANIFEST_PATH)) die(`manifest file not found: ${MANIFEST_PATH}`);

const manifestTemplate = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'));

function die(msg) {
  console.error(`[manifest-server] ${msg}`);
  process.exit(1);
}

function htmlEscape(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// Cloud Shell's Web Preview proxies the request to localhost:8080 with the
// real public hostname in x-forwarded-host. Compute the redirect URL from
// whatever the browser actually used to reach us.
function detectBaseUrl(req) {
  const host = req.headers['x-forwarded-host'] || req.headers.host;
  const proto = req.headers['x-forwarded-proto'] || 'http';
  return `${proto}://${host}`;
}

function renderForm(req) {
  const baseUrl = detectBaseUrl(req);
  const manifest = { ...manifestTemplate, redirect_url: `${baseUrl}/callback` };
  const manifestJson = JSON.stringify(manifest);
  const action = GH_OWNER_ORG
    ? `https://github.com/organizations/${encodeURIComponent(GH_OWNER_ORG)}/settings/apps/new?state=${STATE_TOKEN}`
    : `https://github.com/settings/apps/new?state=${STATE_TOKEN}`;

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Register GoobReview App</title>
  <style>
    body { font: 15px/1.5 system-ui, sans-serif; max-width: 640px; margin: 4rem auto; padding: 0 1rem; color: #222; }
    h1 { margin-top: 0; }
    button { font-size: 16px; padding: 0.75em 1.5em; background: #2da44e; color: white; border: 0; border-radius: 6px; cursor: pointer; }
    button:hover { background: #2c974b; }
    .perms { background: #f6f8fa; border-radius: 6px; padding: 1em 1.5em; margin: 1.5em 0; }
    .perms li { margin: 0.25em 0; }
    code { background: #f6f8fa; padding: 1px 5px; border-radius: 3px; font-size: 13px; }
    .muted { color: #57606a; font-size: 13px; }
  </style>
</head>
<body>
  <h1>Register your GoobReview App</h1>
  <p>Clicking the button below will send you to GitHub, where you can confirm and create a new GitHub App named <code>${htmlEscape(manifestTemplate.name)}</code> (rename it there if you want — names are globally unique on GitHub).</p>

  <div class="perms">
    <p><strong>The App will request:</strong></p>
    <ul>
      <li>Checks: <code>read</code> — to gate reviews on CI status</li>
      <li>Contents: <code>read</code> — to read changed files and project docs</li>
      <li>Issues: <code>write</code> — to post labels and a managed checklist</li>
      <li>Metadata: <code>read</code> — required for any repo API access</li>
      <li>Pull requests: <code>write</code> — to submit reviews and inline comments</li>
    </ul>
    <p class="muted">No webhooks. No user OAuth. No org-level permissions.</p>
  </div>

  <form method="POST" action="${htmlEscape(action)}">
    <input type="hidden" name="manifest" value='${htmlEscape(manifestJson)}'/>
    <button type="submit" autofocus>Create GoobReview App on GitHub →</button>
  </form>

  <p class="muted">After you confirm on GitHub, you'll be redirected back here automatically. The private key will be saved to the VM — it never touches your local machine.</p>
</body>
</html>`;
}

function renderSuccess(result) {
  const installUrl = `https://github.com/apps/${encodeURIComponent(result.slug)}/installations/new`;
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>GoobReview App created</title>
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
  <h1>App created: ${htmlEscape(result.name)}</h1>
  <p>App ID <code>${htmlEscape(result.id)}</code>. Private key has been saved and will be shipped to your VM.</p>

  <p><strong>One step left:</strong> install the App on your target repo.</p>
  <p><a class="btn" href="${htmlEscape(installUrl)}">Install ${htmlEscape(result.name)} on a repo →</a></p>

  <p class="muted">Pick "Only select repositories" and choose the repo GoobReview will review. After install, return to your terminal — the register script has already exited and printed the next command to run.</p>
</body>
</html>`;
}

function exchangeCode(code) {
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: 'api.github.com',
        path: `/app-manifests/${encodeURIComponent(code)}/conversions`,
        method: 'POST',
        headers: {
          Accept: 'application/vnd.github+json',
          'User-Agent': 'goobreview-register',
          'X-GitHub-Api-Version': '2022-11-28',
          'Content-Length': 0,
        },
      },
      (res) => {
        let body = '';
        res.on('data', (c) => (body += c));
        res.on('end', () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            try {
              resolve(JSON.parse(body));
            } catch (e) {
              reject(new Error(`malformed JSON from GitHub: ${e.message}`));
            }
          } else {
            reject(new Error(`GitHub returned ${res.statusCode}: ${body.slice(0, 500)}`));
          }
        });
      }
    );
    req.on('error', reject);
    req.end();
  });
}

function saveResult(result) {
  fs.mkdirSync(OUTPUT_DIR, { recursive: true, mode: 0o700 });
  fs.writeFileSync(path.join(OUTPUT_DIR, 'app-key.pem'), result.pem, { mode: 0o600 });
  const summary = {
    id: result.id,
    slug: result.slug,
    name: result.name,
    owner: result.owner?.login || result.owner?.slug || '',
    html_url: result.html_url,
    client_id: result.client_id,
    webhook_secret: result.webhook_secret,
  };
  fs.writeFileSync(path.join(OUTPUT_DIR, 'app.json'), JSON.stringify(summary, null, 2));
  return summary;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

  if (req.method === 'GET' && url.pathname === '/') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(renderForm(req));
    return;
  }

  if (req.method === 'GET' && url.pathname === '/callback') {
    const code = url.searchParams.get('code');
    const state = url.searchParams.get('state');
    if (!code) {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      res.end('Missing code parameter. Did you arrive here from GitHub?');
      return;
    }
    if (state !== STATE_TOKEN) {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      res.end('State token mismatch (possible CSRF). Restart the script and try again.');
      return;
    }
    try {
      const result = await exchangeCode(code);
      const summary = saveResult(result);
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(renderSuccess(summary));
      console.error(`[manifest-server] App ${summary.name} (id=${summary.id}) registered; key written to ${OUTPUT_DIR}/app-key.pem`);
      // Let the browser finish receiving the response before we exit.
      setTimeout(() => server.close(() => process.exit(0)), 1500);
    } catch (err) {
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end(`Manifest conversion failed: ${err.message}`);
      console.error(`[manifest-server] ${err.message}`);
    }
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not found');
});

server.listen(PORT, () => {
  console.error(`[manifest-server] Listening on port ${PORT}; state token ${STATE_TOKEN.slice(0, 8)}…`);
});
