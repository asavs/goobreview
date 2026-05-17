# GoobReview

An end-to-end pull request reviewer template powered by Gemini CLI and GitHub.

GoobReview is designed for users who want to point a Google AI Pro-backed Gemini CLI setup at their repository and get real GitHub PR reviews from a reviewer identity. It turns a small VM into a durable review daemon that reads your project docs, waits for CI, reviews non-draft PRs, and posts `APPROVE`, `REQUEST_CHANGES`, or `COMMENT` reviews.

## One-Click Setup On Google Cloud

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/asavschaeffer/goobreview&cloudshell_tutorial=docs/cloud-shell-tutorial.md)

Click the button to open this repo in [Google Cloud Shell](https://cloud.google.com/shell). Cloud Shell is a browser terminal with `gcloud` already authenticated to your Google account — no local installs needed. The tutorial pane will walk you through running `scripts/bootstrap-gcp.sh`, which prompts for project / zone / VM name and then provisions everything else automatically.

Prefer to paste a command? In any Cloud Shell session:

```bash
git clone https://github.com/asavschaeffer/goobreview.git && bash goobreview/scripts/bootstrap-gcp.sh
```

Either path leaves you with a provisioned VM and dependencies installed. To finish, you'll [register a GitHub App](docs/github-app-setup.md) (5 minutes, free, no extra GitHub account needed), `scp` the App's private key to the VM, and run `scripts/configure.sh`.

> Want your own copy to customize? Click **Use this template** at the top of this repo on GitHub. A first-push workflow (`.github/workflows/template-cleanup.yml`) auto-personalizes the Cloud Shell button, bootstrap script, and clone URL to point at your new repo.

## Manual Setup

The intended setup is:

1. Clone this template onto a small Linux VM.
2. Configure the target GitHub repository and the project docs the reviewer should read.
3. Register a GitHub App and install it on the target repo. The App is the reviewer identity — see [docs/github-app-setup.md](docs/github-app-setup.md).
4. Authenticate Gemini CLI with the Google account you want to use, including Google AI Pro or Ultra accounts where available.
5. Run the reviewer from cron.

The App identity means the daemon can submit `APPROVE`, `REQUEST_CHANGES`, or `COMMENT` reviews under a clearly-bot login (`<your-app>[bot]`) without burning a second GitHub user account or org seat. It can also add inline comments, update a managed PR checklist, and re-review every new PR head commit.

## What It Does

- Polls open, non-draft pull requests.
- Skips PRs authored by the authenticated reviewer account.
- Gates reviews on configured GitHub check-run names.
- Fetches selected project documentation from the PR head.
- Sends PR metadata, CI status, file tree, selected file contents, and diff to Gemini CLI.
- Posts one consolidated GitHub review.
- Records `PR_NUMBER HEAD_SHA` pairs only after successful review posting.

## Fast Path For An Agent

Give your coding agent this repository and ask:

```text
Use this template to set up an automated peer-account PR reviewer for OWNER/REPO.
Walk me through creating or selecting a small Ubuntu VM, installing gh and Gemini CLI,
authenticating both tools, choosing project docs/checks, running a dry-run review,
and enabling cron only after the dry run is clean.
```

The agent should follow:

- [docs/quickstart.md](docs/quickstart.md)
- [docs/github-app-setup.md](docs/github-app-setup.md)
- [docs/vm-setup.md](docs/vm-setup.md)
- [docs/daemon-runbook.md](docs/daemon-runbook.md)

## Repository Layout

```text
config/
  reviewer.env.example      Example environment file for the target repo.
  required-checks.example.json      Example required GitHub check-run names.
  project-docs.example.txt          Example review docs fetched from the PR head.
  head-context-paths.example.txt    Example extra files fetched for validation.
scripts/
  bootstrap-gcp.sh          One-shot Cloud Shell provisioner: creates the VM and runs setup-vm.sh on it.
  setup-vm.sh               Installs gh, Node, Gemini CLI, and clones the template. Runs on the VM.
scripts/
  configure.sh              On-VM interactive setup for config/ and App credentials.
scripts/reviewer/
  reviewer.sh               Poll, prompt Gemini, and post reviews.
  get-installation-token.sh Mint/cache a GitHub App installation token (also prints App slug).
  lib/app-token.mjs         Node helper: signs JWT, fetches /app, mints token.
  run-once.sh               Load config, sync checkout, run one review tick.
  sync-worktree.sh          Keep this checkout detached at the configured branch.
  check-ci.sh               Required check-run gate.
  ensure-labels.sh          Optional label setup.
  merge-gate.sh             Mechanical pre-merge checks.
  review-prompt.md          Base reviewer prompt.
docs/
  quickstart.md             5-minute end-to-end path.
  github-app-setup.md       Register and install the GitHub App.
  vm-setup.md               VM provisioning + tool install.
  daemon-runbook.md         Operations reference: cron, systemd, config, prompt, limits.
  cloud-shell-tutorial.md   In-Cloud-Shell walkthrough pane.
deploy/systemd/
  goobreview.service.example
  goobreview.timer.example
```

## Safety Model

The daemon trusts a GitHub App installation token (minted from a private key stored at `REVIEWER_APP_PRIVATE_KEY_PATH`) and local `gemini` authentication on the VM. Keep the private key file at mode `0600`, owned by the user that runs the cron. Do not run this from a developer's active working checkout.

The daemon does not merge PRs and does not edit source code. It only posts reviews, updates a managed checklist block in PR bodies, and applies optional labels.
