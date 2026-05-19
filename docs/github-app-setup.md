# Register A GitHub App For GoobReview

GoobReview authenticates as a GitHub App so its reviews come from a bot identity (`<your-app-name>[bot]`). That identity is distinct from any human account, so it can submit `APPROVE`, `REQUEST_CHANGES`, and `COMMENT` reviews on PRs by any author. Apps don't consume paid-org seats, get scoped per-repo permissions, and are the same idiom Dependabot, Renovate, and CodeRabbit use.

## 1. Create The App

Navigate to **Settings → Developer settings → GitHub Apps → New GitHub App** under your account, or the equivalent path under your organization's settings.

Fill in:

- **GitHub App name** — something descriptive like `goob-reviewer-<yourname>`. This becomes the bot's GitHub login (`<name>[bot]`) and shows on every review. Names are globally unique on GitHub, so add a personal suffix if your first choice is taken.
- **Homepage URL** — your repo URL (`https://github.com/<you>/goobreview`). GitHub requires a value; GoobReview never uses it.
- **Callback URL** — leave blank.
- **Expire user authorization tokens** — leave at default (doesn't matter; GoobReview never issues user OAuth tokens).
- **Request user authorization (OAuth) during installation** — leave unchecked.
- **Enable device flow** — leave unchecked.
- **Setup URL** — leave blank.
- **Webhook → Active** — *uncheck*. GoobReview polls; it doesn't receive webhooks.
- **Repository permissions** — GitHub shows a long list. Set only these five; leave everything else at **No access**:

  | Permission | Setting | Why |
  |---|---|---|
  | Checks | Read-only | CI gate — reads check-runs before calling Gemini |
  | Contents | Read-only | Reads file tree and project docs from the PR head SHA |
  | Issues | Read & Write | Posts labels (`agent-reviewed`, etc.) via the Issues API |
  | Metadata | Read-only | Auto-selected; required for any repo API access |
  | Pull requests | Read & Write | Lists PRs, submits reviews, edits PR body for the checklist block |

  Everything else on that list (Actions, Administration, Attestations, Code scanning, Commit statuses, Dependabot, Deployments, Discussions, Environments, Packages, Pages, Projects, Secrets, Webhooks, Workflows, etc.) — **No access**.

- **Account permissions** and **Organization permissions** — leave everything at **No access**. GoobReview only talks to repository-level APIs (PRs, checks, contents, issues). It never touches user accounts or org settings.
- **Where can this GitHub App be installed?** — "Any account" allows anyone to install the App on their own repos. "Only on this account" is fine if you're keeping this personal.

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
