# GoobReview

A free end-to-end pull request reviewer powered by seldom utilized Google & GitHub resources.

GoobReview provisions a small VM into a durable reviewer-identity daemon that waits for CI, reviews PRs and posts `APPROVE`, `REQUEST_CHANGES`, or `COMMENT` reviews.

## What It Does

- Polls open, non-draft pull requests.
- Skips PRs authored by the authenticated reviewer account.
- Gates reviews on configured GitHub check-run names.
- Sends a fixed, GitHub-native prompt to Antigravity CLI (`agy`): personality, compact PR metadata with the author's description as claims to verify, commit subjects, check-run results, previous bot review, per-file diff with a changed-file index, and output format. The author username is blinded by default; blinding policy is set in `reviewer.env`.
- Runs `agy` from a daemon-owned runtime directory with the cached PR-head source snapshot attached as read-only context.
- Can render the exact `agy` prompt text for a PR without posting or calling `agy`.
- Posts one consolidated GitHub review.
- Records `PR_NUMBER HEAD_SHA` pairs only after successful review posting.


## Setup

Onboarding aims at zero diagnosis: `gcloud` commands, organized by scripts, executed by Antigravity CLI in Cloud Shell. The only steps left to you are account custody boundaries such as Google auth if Cloud Shell has no active `gcloud` account, billing consent, the GitHub App form in your browser, and Antigravity CLI sign-in.

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/asavschaeffer/goobreview&cloudshell_tutorial=docs/cloud-shell-tutorial.md)

Click the button to open this repo in [Google Cloud Shell](https://cloud.google.com/shell). Cloud Shell is a browser terminal with `gcloud` preinstalled and usually already authenticated to your Google account - no local installs needed. If the current shell has no active `gcloud` account, `scripts/status.sh` tells you the exact auth step before Gemini starts driving setup. The tutorial pane follows [docs/cloud-shell-tutorial.md](docs/cloud-shell-tutorial.md), which is the shortest path through provisioning, App registration, VM configuration, a dry run, and scheduler enablement.

### Manual Setup

If you can't or don't want to use the one-click path - say, you already have a VM, or you can't run a local helper server in your environment - follow the same high-level order with the manual references:

1. Provision a small Linux VM and install the required tools. See [docs/vm-setup.md](docs/vm-setup.md).
2. Register and install the GitHub App. See [docs/github-app-setup.md](docs/github-app-setup.md).
3. Finish the on-VM flow in [docs/quickstart.md](docs/quickstart.md#4-finish-setup-on-the-vm): authenticate Antigravity CLI, run `scripts/configure.sh`, dry-run, then enable cron or systemd.

The App identity means the daemon can submit `APPROVE`, `REQUEST_CHANGES`, or `COMMENT` reviews under a clearly-bot login (`<your-app>[bot]`) without burning a second GitHub user account or org seat, and re-review every new PR head commit.

## Customizing

Three ways to shape what your reviewer does, in order of impact:

1. **`REVIEWER_POSTED_PERSONALITY` in `config/reviewer.env`** - which style is posted to GitHub: `none` uses `config/personalities/control.md`, and `linus` uses `config/personalities/linus.md`.
2. **`REVIEWER_RESEARCH_CONSENT` in `config/reviewer.env`** - whether public live reviews may retain paired control/Linus prompt+response artifacts under `REVIEWER_STATE/research-runs/`. Consent never changes which style is posted.
3. **`REVIEWER_INCLUDE_*` flags in `config/reviewer.env`** - blinding policy: whether the reviewer sees the author username (off by default), the PR description, and the commit subjects. The prompt composition itself is fixed; if you want a different payload shape, fork and edit `scripts/reviewer/lib/prompt.sh` - the fork is the customization system, same as the personality gallery.
3. **`config/required-checks.json`** - exact GitHub check-run names that must pass before `agy` is called.

The target repo shapes its own review context with conventions it likely already uses: `AGENTS.md` / `CONTRIBUTING.md` / `GUIDELINES.md` files are pointed out to the reviewer, and diffs for files marked `linguist-generated` in `.gitattributes` are omitted the same way GitHub's own Files Changed tab collapses them.

`scripts/configure.sh` walks you through copying the `.example` files and editing them. See [docs/daemon-runbook.md](docs/daemon-runbook.md#configuration-reference) for the full reference.

> Want your own copy to customize? Click **Use this template** at the top of this repo on GitHub. A first-push workflow (`.github/workflows/template-cleanup.yml`) auto-personalizes the Cloud Shell button, bootstrap script, and clone URL to point at your new repo. The one-click Cloud Shell bootstrap requires that copy to be public while the VM installs; private copies should use the manual VM path in [docs/vm-setup.md](docs/vm-setup.md).

## Repository Layout

```text
config/                              Per-deployment files. *.example.* ships;
                                     the non-example copy is gitignored.
  app-manifest.json                  GitHub App template used by register-app.sh
                                     to pre-fill the App-creation form
                                     (permissions, name, url). Committed.
  personalities/                     Reviewer personalities. none maps to
                                     control.md; linus maps to linus.md.
                                     The main thing you customize.
  required-checks.example.json       GitHub check-run names that gate review posting.
  reviewer.env.example               Runtime env: target repo, App credentials,
                                     state dir, Gemini model.

scripts/
  bootstrap-gcp.sh                   Cloud Shell provisioner: creates the VM,
                                     runs setup-vm.sh on it.
  setup-vm.sh                        Installs base tools + Antigravity CLI,
                                     configures swap; clones the template.
                                     Runs on the VM (no Node runtime needed).
  register-app.sh                    GitHub App registration: runs
                                     lib/register-server.mjs, scps the key to
                                     the VM, writes REVIEWER_APP_ID.
  configure.sh                       On-VM interactive setup for config/ and
                                     App credentials.
  lib/register-server.mjs            Tiny Node HTTP server: hands the user a
                                     pre-filled GitHub form, receives the
                                     .pem + App ID. Used only at setup.
  reviewer/
    reviewer.sh                      Poll, prompt agy, post reviews.
    review-prompt.md                 Minimal GitHub review output format.
    run-once.sh                      Load env, sync checkout, run one tick.
    sync-worktree.sh                 Keep the daemon checkout detached at
                                     the configured branch.
    check-ci.sh                      Required check-run gate.
    merge-gate.sh                    Mechanical pre-merge checks.
    get-installation-token.sh        Pure-shell App auth: openssl signs the JWT,
                                     curl mints/caches tokens, discovers
                                     installation IDs. No Node on the VM.

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

The daemon does not merge PRs and does not edit source code. It only posts reviews.
