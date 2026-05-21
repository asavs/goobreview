# GoobReview

An end-to-end pull request reviewer template powered by Gemini CLI and GitHub.

GoobReview is designed for users who want to point a Google AI Pro-backed Gemini CLI setup at their repository and get real GitHub PR reviews from a reviewer identity. It turns a small VM into a durable review daemon that reads your project docs, waits for CI, reviews non-draft PRs, and posts `APPROVE`, `REQUEST_CHANGES`, or `COMMENT` reviews.

## One-Click Setup On Google Cloud

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/asavschaeffer/goobreview&cloudshell_tutorial=docs/cloud-shell-tutorial.md)

Click the button to open this repo in [Google Cloud Shell](https://cloud.google.com/shell). Cloud Shell is a browser terminal with `gcloud` already authenticated to your Google account — no local installs needed. The tutorial pane will walk you through three commands:

```bash
bash scripts/bootstrap-gcp.sh    # provisions an e2-micro VM (free tier) + installs deps
bash scripts/register-app.sh     # registers a GitHub App, ships the key to the VM
                                 # then ssh in and run scripts/configure.sh
```

`bootstrap-gcp.sh` prompts for project / zone / VM name. `register-app.sh` uses GitHub's [Manifest Flow](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest) — you click Cloud Shell's Web Preview, then two buttons (one to create the App, one to install it on your target repo). The App's private key arrives over the GitHub API and is uploaded to the VM automatically; it never touches your local machine.

> Want your own copy to customize? Click **Use this template** at the top of this repo on GitHub. A first-push workflow (`.github/workflows/template-cleanup.yml`) auto-personalizes the Cloud Shell button, bootstrap script, and clone URL to point at your new repo.

## Manual Setup

If you can't or don't want to use the one-click path — say, you already have a VM, or you're on a corporate GitHub that disallows manifest-flow App creation — the manual path is:

1. Provision a small Linux VM (1 vCPU, 1-2 GB RAM, 20 GB disk) and install `gh`, `jq`, Node 20, and Gemini CLI on it. See [docs/vm-setup.md](docs/vm-setup.md).
2. Clone this template into `/opt/goobreview/example`.
3. Register a GitHub App **manually** (clicking through the full permission list on GitHub) and install it on the target repo. See [docs/github-app-setup.md § Manual registration](docs/github-app-setup.md#manual-registration).
4. Copy the App's private key onto the VM at `/var/lib/goobreview/example/app-key.pem` (mode 0600).
5. Authenticate Gemini CLI with the Google account you want to use (Google AI Pro/Ultra accounts work).
6. Run `scripts/configure.sh`, then enable cron or the systemd timer.

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
Use this template to set up an automated PR reviewer for OWNER/REPO. Walk me
through bootstrap-gcp.sh (VM provisioning), register-app.sh (GitHub App via
manifest flow), configure.sh (target repo + auto-discover installation ID),
a dry-run review, and enabling the scheduler only after the dry run is clean.
```

The agent should follow:

- [docs/quickstart.md](docs/quickstart.md)
- [docs/cloud-shell-tutorial.md](docs/cloud-shell-tutorial.md)
- [docs/github-app-setup.md](docs/github-app-setup.md) (manual registration only)
- [docs/vm-setup.md](docs/vm-setup.md)
- [docs/daemon-runbook.md](docs/daemon-runbook.md)

## Repository Layout

```text
config/                              Per-deployment files. *.example.* ships;
                                     the non-example copy is gitignored.
  app-manifest.json                  GitHub App template used by register-app.sh
                                     (permissions, name pattern). Committed.
  personality.example.md             Reviewer role, voice, focus areas.
                                     The main file you customize.
  personalities/                     Pre-built personalities (linus.md, etc.)
                                     selectable via configure.sh.
  project-docs.example.txt           Repo paths fetched from the PR head and
                                     pasted into every review prompt.
  head-context-paths.example.txt     Extra files fetched for reference validation
                                     (package.json, ci.yml, etc.).
  required-checks.example.json       GitHub check-run names that gate review posting.
  reviewer.env.example               Runtime env: target repo, App credentials,
                                     state dir, Gemini model.

scripts/
  bootstrap-gcp.sh                   Cloud Shell provisioner: creates the VM,
                                     runs setup-vm.sh on it.
  setup-vm.sh                        Installs gh, Node, Gemini CLI, configures
                                     swap; clones the template. Runs on the VM.
  register-app.sh                    Manifest-flow GitHub App registration:
                                     runs lib/manifest-server.mjs, scps the key
                                     to the VM, writes REVIEWER_APP_ID.
  configure.sh                       On-VM interactive setup for config/ and
                                     App credentials.
  lib/manifest-server.mjs            Tiny Node HTTP server that drives GitHub's
                                     App Manifest Flow. Used only at setup.
  reviewer/
    reviewer.sh                      Poll, prompt Gemini, post reviews.
    review-prompt.md                 Engine prompt (output contract, severity
                                     scale, validation rules). Edit
                                     personality.md instead.
    run-once.sh                      Load env, sync checkout, run one tick.
    sync-worktree.sh                 Keep the daemon checkout detached at
                                     the configured branch.
    check-ci.sh                      Required check-run gate.
    merge-gate.sh                    Mechanical pre-merge checks.
    ensure-labels.sh                 Optional helper-label setup.
    get-installation-token.sh        Mint/cache a GitHub App installation token.
    lib/app-token.mjs                Node helper: signs JWT, fetches /app, mints token.

docs/
  quickstart.md                      5-minute end-to-end path.
  github-app-setup.md                Register and install the GitHub App.
  vm-setup.md                        VM provisioning + tool install.
  daemon-runbook.md                  Operations reference: cron, systemd,
                                     config, prompt, limits.
  cloud-shell-tutorial.md            In-Cloud-Shell walkthrough pane.

deploy/systemd/
  goobreview.service.example
  goobreview.timer.example
```

## Customizing The Reviewer

Three ways to shape what your reviewer does, in order of impact:

1. **`config/personality.md`** — role, voice, focus areas. Forking for security, accessibility, language-specific reviews, etc. happens here. The file includes example "fork themes" you can adapt, and `config/personalities/` ships pre-built options you can pick during `configure.sh`. (The severity scale and verdict mapping live in the engine prompt, not here.)
2. **`config/project-docs.txt`** — repository paths to fetch from the PR head and inline into every review prompt. Put your house style, architecture notes, and review standards here.
3. **`config/head-context-paths.txt`** — extra files to fetch for reference validation (e.g. `package.json`, `.github/workflows/ci.yml`). The reviewer uses these to avoid hallucinating missing files or scripts.

`scripts/configure.sh` walks you through copying the `.example` files and editing them. See [docs/daemon-runbook.md](docs/daemon-runbook.md#configuration-reference) for the full reference.

## Safety Model

The daemon trusts a GitHub App installation token (minted from a private key stored at `REVIEWER_APP_PRIVATE_KEY_PATH`) and local `gemini` authentication on the VM. Keep the private key file at mode `0600`, owned by the user that runs the cron. Do not run this from a developer's active working checkout.

The daemon does not merge PRs and does not edit source code. It only posts reviews, updates a managed checklist block in PR bodies, and applies optional labels.
