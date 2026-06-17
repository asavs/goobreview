# GoobReview: Cloud Shell Setup

This walkthrough is the canonical setup path. It provisions a small Compute Engine VM, registers the GitHub App, and then sends you through one dry-run review before anything is posted. For deeper detail on the on-VM steps (configure flags, dry-run options, scheduler), see [docs/quickstart.md](quickstart.md); for non-Cloud-Shell setups, see its Manual VM Setup appendix.

You will need:

- A Google account that can use Cloud Shell.
- A GCP project with billing, or permission to create/link one. The default VM is intended to stay inside GCP's always-free Compute Engine tier, but Google still requires billing to enable Compute Engine.
- Access to the GitHub account or organization where you want the reviewer App to live.
- A target GitHub repository where you can install that App.

The setup intentionally pauses for browser-only steps. When it does, finish the browser action, return to Cloud Shell, and keep going.

The Cloud Shell bootstrap path expects this template checkout to be readable without interactive credentials from the VM. If you made a private template copy, either keep it public during bootstrap or use the manual VM setup path.

At any point, Gemini can run:

```bash
bash scripts/status.sh
```

It prints the current GCloud, VM, GitHub App, config, and runtime state with a recommended next action.
Before opening Gemini, you can run the same command yourself. If Cloud Shell did
not carry an active `gcloud` account into this terminal, `status.sh` will stop
at that boundary and show the auth command to run first. That keeps Gemini from
starting setup in a shell that cannot inspect projects or billing.
It also runs a read-only VM discovery pass across accessible projects using
`gcloud compute instances list`, which can help you find an existing
GoobReview VM without creating anything. Run only that helper with:

```bash
bash scripts/discover-vms.sh
```

## 1. Let Gemini run the bootstrap script

First make sure `status.sh` can see an active Google account:

```bash
bash scripts/status.sh
```

If it reports `active account: none`, complete the printed `gcloud auth login`
step, then rerun `status.sh`. After that passes the auth boundary, open Gemini
in Cloud Shell:

```bash
gemini
```

Then ask it to set up GoobReview from this checkout. Gemini should run the
read-only sensors, choose the default VM shape, and execute the flag-driven
scripts for you. The shell commands below are shown so you can see what Gemini
is doing; use them yourself only if you are taking the manual path.

Gemini's first provisioning command is:

```bash
bash scripts/bootstrap-gcp.sh \
  --project YOUR_PROJECT_ID \
  --zone us-central1-a \
  --vm-name goobreview-1 \
  --yes
```

The bootstrap script checks your Google Cloud project and billing state, then handles whatever is missing:

- If your active project is Cloud Shell's temporary `cloudshell-NNNN` project, it offers to create a normal project.
- If your selected project does not exist, it offers to create it.
- If your selected project has billing disabled, it offers to link billing.
- If it cannot find a usable Cloud Billing account, it sends you to https://console.cloud.google.com/billing; after you finish the browser consent step, return to Gemini so it can continue.

The script looks for billing accounts directly, and can also infer one from an existing project that already has billing enabled. If the billing page is confusing, stay in Gemini and ask it to guide you through the Google Cloud console step.

Gemini should only ask you for choices that cannot be inferred. The default values are:

- **GCP project ID** - defaults to whatever `gcloud config get-value project` returns, or a new project ID if the script is creating one
- **Zone** - defaults to `us-central1-a`
- **VM name** - defaults to `goobreview-1`

Manual fallback:

```bash
bash scripts/bootstrap-gcp.sh
```

A billing account is required to enable Compute Engine, but the default GoobReview VM is an `e2-micro` in `us-central1`, which runs within GCP's [always-free tier](https://cloud.google.com/free/docs/free-cloud-features#compute) (1 instance + 30 GB standard disk per month). You won't be charged unless you bump to a larger machine, run multiple VMs, or move to a non-free region. New Google Cloud accounts also get $300 in 90-day credits.

After you confirm, the script will:

1. Create an `e2-micro` Ubuntu 24.04 VM (1 shared vCPU, 1 GB RAM, 20 GB disk) in your chosen zone. See [docs/vm-setup.md](vm-setup.md) for the full spec and larger-machine alternatives.
2. Wait for SSH to become reachable.
3. Run `setup-vm.sh` on the VM, which installs the required tools, configures a 2 GB swap file, then clones the template into `/opt/goobreview/example`.

`setup-vm.sh` repairs ownership only on the checkout and state directories it
creates. Custom checkout/state paths must be reviewer-specific subdirectories;
broad shared locations such as `/opt`, `/var`, `/tmp`, or `/etc` are rejected.

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

This starts a tiny local server on port 8080 unless that port is already occupied. Keep the terminal open while you use the browser page. The walkthrough is:

1. Click the **Web Preview** button (top right of Cloud Shell) -> **Preview on port 8080** (or the fallback port printed in the terminal).
2. In the new browser tab, click through to the **pre-filled GitHub form** (it already has the name, homepage, webhook setting, and the five permissions set). At the bottom click **Create GitHub App**.
3. On the App's settings page that loads, click **Generate a private key** to download the `.pem`, and note the **App ID** at the top.
4. Back on the Web Preview page, upload the `.pem` and paste the App ID. After it verifies, click **Install ... on a repo ->** and pick your target repo. If you passed `--repo`, keep the helper page open until it reports the installation ID.

When the script finishes, the private key is on the VM at `/var/lib/goobreview/example/app-key.pem` and the App ID is pre-filled in `reviewer.env`. GitHub may download the `.pem` to your browser's Downloads folder before you upload it to the helper; after the helper confirms the key is on the VM, delete the local download.

Quick check:

```bash
bash scripts/status.sh
```

The GitHub App preflight should now show an App ID and VM key. If you used `--repo`, it should also show an installation ID; otherwise configure can detect the target repo and installation ID when the App installation exposes exactly one repo.

Registering the App under an organization instead of your personal account? Pass the org name:

```bash
GOOBREVIEW_GH_ORG=my-org bash scripts/register-app.sh
```

(For the by-hand path or troubleshooting, see [docs/github-app-setup.md](github-app-setup.md).)

## 3. Configure the reviewer

Gemini should open the VM SSH session for you and land in the checkout:

```bash
gcloud compute ssh goobreview-1 --zone=us-central1-a
cd /opt/goobreview/example
```

When the VM shell is ready, your next true browser/auth boundary is Gemini CLI
sign-in and workspace trust:

```bash
gemini                # Google OAuth - sign in, trust this folder, then /quit
```

After you quit Gemini CLI, let the setup agent continue with:

```bash
scripts/configure.sh
```

`configure.sh` auto-detects the target repo plus App installation ID when the App installation exposes exactly one repo, then asks which style should be posted and whether public-repo research artifacts may be retained. It also offers to open the generated config files in `$EDITOR`. If the App can see multiple repos, it prompts for `owner/repo`.

Posted style is the most consequential decision before your first dry run: `none` is neutral and general-purpose, while `linus` is intentionally blunt. Research consent is separate; it controls artifact retention only, not which review posts. You can change both later with `scripts/tune.sh` or `config/reviewer.env`.

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
