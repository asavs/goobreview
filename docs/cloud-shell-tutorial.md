# GoobReview: Cloud Shell Setup

This walkthrough is the Cloud Shell version of [docs/quickstart.md](quickstart.md). It provisions a small Compute Engine VM, registers the GitHub App, and then sends you to the shared on-VM setup steps.

## 1. Check your Google Cloud account

Cloud Shell is signed in to your Google account, but its session-default project (`cloudshell-NNNN`) can't run Compute Engine. You need a normal GCP project linked to an active Cloud Billing account.

The bootstrap script can create a project, link it to an existing billing account, or repair a selected project whose billing is disabled. If your Google account has no active Cloud Billing account yet, Google requires a browser/payment setup step before any CLI can create the VM.

**If you already have a billing-enabled project:**

```bash
gcloud config set project YOUR_PROJECT_ID
```

**If you have billing but no project:** continue to Step 2; `bootstrap-gcp.sh` can create and link one.

**If you have no Cloud Billing account yet:** open https://console.cloud.google.com/billing and create one, then come back and run Step 2.

A billing account is required to enable Compute Engine, but the default GoobReview VM is an `e2-micro` in `us-central1`, which runs within GCP's [always-free tier](https://cloud.google.com/free/docs/free-cloud-features#compute) (1 instance + 30 GB standard disk per month). You won't be charged unless you bump to a larger machine, run multiple VMs, or move to a non-free region. New Google Cloud accounts also get $300 in 90-day credits.

> **Stuck on billing or project setup?** Type `gemini` at the Cloud Shell prompt and ask it to walk you through the console step. Gemini is preinstalled in Cloud Shell and can guide you while this repo's Bash scripts handle the deterministic setup commands.

## 2. Run the bootstrap script

```bash
bash scripts/bootstrap-gcp.sh
```

The script checks your active project and billing state first. You'll be asked for three things (defaults shown in brackets):

- **GCP project ID** - defaults to whatever `gcloud config get-value project` returns, or a new project ID if the script is creating one
- **Zone** - defaults to `us-central1-a`
- **VM name** - defaults to `goobreview-1`

After you confirm, the script will:

1. Create an `e2-micro` Ubuntu 24.04 VM (1 shared vCPU, 1 GB RAM, 20 GB disk) in your chosen zone. See [docs/vm-setup.md](vm-setup.md) for the full spec and larger-machine alternatives.
2. Wait for SSH to become reachable.
3. Run `setup-vm.sh` on the VM, which installs the required tools, configures a 2 GB swap file, then clones the template into `/opt/goobreview/example`.

When it finishes, it will print an SSH command and the remaining manual steps.

## 3. Register the GitHub App

GoobReview's reviewer identity is a GitHub App, not a user account, so its reviews come from a bot (`<app-name>[bot]`) that can `APPROVE` and `REQUEST_CHANGES` on PRs from any author.

From Cloud Shell (still in the goobreview checkout):

```bash
bash scripts/register-app.sh
```

If you accepted a custom VM name or zone during bootstrap, keep using the no-argument command above from the same Cloud Shell checkout. `bootstrap-gcp.sh` saved the handoff details locally. If you start from a fresh checkout instead, pass them explicitly:

```bash
bash scripts/register-app.sh YOUR_VM_NAME YOUR_ZONE
```

This starts a tiny local server. The walkthrough is:

1. Click the **Web Preview** button (top right of Cloud Shell) -> **Preview on port 8080**.
2. In the new browser tab, click through to the **pre-filled GitHub form** (it already has the name, homepage, webhook setting, and the five permissions set). At the bottom click **Create GitHub App**.
3. On the App's settings page that loads, click **Generate a private key** to download the `.pem`, and note the **App ID** at the top.
4. Back on the Web Preview page, upload the `.pem` and paste the App ID. After it verifies, click **Install ... on a repo ->** and pick your target repo.

When the script finishes, the private key is on the VM at `/var/lib/goobreview/example/app-key.pem` and the App ID is pre-filled in `reviewer.env`. The key only lives in Cloud Shell and on the VM &mdash; never on your local machine.

Registering the App under an organization instead of your personal account? Pass the org name:

```bash
GOOBREVIEW_GH_ORG=my-org bash scripts/register-app.sh
```

(For the by-hand path or troubleshooting, see [docs/github-app-setup.md](github-app-setup.md).)

## 4. Configure the reviewer

SSH to the VM, trust Gemini, and run the configure helper:

```bash
gcloud compute ssh goobreview-1 --zone=us-central1-a
cd /opt/goobreview/example
gemini                # Google OAuth - sign in, trust this folder, then /quit
scripts/configure.sh
```

`configure.sh` copies each gitignored config file (`reviewer.env`, `required-checks.json`) from its `.example` sibling, prompts for the target repo, auto-discovers the installation ID, lets you pick a personality from `config/personalities/`, and offers to open each file in `$EDITOR`.

Personality choice is the most consequential decision before your first dry run: it defines what kind of reviewer this is. `configure.sh` writes your pick into `REVIEWER_PERSONALITY_FILE` in `reviewer.env`. See [docs/daemon-runbook.md#configuration-reference](daemon-runbook.md#configuration-reference) for the full config reference.

## 5. Dry run, then enable the scheduler

Follow [docs/quickstart.md](quickstart.md) starting from [Step 5: Dry Run](quickstart.md#5-dry-run), then [Step 6: Enable The Scheduler](quickstart.md#6-enable-the-scheduler).
