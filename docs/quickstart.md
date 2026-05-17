# Quickstart

This path assumes one target repository and one reviewer identity.

## 1. Register A GitHub App

GoobReview authenticates as a GitHub App, so its reviews come from a bot identity (`<your-app>[bot]`) distinct from any human account. Follow [docs/github-app-setup.md](github-app-setup.md): create the App, generate a private key, install it on the target repo.

Required App permissions: Contents read, Issues read/write, Pull requests read/write, Checks read, Metadata read.

## 2. Provision Or Select A VM

Use a small Ubuntu LTS VM. The daemon is mostly idle and calls Gemini only when a review is needed.

Minimum practical shape:

- 1 vCPU.
- 1-2 GB RAM.
- 20 GB disk.
- SSH access restricted to maintainers.

See [vm-setup.md](vm-setup.md) for Google Compute Engine and generic Ubuntu notes.

## 3. Clone The Template

On the VM:

```bash
sudo mkdir -p /opt/goobreview
sudo chown "$USER:$USER" /opt/goobreview
git clone https://github.com/YOUR_ACCOUNT/goobreview.git /opt/goobreview/example
cd /opt/goobreview/example
git checkout --detach origin/main
```

Use the actual public template repo URL after publishing.

## 4. Configure The Target Repo

`scp` the App's private key to the VM (see step 4 of [github-app-setup.md](github-app-setup.md)), then run:

```bash
scripts/configure.sh
```

It copies all four config files from their `.example` siblings, prompts you for `REVIEWER_REPO`, the App ID, and the private key path, then auto-discovers the installation ID and writes everything to `config/reviewer.env`.

If you prefer to do it by hand, copy each `config/*.example.*` to its non-example name, edit `config/reviewer.env` to set `REVIEWER_REPO`, `REVIEWER_APP_ID`, `REVIEWER_APP_INSTALLATION_ID`, and `REVIEWER_APP_PRIVATE_KEY_PATH`, and edit the three other files to taste. The local config files are gitignored so `sync-worktree.sh` can keep the template checkout clean.

If you do not know the required check-run names yet, leave `config/required-checks.json` as `[]` for the first dry run, then fill it with exact GitHub check-run display names before normal operation.

## 5. Authenticate Gemini

Install Gemini CLI as described in [vm-setup.md](vm-setup.md), then:

```bash
cd /opt/goobreview/example
gemini
printf 'say hi in three words' | timeout 60s gemini -m auto -p ""
```

Run `gemini` interactively from `/opt/goobreview/example` so it can trust that folder. The reviewer needs no `gh auth login` step — it gets a short-lived GitHub App installation token at runtime from the private key configured in step 4.

## 6. Create Optional Labels

```bash
set -a
. config/reviewer.env
set +a
scripts/reviewer/ensure-labels.sh
```

The daemon still works if label setup is skipped. Label failures are logged and non-fatal.

## 7. Dry Run

Use an open, non-draft PR authored by another account when possible.

```bash
set -a
. config/reviewer.env
set +a
REVIEWER_DRY_RUN=1 REVIEWER_MAX_PRS=1 scripts/reviewer/reviewer.sh
tail -n 80 "$REVIEWER_STATE/log.txt"
```

For a self-authored smoke test:

```bash
REVIEWER_DRY_RUN=1 REVIEWER_ONLY_PR=123 REVIEWER_USER=nobody REVIEWER_MAX_PRS=1 scripts/reviewer/reviewer.sh
```

Remove `REVIEWER_DRY_RUN=1` only when you intentionally want to post a real review.

## 8. Enable A Scheduler

Use systemd when you control the VM and want better logs/status — see the **Systemd Timer** section of [daemon-runbook.md](daemon-runbook.md#systemd-timer).

Use cron when you want the simplest possible scheduler.

### Cron

Edit the reviewer's crontab:

```bash
crontab -e
```

Add:

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * cd /opt/goobreview/example && REVIEWER_ENV_FILE=/opt/goobreview/example/config/reviewer.env /usr/bin/bash scripts/reviewer/run-once.sh >> /var/lib/goobreview/example/cron.log 2>&1
```

Watch logs:

```bash
tail -f /var/lib/goobreview/example/log.txt
tail -f /var/lib/goobreview/example/cron.log
```
