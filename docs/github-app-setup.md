# Register A GitHub App For GoobReview

GoobReview authenticates as a GitHub App so its reviews come from a bot identity (`<your-app-name>[bot]`). That identity is distinct from any human account, so it can submit `APPROVE`, `REQUEST_CHANGES`, and `COMMENT` reviews on PRs by any author. Apps don't consume paid-org seats, get scoped per-repo permissions, and are the same idiom Dependabot, Renovate, and CodeRabbit use.

## 1. Create The App

Navigate to **Settings → Developer settings → GitHub Apps → New GitHub App** under your account, or the equivalent path under your organization's settings.

Fill in:

- **GitHub App name** — something descriptive like `goob-reviewer-<yourname>`. This becomes the bot's GitHub login (`<name>[bot]`) and shows on every review.
- **Homepage URL** — your repo URL is fine.
- **Webhook → Active** — *uncheck*. GoobReview polls; it doesn't receive webhooks.
- **Repository permissions:**
  - Contents: **Read-only** (read project docs from PR head)
  - Issues: **Read & Write** (PR labels and the managed checklist block)
  - Metadata: **Read-only** (auto-selected)
  - Pull requests: **Read & Write** (submit reviews, post inline comments)
  - Checks: **Read-only** (the CI gate before reviewing)
- **Where can this GitHub App be installed?** — "Only on this account" is the right default for personal use.

Click **Create GitHub App**. You'll be redirected to its settings page.

## 2. Generate A Private Key

On the App settings page, scroll to **Private keys** and click **Generate a private key**. A `.pem` file downloads. Keep it safe — anyone with this file can act as your bot.

## 3. Install The App On Your Target Repo

In the App's left sidebar, click **Install App**, then **Install** next to your account or org. Pick **Only select repositories** and choose the repo GoobReview will review.

You can verify the install at `https://github.com/settings/installations` (or your org's equivalent).

## 4. Note The App ID And Copy The Key To The VM

The App ID is at the top of the App's settings page — a numeric value like `1234567`. You'll be asked for it in the next step.

Copy the private key to the VM. From your local machine or Cloud Shell:

```bash
gcloud compute scp ./your-app-name.YYYY-MM-DD.private-key.pem \
  goobreview-1:/var/lib/goobreview/example/app-key.pem \
  --zone=us-central1-a
gcloud compute ssh goobreview-1 --zone=us-central1-a \
  --command='chmod 600 /var/lib/goobreview/example/app-key.pem'
```

Adjust paths/VM name/zone as needed. The default location GoobReview looks at is `$REVIEWER_STATE/app-key.pem`.

## 5. Run configure.sh

SSH to the VM and run:

```bash
cd /opt/goobreview/example
scripts/configure.sh
```

You'll be prompted for the App ID and the key path. The script then auto-discovers the installation ID for `REVIEWER_REPO` (the number GitHub uses to identify "App X installed on owner/repo Y") — you don't have to look it up by hand.

## Troubleshooting

- **"Auto-discover failed: GET /repos/... failed (404)"** — the App isn't installed on `REVIEWER_REPO`. Go back to step 3.
- **"Auto-discover failed: ... (401)"** — the App ID and private key don't match. Re-check the App ID at the top of the settings page, or regenerate the private key.
- **Reviews are posted as `COMMENT` instead of `APPROVE` / `REQUEST_CHANGES`** — the PR is authored by the App itself (which GitHub forbids from self-reviewing). Apps rarely author normal PRs; this only happens if the App is also being used by other automation to open PRs.
- **`"resource not accessible by integration"` on a specific call** — the App is missing a permission. Edit the App's permissions on its settings page, then re-accept the permission change on the installation page.
