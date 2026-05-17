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

1. Create an `e2-small` Ubuntu 24.04 VM with a 20 GB disk
2. Wait for SSH to become reachable
3. Run `setup-vm.sh` on the VM, which installs `git`, `jq`, Node 20, GitHub CLI, and Gemini CLI, then clones the template into `/opt/goobreview/example`

When it finishes, it will print an SSH command and the remaining manual steps.

## 3. Register a GitHub App and trust Gemini

GoobReview's reviewer identity is a GitHub App, not a user account. Follow [docs/github-app-setup.md](github-app-setup.md) to register the App (about 5 minutes, free, no extra GitHub account), download its private key, and install the App on your target repo.

Then on the VM:

```bash
gcloud compute scp ./your-app.private-key.pem \
  goobreview-1:/var/lib/goobreview/example/app-key.pem \
  --zone=us-central1-a
gcloud compute ssh goobreview-1 --zone=us-central1-a
cd /opt/goobreview/example
chmod 600 /var/lib/goobreview/example/app-key.pem
gemini              # Google OAuth — sign in, trust this folder, then /quit
```

Use the VM name and zone you chose in step 2.

## 4. Configure the reviewer

Still on the VM, run the interactive helper:

```bash
scripts/configure.sh
```

It copies each of the gitignored config files (`reviewer.env`, `personality.md`, `project-docs.txt`, `head-context-paths.txt`, `required-checks.json`) from their `.example` siblings, prompts for the target repo, and offers to open each file in `$EDITOR`.

`personality.md` is the most useful one to edit before your first dry run — it defines what kind of reviewer this is (general-purpose, security-focused, accessibility-focused, etc.). The example file ships with sensible defaults plus a "Fork Themes" section you can adapt.

## 5. Dry run, then enable the scheduler

Follow [docs/quickstart.md](quickstart.md) starting from step 6 (optional labels), step 7 (dry run), and step 8 (cron or systemd timer).
