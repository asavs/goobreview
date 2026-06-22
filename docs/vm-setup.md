# VM Setup

Use this page for any non-Cloud-Shell install, or when you need to understand what `scripts/bootstrap-gcp.sh` and `scripts/setup-vm.sh` create for you. The VM needs `git`, `jq`, `curl`, `wget`, `tar`, `flock`, `timeout`, Node/npm, and Antigravity CLI (`agy`). Ubuntu LTS is the easiest default.

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

`e2-micro` (2 vCPU, 1 GB RAM) in `us-central1`, `us-west1`, or `us-east1` (excluding northern Virginia) is covered by GCP's always-free tier - one instance and 30 GB standard disk per month. Antigravity CLI can spike past 1 GB during a review, so `scripts/setup-vm.sh` configures a 2 GB swap file by default; set `GOOBREVIEW_SWAP_SIZE=0` to skip if you're on a larger machine.

Keep firewall exposure minimal. The reviewer needs outbound HTTPS and inbound SSH only.

## Install GoobReview Runtime

After SSHing to the VM, the recommended manual path is to run the same installer
the Cloud Shell bootstrap uses. It installs base packages, Node 20,
Antigravity CLI, the checkout, the state directory, and optional swap:

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
default `/opt/goobreview/example` and `/var/lib/goobreview/example` layout. It
creates missing checkout/state directories, then changes ownership only for
those target directories. It does not recursively chown parent directories such
as `/opt/goobreview` or `/var/lib/goobreview`.

When overriding `GOOBREVIEW_CHECKOUT_DIR` or `GOOBREVIEW_STATE_DIR`, use a
reviewer-specific subdirectory. The installer rejects broad shared locations
such as `/`, `/opt`, `/var`, `/var/lib`, `/tmp`, `/etc`, and `/usr` because a
recursive ownership repair there would affect unrelated system files.

## Manual Package Reference

Use this only if you cannot run `scripts/setup-vm.sh`.

On Ubuntu, install the base packages first:

```bash
sudo apt-get update
sudo apt-get install -y git jq curl wget ca-certificates gnupg lsb-release util-linux coreutils tar
```

`flock` comes from `util-linux`; `timeout` comes from `coreutils`. Do not rely
on Ubuntu's `nodejs` package on older LTS images; install Node 20 or newer.

## Install Antigravity CLI

Use the official Antigravity CLI installer:

- https://antigravity.google/docs/cli-overview

Current documented install path:

```bash
curl -fsSL https://antigravity.google/cli/install.sh | bash
agy --version
```

Then authenticate and trust the daemon checkout:

```bash
cd /opt/goobreview/example
agy
```

Antigravity CLI authenticates with Google Sign-In, storing credentials in the system keyring or its file fallback.

- **Sign in with Google** for the Google account associated with your Antigravity access.
- **Vertex AI** through Application Default Credentials, a service account JSON key, or a Google Cloud API key, plus `GOOGLE_CLOUD_PROJECT` and `GOOGLE_CLOUD_LOCATION`. This is suitable for enterprise or production automation but uses Vertex AI quota and billing, not personal Google AI Pro/Ultra subscription quota.

GoobReview's default path intentionally uses Sign in with Google. Do not copy Google auth files, service account JSON, API keys, or other Antigravity credentials into the repo or checkout.

Exit Antigravity CLI when sign-in completes.

```text
/quit
```

Verify headless mode from the same checkout:

```bash
timeout 60s agy --sandbox --dangerously-skip-permissions --print "say hi in three words"
```

If this prompts for authorization or times out, run `agy` interactively again from the exact VM user account that cron will use. The reviewer later runs `agy` from `REVIEWER_RUNTIME_STATE/agy-runtime` with the PR-head source snapshot as its sole project context and the GitHub App credentials removed from its environment.

## Clone The Template

Use one stable checkout and state directory per reviewer identity:

```bash
sudo mkdir -p /opt/goobreview/example /var/lib/goobreview/example
sudo chown -R "$USER:$USER" /opt/goobreview/example /var/lib/goobreview/example
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

Then perform clone, GitHub App key install, and `agy` sign-in as that user.
