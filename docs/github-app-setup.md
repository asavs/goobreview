# Register A GitHub App For GoobReview

GoobReview authenticates as a GitHub App so its reviews come from a bot identity (`<your-app-name>[bot]`). This page is the source of truth for App identity, permissions, key handling, and the registration walkthrough. The end-to-end setup flow lives in [quickstart.md](quickstart.md).

The App identity is distinct from any human account, so it can submit `APPROVE`, `REQUEST_CHANGES`, and `COMMENT` reviews on PRs by any author. Apps don't consume paid-org seats, get scoped per-repo permissions, and are the same idiom Dependabot, Renovate, and CodeRabbit use.

## What `register-app.sh` does

If you provisioned the VM with `scripts/bootstrap-gcp.sh`, run:

```bash
bash scripts/register-app.sh                       # personal account
GOOBREVIEW_GH_ORG=my-org bash scripts/register-app.sh  # organization
```

Pass the target repo when you know it:

```bash
bash scripts/register-app.sh --repo OWNER/REPO
```

The bootstrap step saves the selected VM name and zone in `.goobreview-cloud-shell.env`, so the no-argument command works even when you did not accept the default VM details. If you are using a different checkout or bypassed bootstrap, pass them explicitly:

```bash
bash scripts/register-app.sh --repo OWNER/REPO YOUR_VM_NAME YOUR_ZONE
```

The script spins up a tiny local web server on port 8080. You open Cloud Shell's **Web Preview** at that port and the page walks you through two steps:

1. **Create the App on GitHub.** A button links you to GitHub's App-creation form with name, homepage, description, webhook setting, and all five permissions pre-filled from `config/app-manifest.json`. You click **Create GitHub App** at the bottom of the form, then on the resulting settings page click **Generate a private key** (the `.pem` downloads) and note the **App ID** at the top.
2. **Upload the key back to the helper.** The same Web Preview page has a file picker for the `.pem` and a field for the App ID. The helper signs a JWT to verify the key, looks up the App's slug via the GitHub API, writes `app-key.pem` to the VM at `/var/lib/goobreview/example/app-key.pem`, and pre-populates `REVIEWER_APP_ID` in `config/reviewer.env`. The success page then links you to **Install on a repo**, where you pick the target repository. If you passed `--repo`, keep the helper page open after installing; it polls the App installation endpoint and writes `REVIEWER_REPO` plus `REVIEWER_APP_INSTALLATION_ID` when GitHub reports the install.

The `.pem` lives in the Cloud Shell session and the VM only &mdash; it never lands on your local machine.

After installation, ssh to the VM and run `scripts/configure.sh`. The App ID prompt will default to the right value; when `--repo` was used, the repo and installation ID are filled too. Without `--repo`, installation-ID auto-discovery will pick up the install during configure.

## Permissions and webhook configuration

These are filled in automatically; this section is the reference if you ever need to verify or recreate them by hand. The values come from `config/app-manifest.json`.

| Permission | Setting | Why |
|---|---|---|
| Checks | Read-only | CI gate — reads check-runs before calling Gemini |
| Contents | Read-only | Downloads the PR-head source snapshot for read-only review context |
| Issues | Read & Write | Posts labels (`agent-reviewed`, etc.) via the Issues API |
| Metadata | Read-only | Auto-selected; required for any repo API access |
| Pull requests | Read & Write | Lists PRs and submits reviews |

Everything else (Actions, Administration, Attestations, Code scanning, Commit statuses, Dependabot, Deployments, Discussions, Environments, Packages, Pages, Projects, Secrets, Webhooks, Workflows, etc.) &mdash; **No access**. Same for Account permissions and Organization permissions: leave everything at **No access**. The daemon only talks to repository-level APIs.

**Webhook → Active** is unchecked. GoobReview polls; it doesn't receive webhooks.

## Doing it by hand (no Cloud Shell)

If you can't run the helper server (no Cloud Shell, restrictive corporate GitHub, etc.):

1. Navigate to **Settings → Developer settings → GitHub Apps → New GitHub App** under your account or org.
2. Fill in **GitHub App name** (something descriptive like `goob-reviewer-<yourname>` &mdash; globally unique), **Homepage URL** (your repo URL is fine), leave **Callback URL** and **Setup URL** blank, **uncheck Webhook → Active**, and set the five permissions in the table above. Click **Create GitHub App**.
3. On the App's settings page, scroll to **Private keys** → **Generate a private key**. A `.pem` downloads.
4. Left sidebar → **Install App** → **Install** next to your account/org → **Only select repositories** → pick the target repo.
5. Note the **App ID** at the top of the App settings page. Copy the `.pem` to the VM:

   ```bash
   gcloud compute scp ./your-app-name.YYYY-MM-DD.private-key.pem \
     goobreview-1:/var/lib/goobreview/example/app-key.pem \
     --zone=us-central1-a
   gcloud compute ssh goobreview-1 --zone=us-central1-a \
     --command='chmod 600 /var/lib/goobreview/example/app-key.pem'
   ```

6. SSH to the VM and run `scripts/configure.sh`. Enter the App ID when prompted.

## Troubleshooting

- **"Auto-discover failed: GET /repos/... failed (404)"** — the App isn't installed on `REVIEWER_REPO`. Re-open the install link the helper showed you (or `https://github.com/apps/<slug>/installations/new`).
- **"Auto-discover failed: ... (401)"** — the App ID and private key don't match. Re-check the App ID at the top of the settings page, or regenerate the private key.
- **"GitHub rejected the App ID + key combination"** (from the helper) — same root cause as the 401 above: the ID you pasted and the `.pem` you uploaded belong to different Apps.
- **Reviews are posted as `COMMENT` instead of `APPROVE` / `REQUEST_CHANGES`** — the PR is authored by the App itself (GitHub forbids self-review). Apps rarely author normal PRs; this only happens if the App is also used by other automation to open PRs.
- **`"resource not accessible by integration"` on a specific call** — the App is missing a permission. Edit the App's permissions on its settings page, then re-accept the permission change on the installation page.
