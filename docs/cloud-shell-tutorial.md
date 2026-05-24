# GoobReview: Cloud Shell Setup

This walkthrough is the Cloud Shell version of [docs/quickstart.md](quickstart.md). It provisions a small Compute Engine VM, registers the GitHub App, and then sends you to the shared on-VM setup steps.

## 1. Run the bootstrap script

```bash
bash scripts/bootstrap-gcp.sh
```

This is the first command to run. It checks your Google Cloud project and billing state, then walks you through whatever is missing:

- If your active project is Cloud Shell's temporary `cloudshell-NNNN` project, it offers to create a normal project.
- If your selected project does not exist, it offers to create it.
- If your selected project has billing disabled, it offers to link billing.
- If it cannot find a usable Cloud Billing account, it sends you to https://console.cloud.google.com/billing and tells you to rerun the same command afterward.

The script looks for billing accounts directly, and can also infer one from an existing project that already has billing enabled. Cloud Shell has Gemini preinstalled, so if the billing page is confusing, type `gemini` and ask it to guide you through the Google Cloud console step.

You'll be asked for three things (defaults shown in brackets):

- **GCP project ID** - defaults to whatever `gcloud config get-value project` returns, or a new project ID if the script is creating one
- **Zone** - defaults to `us-central1-a`
- **VM name** - defaults to `goobreview-1`

A billing account is required to enable Compute Engine, but the default GoobReview VM is an `e2-micro` in `us-central1`, which runs within GCP's [always-free tier](https://cloud.google.com/free/docs/free-cloud-features#compute) (1 instance + 30 GB standard disk per month). You won't be charged unless you bump to a larger machine, run multiple VMs, or move to a non-free region. New Google Cloud accounts also get $300 in 90-day credits.

After you confirm, the script will:

1. Create an `e2-micro` Ubuntu 24.04 VM (1 shared vCPU, 1 GB RAM, 20 GB disk) in your chosen zone. See [docs/vm-setup.md](vm-setup.md) for the full spec and larger-machine alternatives.
2. Wait for SSH to become reachable.
3. Run `setup-vm.sh` on the VM, which installs the required tools, configures a 2 GB swap file, then clones the template into `/opt/goobreview/example`.

When it finishes, it will print an SSH command and the remaining manual steps.

## 2. Register the GitHub App

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

## 3. Configure the reviewer

SSH to the VM, trust Gemini, and run the configure helper:

```bash
gcloud compute ssh goobreview-1 --zone=us-central1-a
cd /opt/goobreview/example
gemini                # Google OAuth - sign in, trust this folder, then /quit
scripts/configure.sh
```

`configure.sh` copies each gitignored config file (`reviewer.env`, `required-checks.json`, `prompt-payload.json`) from its `.example` sibling, prompts for the target repo, auto-discovers the installation ID, lets you pick a personality and prompt payload profile, and offers to open each file in `$EDITOR`.

Personality choice is the most consequential decision before your first dry run: it defines what kind of reviewer this is. `configure.sh` writes your pick into `REVIEWER_PERSONALITY_FILE` in `reviewer.env`. See [docs/daemon-runbook.md#configuration-reference](daemon-runbook.md#configuration-reference) for the full config reference.

## 4. Dry run, then enable the scheduler

Follow [docs/quickstart.md](quickstart.md) starting from [Step 5: Dry Run](quickstart.md#5-dry-run), then [Step 6: Enable The Scheduler](quickstart.md#6-enable-the-scheduler).
