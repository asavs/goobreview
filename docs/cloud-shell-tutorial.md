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

## 3. Finish the interactive auth on the VM

Two things have to be done by a human in a browser — they can't be scripted:

```bash
gcloud compute ssh goobreview-1 --zone=us-central1-a
cd /opt/goobreview/example
gh auth login       # OAuth — pick the GitHub account that will post reviews
gemini              # Google OAuth — sign in, trust this folder, then /quit
```

Use the VM name and zone you chose in step 2.

## 4. Configure the reviewer

Still on the VM:

```bash
cp config/reviewer.env.example config/reviewer.env
nano config/reviewer.env       # set REVIEWER_REPO=owner/repo
```

## 5. Dry run, then enable the scheduler

Follow [docs/quickstart.md](quickstart.md) starting from step 6 (optional labels), step 7 (dry run), and step 8 (cron or systemd timer).
