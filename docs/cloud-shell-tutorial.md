# GoobReview: Cloud Shell Setup

This walkthrough provisions a small Compute Engine VM and installs the GoobReview reviewer daemon on it. Total time: about 5 minutes, plus two interactive OAuth steps at the end.

## 1. Confirm your project

Cloud Shell is already authenticated to your Google account. Check which GCP project is active:

```bash
gcloud config get-value project
```

If that's not the project you want to use, set it now:

```bash
gcloud config set project YOUR_PROJECT_ID
```

The VM will be billed to this project. The bootstrap script will also prompt you to confirm.

## 2. Run the bootstrap script

```bash
bash scripts/bootstrap-gcp.sh
```

You'll be asked for three things (defaults shown in brackets):

- **GCP project ID** — defaults to whatever `gcloud config get-value project` returns
- **Zone** — defaults to `us-central1-a`
- **VM name** — defaults to `goobreview-1`

After you confirm, the script will:

1. Create an `e2-micro` Ubuntu 24.04 VM with a 20 GB disk. `e2-micro` in `us-central1`, `us-west1`, or `us-east1` (excluding northern Virginia) is covered by GCP's always-free tier — one instance and 30 GB standard disk per month at no charge.
2. Wait for SSH to become reachable
3. Run `setup-vm.sh` on the VM, which installs `git`, `jq`, Node 20, GitHub CLI, and Gemini CLI, configures a 2 GB swap file (Gemini CLI can spike past `e2-micro`'s 1 GB of RAM), then clones the template into `/opt/goobreview/example`

When it finishes, it will print an SSH command and the remaining manual steps.

## 3. Register the GitHub App

GoobReview's reviewer identity is a GitHub App, not a user account, so its reviews come from a bot (`<app-name>[bot]`) that can `APPROVE` and `REQUEST_CHANGES` on PRs from any author.

From Cloud Shell (still in the goobreview checkout):

```bash
bash scripts/register-app.sh
```

This starts a tiny local server, then prompts you to:

1. Click the **Web Preview** button (top right of Cloud Shell) → **Preview on port 8080**.
2. In the new browser tab, click **Create GoobReview App on GitHub →**.
3. Confirm on GitHub (you can rename the App on that page if you want).
4. Click **Install ... on a repo →** on the success page and pick your target repo.

When the script finishes, the private key is already on the VM at `/var/lib/goobreview/example/app-key.pem` and the App ID is pre-filled in `reviewer.env`. The key never touches your local machine.

Registering the App under an organization instead of your personal account? Pass the org name:

```bash
GOOBREVIEW_GH_ORG=my-org bash scripts/register-app.sh
```

(If you'd rather register manually — clicking through the full permission list on GitHub — see [docs/github-app-setup.md](github-app-setup.md).)

## 4. Configure the reviewer

SSH to the VM, trust Gemini, and run the configure helper:

```bash
gcloud compute ssh goobreview-1 --zone=us-central1-a
cd /opt/goobreview/example
gemini                # Google OAuth — sign in, trust this folder, then /quit
scripts/configure.sh
```

`configure.sh` copies each gitignored config file (`reviewer.env`, `personality.md`, `project-docs.txt`, `head-context-paths.txt`, `required-checks.json`) from its `.example` sibling, prompts for the target repo, auto-discovers the installation ID, and offers to open each file in `$EDITOR`.

`personality.md` is the most useful one to edit before your first dry run — it defines what kind of reviewer this is (general-purpose, security-focused, accessibility-focused, etc.). The example file ships with sensible defaults plus a "Fork Themes" section you can adapt.

## 5. Dry run, then enable the scheduler

Follow [docs/quickstart.md](quickstart.md) starting from step 6 (optional labels), step 7 (dry run), and step 8 (cron or systemd timer).
