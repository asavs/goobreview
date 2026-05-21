# VM Setup

Use this page for any non-Cloud-Shell install, or when you need to understand what `scripts/bootstrap-gcp.sh` and `scripts/setup-vm.sh` create for you. The VM needs `git`, `gh`, `jq`, `flock`, `timeout`, Node/npm, and Gemini CLI. Ubuntu LTS is the easiest default.

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

`e2-micro` (2 vCPU, 1 GB RAM) in `us-central1`, `us-west1`, or `us-east1` (excluding northern Virginia) is covered by GCP's always-free tier - one instance and 30 GB standard disk per month. Gemini CLI can spike past 1 GB during a review, so `scripts/setup-vm.sh` configures a 2 GB swap file by default; set `GOOBREVIEW_SWAP_SIZE=0` to skip if you're on a larger machine.

Keep firewall exposure minimal. The reviewer needs outbound HTTPS and inbound SSH only.

## Base Packages

On Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y git jq curl wget ca-certificates gnupg lsb-release util-linux coreutils nodejs npm
```

`flock` comes from `util-linux`; `timeout` comes from `coreutils`.

## Install GitHub CLI

GitHub CLI's official install docs live in the `cli/cli` repository and GitHub Docs:

- https://github.com/cli/cli/blob/trunk/docs/install_linux.md
- https://docs.github.com/github-cli/github-cli/quickstart

For Ubuntu, follow the current official apt instructions from the GitHub CLI docs. After installing:

```bash
gh --version
```

GoobReview does not call `gh auth login`. The reviewer authenticates as a GitHub App using a short-lived installation token minted at runtime from a private key; `gh` picks up the token via `GH_TOKEN`. See [github-app-setup.md](github-app-setup.md) for App registration.

## Install Gemini CLI

The Gemini CLI project documents npm installation:

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

The Gemini CLI authentication docs describe individual Google account login and note that Google AI Pro or Google AI Ultra subscribers should use the Google account associated with that subscription.

Exit Gemini with:

```text
/quit
```

Verify headless mode from the same checkout:

```bash
printf 'say hi in three words' | timeout 60s gemini -m auto -p ""
```

If this prompts for authorization, reports an untrusted workspace, or times out, run `gemini` interactively again from the exact checkout path cron will use.

## Clone The Template

Use one stable checkout per reviewer identity:

```bash
sudo mkdir -p /opt/goobreview
sudo chown "$USER:$USER" /opt/goobreview
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
