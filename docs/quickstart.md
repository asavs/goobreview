# Quickstart

End-to-end setup from a fresh fork to a posting reviewer in about 10 minutes. Assumes one target repository and one reviewer identity.

## 1. Open This Repo In Cloud Shell

Click the **Open in Cloud Shell** button on the [project README](../README.md) (or run `git clone https://github.com/asavschaeffer/goobreview.git` in any Cloud Shell session). Cloud Shell is a browser terminal with `gcloud` pre-authenticated to your Google account.

If you can't use Cloud Shell, see the [Manual VM Setup](#manual-vm-setup) appendix at the end of this document.

## 2. Provision The VM

You need a billing-enabled GCP project (Cloud Shell's session-default `cloudshell-NNNN` won't work for Compute Engine). The bootstrap script can create a project, link it to an existing billing account, or repair a selected project whose billing is disabled. If your Google account has no active Cloud Billing account yet, open https://console.cloud.google.com/billing first; Google requires that browser/payment step before the CLI can create the VM.

The default VM is an `e2-micro` in `us-central1`, which is on GCP's [always-free tier](https://cloud.google.com/free/docs/free-cloud-features#compute) when you keep the defaults. You won't be charged unless you bump to a larger machine, run multiple VMs, move to a non-free region, or otherwise exceed free-tier limits.

Cloud Shell has Gemini preinstalled. If the billing/project page is confusing, type `gemini` and ask it to walk you through that Google Cloud console step; then come back here and rerun the same bootstrap command.

From the Cloud Shell checkout:

```bash
bash scripts/bootstrap-gcp.sh
```

It checks project/billing state, prompts for GCP project, zone, and VM name, then:

- Creates an `e2-micro` Ubuntu 24.04 VM (1 shared vCPU, 1 GB RAM, 20 GB disk). See [docs/vm-setup.md](vm-setup.md) for the full spec and larger-machine alternatives.
- Installs the required packages, GitHub CLI, Gemini CLI, and a 2 GB swap file.
- Clones this template into `/opt/goobreview/example` on the VM.

Takes about 3 minutes. When it finishes, it prints the remaining commands.

## 3. Register The GitHub App

Still in Cloud Shell:

```bash
bash scripts/register-app.sh
```

The bootstrap step saved your selected VM name and zone in `.goobreview-cloud-shell.env`, so this command still works if you changed either default. From a fresh checkout, pass them explicitly:

```bash
bash scripts/register-app.sh YOUR_VM_NAME YOUR_ZONE
```

It starts a tiny local server. Click Cloud Shell's **Web Preview** button -> **Preview on port 8080**. The page walks you through two steps:

1. Click the link to GitHub's pre-filled App-creation form (name, homepage, webhook off, all five permissions already set). At the bottom of the GitHub form, click **Create GitHub App**. On the App's settings page that loads, click **Generate a private key** to download the `.pem` and note the **App ID** at the top.
2. Back on the helper page, upload the `.pem` and paste the App ID. The helper signs a JWT to verify them, ships the key to the VM, pre-populates `REVIEWER_APP_ID` in `reviewer.env`, and shows an **Install ... on a repo ->** link. Click it and pick your target repo.

When the script finishes, the App's private key is at `/var/lib/goobreview/example/app-key.pem` on the VM and `REVIEWER_APP_ID` is filled in. The `.pem` lives only in Cloud Shell and on the VM &mdash; never on your local machine. See [docs/github-app-setup.md](github-app-setup.md) for the App identity, permissions, and the by-hand path.

Registering under an organization instead of your personal account:

```bash
GOOBREVIEW_GH_ORG=my-org bash scripts/register-app.sh
```

## 4. Finish Setup On The VM

SSH to the VM, authenticate Gemini, and run the configure helper:

```bash
gcloud compute ssh goobreview-1 --zone=us-central1-a
cd /opt/goobreview/example
gemini                # Google OAuth - sign in, trust this folder, then /quit
scripts/configure.sh  # prompts for target repo; auto-discovers installation ID
```

`configure.sh`:

- Copies each gitignored config file (`reviewer.env`, `required-checks.json`) from its `.example` sibling.
- Prompts for `REVIEWER_REPO` (the App ID is already filled in after `scripts/register-app.sh`; the by-hand path prompts for it).
- Auto-discovers the installation ID by minting an App token and looking up the install on the target repo.
- Lists the personalities in `config/personalities/` and writes your pick to `REVIEWER_PERSONALITY_FILE` in `reviewer.env`.
- Offers to open each config file in `$EDITOR`.
- Offers to create the helper labels on the target repo.

The most consequential choice is **which personality**: it defines the reviewer's role, voice, and focus areas. Out of the box: `control.md` (general-purpose, no voice direction) or `linus.md` (opinionated, profane-when-warranted). To add a new one, drop a `.md` file in `config/personalities/` in your fork and select it.

## 5. Dry Run

Still on the VM:

```bash
scripts/dry-run.sh
```

This runs the reviewer once against your target repo with `REVIEWER_DRY_RUN=1` so nothing is posted, then tails the log. Use a target repo with at least one open non-draft PR for a meaningful test.

To dry-run a specific PR:

```bash
scripts/dry-run.sh 123
```

Remove `REVIEWER_DRY_RUN=1` (i.e., run `scripts/reviewer/reviewer.sh` directly with your env sourced) when you intentionally want to post a real review.

## 6. Enable The Scheduler

Once the dry run looks good:

```bash
scripts/enable-cron.sh
```

Installs a one-line crontab entry that runs `run-once.sh` every minute. The reviewer self-throttles to one PR review per tick by default (`REVIEWER_MAX_PRS=1`), so this isn't as aggressive as it sounds.

Prefer systemd? See [docs/daemon-runbook.md#systemd-timer](daemon-runbook.md#systemd-timer).

Watch logs:

```bash
tail -f /var/lib/goobreview/example/log.txt
tail -f /var/lib/goobreview/example/cron.log
```

To pause: edit the crontab (`crontab -e`) and comment out the line, or `sudo systemctl stop goobreview.timer` if you used systemd.

---

## Manual VM Setup

For non-Cloud-Shell paths (own hardware, AWS, manual GCP, corporate GitHub, etc.), keep the same order but use the canonical references for the pieces Cloud Shell normally automates:

1. Provision a small Ubuntu LTS VM, install the tools, and clone the template using [docs/vm-setup.md](vm-setup.md).
2. Register and install the App using [docs/github-app-setup.md](github-app-setup.md). If registering manually, place the `.pem` at `/var/lib/goobreview/example/app-key.pem` with mode `0600`.
3. Continue at [Step 4 above](#4-finish-setup-on-the-vm) for Gemini auth, `scripts/configure.sh`, dry run, and scheduler enablement.
