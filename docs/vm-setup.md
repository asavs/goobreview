# VM Setup

Use this page for any non-Cloud-Shell install, or when you need to understand what `scripts/bootstrap-gcp.sh` and `scripts/setup-vm.sh` create for you. The VM needs `git`, `gh`, `jq`, `tar`, `flock`, `timeout`, Node/npm, and Gemini CLI. Ubuntu LTS is the easiest default.

Minimum practical shape:

- 1 vCPU.
- 1-2 GB RAM, with 2 GB swap at the low end.
- 20 GB disk.
- Outbound HTTPS and inbound SSH restricted to maintainers.

## Google Compute Engine Example

Google documents VM creation through the console and the `gcloud compute instances create` command:

- https://cloud.google.com/compute/docs/instances/create-start-instance
- https://cloud.google.com/sdk/gcloud/reference/compute/instances/create

Example:

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud compute instances create goobreview-1 \
  --zone=us-central1-a \
  --machine-type=e2-micro \
  --boot-disk-size=20GB \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --tags=ssh
gcloud compute ssh goobreview-1 --zone=us-central1-a
```

To look for an existing GoobReview VM before creating anything, run the
read-only discovery helper from the Cloud Shell checkout:

```bash
bash scripts/discover-vms.sh
```

It uses ordinary `gcloud compute instances list` calls across accessible
projects and zones, filtering for likely GoobReview instance names.

`e2-micro` (2 vCPU, 1 GB RAM) in `us-central1`, `us-west1`, or `us-east1` (excluding northern Virginia) is covered by GCP's always-free tier - one instance and 30 GB standard disk per month. Gemini CLI can spike past 1 GB during a review, so `scripts/setup-vm.sh` configures a 2 GB swap file by default; set `GOOBREVIEW_SWAP_SIZE=0` to skip if you're on a larger machine.

Keep firewall exposure minimal. The reviewer needs outbound HTTPS and inbound SSH only.

## Install GoobReview Runtime

After SSHing to the VM, the recommended manual path is to run the same installer
the Cloud Shell bootstrap uses. It installs base packages, GitHub CLI, Node 20,
Gemini CLI, the checkout, the state directory, and optional swap:

```bash
curl -fsSL https://raw.githubusercontent.com/asavschaeffer/goobreview/main/scripts/setup-vm.sh | bash
```

For your own public template copy, replace the URL and repo:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR/REPO/main/scripts/setup-vm.sh \
  | GOOBREVIEW_REPO_URL=https://github.com/YOUR/REPO.git bash
```

For a private repository, copy or clone it onto the VM using credentials you
control, then run the checked-out installer locally:

```bash
cd /path/to/private/goobreview
GOOBREVIEW_CHECKOUT_DIR="$PWD" bash scripts/setup-vm.sh
```

The script is idempotent; rerun it when you need to repair missing tools or the
default `/opt/goobreview/example` and `/var/lib/goobreview/example` layout.

## Manual Package Reference

Use this only if you cannot run `scripts/setup-vm.sh`.

On Ubuntu, install the base packages first:

```bash
sudo apt-get update
sudo apt-get install -y git jq curl wget ca-certificates gnupg lsb-release util-linux coreutils
```

`flock` comes from `util-linux`; `timeout` comes from `coreutils`. Do not rely
on Ubuntu's `nodejs` package on older LTS images; install Node 20 or newer.

## Install GitHub CLI

GitHub CLI's official install docs live in the `cli/cli` repository and GitHub Docs:

- https://github.com/cli/cli/blob/trunk/docs/install_linux.md
- https://docs.github.com/github-cli/github-cli/quickstart

For Ubuntu, follow the current official apt instructions from the GitHub CLI docs. After installing:

```bash
gh --version
```

GoobReview does not call `gh auth login`. Setup, tuning, prompt rendering, and basic PR metadata reads use GitHub App-token API calls directly. Posting the final PR review still uses `gh pr review`, with `gh` picking up the short-lived installation token via `GH_TOKEN`. See [github-app-setup.md](github-app-setup.md) for App registration.

## Install Gemini CLI

The Gemini CLI project documents npm installation. It requires Node 20 or newer:

- https://github.com/google-gemini/gemini-cli
- https://github.com/google-gemini/gemini-cli/blob/main/docs/get-started/index.md

Current documented install path:

```bash
sudo npm install -g @google/gemini-cli
gemini --version
```

Then authenticate and trust the daemon checkout:

```bash
cd /opt/goobreview/example
gemini
```

The Gemini CLI authentication docs describe three supported auth families:

- **Sign in with Google** for individual Google accounts and Gemini Code Assist licenses. This is the path that preserves Google AI Pro or Google AI Ultra subscription entitlement; use the Google account associated with that subscription.
- **Gemini API key** for headless setup through `GEMINI_API_KEY`. This is suitable for automation but uses API-key quota and billing, not personal Google AI Pro/Ultra subscription quota.
- **Vertex AI** through Application Default Credentials, a service account JSON key, or a Google Cloud API key, plus `GOOGLE_CLOUD_PROJECT` and `GOOGLE_CLOUD_LOCATION`. This is suitable for enterprise or production automation but uses Vertex AI quota and billing, not personal Google AI Pro/Ultra subscription quota.

GoobReview's default path intentionally uses Sign in with Google. Do not copy Google auth files, service account JSON, API keys, or other Gemini credentials into the repo or checkout. If you choose API key or Vertex AI mode instead, keep those credentials in the VM user's shell environment, systemd environment, or another VM-side secret store.

Exit Gemini with:

```text
/quit
```

Verify headless mode from the same checkout:

```bash
printf 'say hi in three words' | timeout 60s gemini -m auto -p ""
```

If this prompts for authorization or times out, run `gemini` interactively again from the exact checkout path cron will use. The reviewer later runs Gemini from `REVIEWER_STATE/gemini-runtime` with the PR-head source snapshot attached as read-only workspace context. For that isolated runtime call, GoobReview sets Gemini CLI's documented `GEMINI_CLI_TRUST_WORKSPACE=true` session override and writes system settings that disable project context filename loading, local `.env` loading, shell tools, and MCP servers.

## Clone The Template

Use one stable checkout and state directory per reviewer identity:

```bash
sudo mkdir -p /opt/goobreview/example /var/lib/goobreview/example
sudo chown -R "$USER:$USER" /opt/goobreview /var/lib/goobreview
git clone https://github.com/asavschaeffer/goobreview.git /opt/goobreview/example
cd /opt/goobreview/example
git checkout --detach origin/main
```

The detached checkout is intentional for a VM-side daemon. `scripts/reviewer/sync-worktree.sh` keeps this checkout on the configured branch before each reviewer tick and refuses to run if the checkout is dirty.

## Dedicated User Option

For a durable setup, create one Unix user per reviewer identity:

```bash
sudo useradd --system --create-home --shell /bin/bash goobreview
sudo mkdir -p /opt/goobreview/example /var/lib/goobreview/example
sudo chown -R goobreview:goobreview /opt/goobreview /var/lib/goobreview
```

Then perform clone, GitHub App key install, and `gemini` trust as that user.
