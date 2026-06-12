# GoobReview

A free end-to-end pull request reviewer powered by seldom utilized Google & GitHub resources.

GoobReview provisions a small VM into a durable reviewer-identity daemon that waits for CI, reviews PRs and posts `APPROVE`, `REQUEST_CHANGES`, or `COMMENT` reviews.

## What It Does

- Polls open, non-draft pull requests.
- Skips PRs authored by the authenticated reviewer account.
- Gates reviews on configured GitHub check-run names.
- Sends configurable prompt segments to Gemini CLI: personality, compact PR metadata, CI status, previous bot review, changed paths, relevant guidance, diff, and output format by default.
- Runs Gemini from a daemon-owned runtime directory with the cached PR-head source snapshot attached as read-only context.
- Can render the exact Gemini prompt text for a PR without posting or calling Gemini.
- Posts one consolidated GitHub review.
- Records `PR_NUMBER HEAD_SHA` pairs only after successful review posting.


## Setup

Onboarding aims at zero user effort: `gcloud` commands, organized by scripts, executed by Gemini CLI in Cloud Shell. The only steps left to you are billing consent, the GitHub App form in your browser, and Gemini sign-in.

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/asavschaeffer/goobreview&cloudshell_tutorial=docs/cloud-shell-tutorial.md)

Click the button to open this repo in [Google Cloud Shell](https://cloud.google.com/shell). Cloud Shell is a browser terminal with `gcloud` already authenticated to your Google account - no local installs needed. The tutorial pane follows [docs/cloud-shell-tutorial.md](docs/cloud-shell-tutorial.md), which is the shortest path through provisioning, App registration, VM configuration, a dry run, and scheduler enablement.

### Manual Setup

If you can't or don't want to use the one-click path - say, you already have a VM, or you can't run a local helper server in your environment - follow the same high-level order with the manual references:

1. Provision a small Linux VM and install the required tools. See [docs/vm-setup.md](docs/vm-setup.md).
2. Register and install the GitHub App. See [docs/github-app-setup.md](docs/github-app-setup.md).
3. Finish the on-VM flow in [docs/quickstart.md](docs/quickstart.md#4-finish-setup-on-the-vm): authenticate Gemini, run `scripts/configure.sh`, dry-run, then enable cron or systemd.

The App identity means the daemon can submit `APPROVE`, `REQUEST_CHANGES`, or `COMMENT` reviews under a clearly-bot login (`<your-app>[bot]`) without burning a second GitHub user account or org seat. It can also apply helper labels and re-review every new PR head commit.

## Customizing

Three ways to shape what your reviewer does, in order of impact:

1. **`config/personalities/<name>.md`** - role, voice, focus areas. Pick one via `REVIEWER_PERSONALITY_FILE` in `reviewer.env`. Add new ones by dropping a `.md` file in this directory. `configure.sh` lists the available personalities and writes your pick into `reviewer.env`.
2. **`config/prompt-payload.json`** - which prompt input streams Gemini receives: compact PR metadata, CI one-liner, previous bot review, changed paths, relevant guidance, full file tree, selected file contents, diff, and response format.
3. **`config/required-checks.json`** - exact GitHub check-run names that must pass before Gemini is called.

`scripts/configure.sh` walks you through copying the `.example` files and editing them. See [docs/daemon-runbook.md](docs/daemon-runbook.md#configuration-reference) for the full reference.

> Want your own copy to customize? Click **Use this template** at the top of this repo on GitHub. A first-push workflow (`.github/workflows/template-cleanup.yml`) auto-personalizes the Cloud Shell button, bootstrap script, and clone URL to point at your new repo. The one-click Cloud Shell bootstrap requires that copy to be public while the VM installs; private copies should use the manual VM path in [docs/vm-setup.md](docs/vm-setup.md).

## Repository Layout

```text
config/                              Per-deployment files. *.example.* ships;
                                     the non-example copy is gitignored.
  app-manifest.json                  GitHub App template used by register-app.sh
                                     to pre-fill the App-creation form
                                     (permissions, name, url). Committed.
  personalities/                     Reviewer personalities (control.md,
                                     linus.md, etc.). Pick one via
                                     REVIEWER_PERSONALITY_FILE in reviewer.env.
                                     The main thing you customize.
  prompt-payload.example.json        Prompt input manifest. Each segment has
                                     an enabled flag, description, and example.
  required-checks.example.json       GitHub check-run names that gate review posting.
  reviewer.env.example               Runtime env: target repo, App credentials,
                                     state dir, Gemini model.

scripts/
  bootstrap-gcp.sh                   Cloud Shell provisioner: creates the VM,
                                     runs setup-vm.sh on it.
  setup-vm.sh                        Installs gh, Node, Gemini CLI, configures
                                     swap; clones the template. Runs on the VM.
  register-app.sh                    GitHub App registration: runs
                                     lib/register-server.mjs, scps the key to
                                     the VM, writes REVIEWER_APP_ID.
  configure.sh                       On-VM interactive setup for config/ and
                                     App credentials.
  lib/register-server.mjs            Tiny Node HTTP server: hands the user a
                                     pre-filled GitHub form, receives the
                                     .pem + App ID. Used only at setup.
  reviewer/
    reviewer.sh                      Poll, prompt Gemini, post reviews.
    review-prompt.md                 Minimal GitHub review output format.
    run-once.sh                      Load env, sync checkout, run one tick.
    sync-worktree.sh                 Keep the daemon checkout detached at
                                     the configured branch.
    check-ci.sh                      Required check-run gate.
    merge-gate.sh                    Mechanical pre-merge checks.
    ensure-labels.sh                 Optional helper-label setup.
    get-installation-token.sh        Discover installation IDs or mint/cache App tokens.
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

## Safety Model

The daemon trusts a GitHub App installation token (minted from a private key stored at `REVIEWER_APP_PRIVATE_KEY_PATH`) and local `gemini` authentication on the VM. Keep the private key file at mode `0600`, owned by the user that runs the cron. Do not run this from a developer's active working checkout. PR-head source snapshots under `REVIEWER_RUNTIME_STATE/worktrees/<repo>/current` are read-only review context; Gemini runs from `REVIEWER_RUNTIME_STATE/gemini-runtime` with PR-authored `GEMINI.md` / `.env` files excluded from automatic context, MCP servers disabled, and Gemini CLI's documented workspace-trust session override set for the isolated review invocation. The daemon does not execute project code from snapshots.

The daemon does not merge PRs and does not edit source code. It only posts reviews and applies optional labels.
