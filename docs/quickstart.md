# Quickstart

End-to-end setup from a fresh fork to a posting reviewer in about 10 minutes. Assumes one target repository and one reviewer identity.

## 1. Open This Repo In Cloud Shell

Click the **Open in Cloud Shell** button on the [project README](../README.md) (or run `git clone https://github.com/asavschaeffer/goobreview.git` in any Cloud Shell session). Cloud Shell is a free browser terminal with `gcloud` pre-authenticated to your Google account.

If you can't use Cloud Shell, see the [Manual VM Setup](#manual-vm-setup) appendix at the end of this document.

## 2. Provision The VM

From the Cloud Shell checkout:

```bash
bash scripts/bootstrap-gcp.sh
```

It prompts for GCP project, zone, and VM name (sensible defaults provided), then:

- Creates an `e2-micro` Ubuntu 24.04 VM with a 20 GB disk (free-tier eligible in `us-central1`, `us-west1`, `us-east1`).
- Installs `git`, `jq`, Node 20, GitHub CLI, Gemini CLI, and configures a 2 GB swap file (Gemini CLI can spike past `e2-micro`'s 1 GB of RAM).
- Clones this template into `/opt/goobreview/example` on the VM.

Takes about 3 minutes. When it finishes, it prints the remaining commands.

## 3. Register The GitHub App

Still in Cloud Shell:

```bash
bash scripts/register-app.sh
```

It starts a tiny local server, then prompts you to:

1. Click Cloud Shell's **Web Preview** button → **Preview on port 8080**.
2. In the browser tab that opens, click **Create GoobReview App on GitHub →**.
3. Confirm on GitHub (rename the App if you want — names are globally unique).
4. On the success page, click **Install ... on a repo →** and pick your target repo.

When the script finishes, the App's private key is at `/var/lib/goobreview/example/app-key.pem` on the VM and `REVIEWER_APP_ID` is pre-populated in `reviewer.env`. The private key never touches your local machine — it arrives over the GitHub API and goes straight to the VM.

Registering under an organization instead of your personal account:

```bash
GOOBREVIEW_GH_ORG=my-org bash scripts/register-app.sh
```

(If your GitHub setup blocks manifest-flow App creation — some corporate accounts do — see [docs/github-app-setup.md § Manual registration](github-app-setup.md#manual-registration).)

## 4. Finish Setup On The VM

SSH to the VM, authenticate Gemini, and run the configure helper:

```bash
gcloud compute ssh goobreview-1 --zone=us-central1-a
cd /opt/goobreview/example
gemini                # Google OAuth — sign in, trust this folder, then /quit
scripts/configure.sh  # prompts for target repo; auto-discovers installation ID
```

`configure.sh`:

- Copies each gitignored config file (`reviewer.env`, `personality.md`, `project-docs.txt`, `head-context-paths.txt`, `required-checks.json`) from its `.example` sibling.
- Prompts for `REVIEWER_REPO` (the App ID is already filled in from step 3).
- Auto-discovers the installation ID by minting an App token and looking up the install on the target repo.
- Offers to open each config file in `$EDITOR`.
- Offers to create the four helper labels on the target repo.

The most useful file to edit is **`personality.md`** — it defines the reviewer's role, voice, and focus areas. The example file includes a "Fork Themes" section with starting points for security, accessibility, language-specific reviewers, etc. `configure.sh` also offers pre-built personalities from `config/personalities/` (e.g. `linus.md`) you can seed it from.

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

Prefer systemd? See [docs/daemon-runbook.md § Systemd Timer](daemon-runbook.md#systemd-timer).

Watch logs:

```bash
tail -f /var/lib/goobreview/example/log.txt
tail -f /var/lib/goobreview/example/cron.log
```

To pause: edit the crontab (`crontab -e`) and comment out the line, or `sudo systemctl stop goobreview.timer` if you used systemd.

---

## Manual VM Setup

For non-Cloud-Shell paths (own hardware, AWS, manual GCP, etc.).

### 1. Provision The VM

Use a small Ubuntu LTS VM. Minimum practical shape:

- 1 vCPU.
- 1-2 GB RAM (add 2 GB swap if you're at the low end).
- 20 GB disk.
- SSH access restricted to maintainers.

See [docs/vm-setup.md](vm-setup.md) for install commands.

### 2. Clone The Template

```bash
sudo mkdir -p /opt/goobreview
sudo chown "$USER:$USER" /opt/goobreview
git clone https://github.com/asavschaeffer/goobreview.git /opt/goobreview/example
cd /opt/goobreview/example
git checkout --detach origin/main
```

### 3. Register A GitHub App

Follow [docs/github-app-setup.md § Manual registration](github-app-setup.md#manual-registration). Manually downloading the `.pem` and placing it at `/var/lib/goobreview/example/app-key.pem` (mode 0600) is the path. (If your environment allows it, `scripts/register-app.sh` still works from any machine that has `gcloud` configured to reach the VM, but the manifest flow assumes a publicly-reachable redirect URL.)

### 4. Configure And Continue

The on-VM portion of the flow (`gemini`, `scripts/configure.sh`, `scripts/dry-run.sh`, `scripts/enable-cron.sh`) is identical to the Cloud Shell path — pick it up at [Step 4 above](#4-finish-setup-on-the-vm).
