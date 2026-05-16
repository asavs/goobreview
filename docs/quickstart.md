# Quickstart

This path assumes one target repository and one reviewer identity.

## 1. Pick The Review Identity

Use a GitHub account that is not the PR author. GitHub does not allow users to approve or request changes on their own PRs.

The reviewer account needs:

- Read access to repository contents.
- Write access to pull requests.
- Issue write access if you want checklist updates and labels.

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

```bash
cp config/reviewer.env.example config/reviewer.env
cp config/project-docs.example.txt config/project-docs.txt
cp config/head-context-paths.example.txt config/head-context-paths.txt
cp config/required-checks.example.json config/required-checks.json
$EDITOR config/reviewer.env
$EDITOR config/project-docs.txt
$EDITOR config/head-context-paths.txt
$EDITOR config/required-checks.json
```

At minimum, set:

```bash
REVIEWER_REPO=owner/repo
REVIEWER_RUNNER_NAME=reviewer-vm
REVIEWER_STATE=/var/lib/goobreview/example
REVIEWER_SYNC_REPO_DIR=/opt/goobreview/example
REVIEWER_SYNC_BRANCH=main
```

The local config files are ignored by Git so `sync-worktree.sh` can keep the template checkout clean. If you do not know the required check-run names yet, leave `config/required-checks.json` as `[]` for the first dry run, then fill it with exact GitHub check-run display names before normal operation.

## 5. Authenticate Tools

Install and authenticate `gh` and Gemini CLI as described in [vm-setup.md](vm-setup.md).

Verify:

```bash
gh auth status
gh repo view owner/repo
gemini
printf 'say hi in three words' | timeout 60s gemini -m auto -p ""
```

Run the interactive `gemini` command from `/opt/goobreview/example` and trust that folder when prompted.

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

Use systemd when you control the VM and want better logs/status:

- [systemd-timer.md](systemd-timer.md)

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
