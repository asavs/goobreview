# GoobReview: Cloud Shell Setup

This walkthrough is the Cloud Shell version of [docs/quickstart.md](quickstart.md). It provisions a small Compute Engine VM, registers the GitHub App, and then sends you through one dry-run review before anything is posted.

You will need:

- A Google account that can use Cloud Shell.
- A GCP project with billing, or permission to create/link one. The default VM is intended to stay inside GCP's always-free Compute Engine tier, but Google still requires billing to enable Compute Engine.
- Access to the GitHub account or organization where you want the reviewer App to live.
- A target GitHub repository where you can install that App.

The setup intentionally pauses for browser-only steps. When it does, finish the browser action, return to Cloud Shell, and keep going.

At any point, run:

```bash
bash scripts/status.sh
```

It prints the current GCloud, VM, GitHub App, config, and runtime state with a recommended next action.

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

If you are using Gemini to drive the setup, it should use the flag-driven form
after confirming the values with you:

```bash
bash scripts/bootstrap-gcp.sh \
  --project YOUR_PROJECT_ID \
  --zone us-central1-a \
  --vm-name goobreview-1 \
  --yes
```

A billing account is required to enable Compute Engine, but the default GoobReview VM is an `e2-micro` in `us-central1`, which runs within GCP's [always-free tier](https://cloud.google.com/free/docs/free-cloud-features#compute) (1 instance + 30 GB standard disk per month). You won't be charged unless you bump to a larger machine, run multiple VMs, or move to a non-free region. New Google Cloud accounts also get $300 in 90-day credits.

After you confirm, the script will:

1. Create an `e2-micro` Ubuntu 24.04 VM (1 shared vCPU, 1 GB RAM, 20 GB disk) in your chosen zone. See [docs/vm-setup.md](vm-setup.md) for the full spec and larger-machine alternatives.
2. Wait for SSH to become reachable.
3. Run `setup-vm.sh` on the VM, which installs the required tools, configures a 2 GB swap file, then clones the template into `/opt/goobreview/example`.

When it finishes, you should have:

- A running VM.
- The GoobReview checkout at `/opt/goobreview/example` on that VM.
- A Cloud Shell handoff file named `.goobreview-cloud-shell.env`, so the next command knows which VM to use.

Quick check:

```bash
bash scripts/status.sh
```

The VM preflight should now say the VM exists. If SSH is still warming up, wait a minute and run the status command again.

## 2. Register the GitHub App

GoobReview's reviewer identity is a GitHub App, not a user account, so its reviews come from a bot (`<app-name>[bot]`) that can `APPROVE` and `REQUEST_CHANGES` on PRs from any author.

From Cloud Shell (still in the goobreview checkout):

```bash
bash scripts/register-app.sh
```

If you know the target repository, pass it now so the helper can save the
installation ID after you install the App:

```bash
bash scripts/register-app.sh --repo OWNER/REPO
```

If you accepted a custom VM name or zone during bootstrap, keep using the no-argument command above from the same Cloud Shell checkout. `bootstrap-gcp.sh` saved the handoff details locally. If you start from a fresh checkout instead, pass them explicitly:

```bash
bash scripts/register-app.sh --repo OWNER/REPO YOUR_VM_NAME YOUR_ZONE
```

This starts a tiny local server. Keep the terminal open while you use the browser page. The walkthrough is:

1. Click the **Web Preview** button (top right of Cloud Shell) -> **Preview on port PORT_FROM_THE_TERMINAL**.
2. In the new browser tab, click through to the **pre-filled GitHub form** (it already has the name, homepage, webhook setting, and the five permissions set). At the bottom click **Create GitHub App**.
3. On the App's settings page that loads, click **Generate a private key** to download the `.pem`, and note the **App ID** at the top.
4. Back on the Web Preview page, upload the `.pem` and paste the App ID. After it verifies, click **Install ... on a repo ->** and pick your target repo. If you passed `--repo`, keep the helper page open until it reports the installation ID.

When the script finishes, the private key is on the VM at `/var/lib/goobreview/example/app-key.pem` and the App ID is pre-filled in `reviewer.env`. The key only lives in Cloud Shell and on the VM &mdash; never on your local machine.

Quick check:

```bash
bash scripts/status.sh
```

The GitHub App preflight should now show an App ID and VM key. If you used `--repo`, it should also show an installation ID; otherwise that is filled during the next configure step after you install the App on the target repo.

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

`configure.sh` prompts for the target repo, auto-discovers the App installation ID, lets you pick a personality and prompt payload profile, and offers to open the generated config files in `$EDITOR`.

Personality choice is the most consequential decision before your first dry run: it defines what kind of reviewer this is. `control` is neutral and general-purpose. `linus` is intentionally blunt. You can change this later with `scripts/tune.sh`.

Quick check on the VM:

```bash
scripts/status.sh
```

The config preflight should point you toward a dry run rather than more setup.

## 4. Dry run, tune, then enable the scheduler

Still on the VM, run a dry review first:

```bash
scripts/dry-run.sh
```

Or target a specific PR:

```bash
scripts/dry-run.sh 123
```

Nothing is posted to GitHub. The script writes an artifact under `$REVIEWER_STATE` that contains the exact prompt and Gemini response. Read it before launching.

To iterate on the voice or prompt shape:

```bash
scripts/tune.sh 123
```

When the dry-run artifact looks good, enable the scheduler:

```bash
scripts/enable-cron.sh
```

`enable-cron.sh` refuses to launch until a dry-run artifact exists. After it succeeds, watch:

```bash
tail -f /var/lib/goobreview/example/log.txt
tail -f /var/lib/goobreview/example/cron.log
```
