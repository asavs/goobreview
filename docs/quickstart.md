# Quickstart

End-to-end setup from a fresh fork to a posting reviewer in about 10 minutes. Assumes one target repository and one reviewer identity.

The recommended path is Cloud Shell: click the **Open in Cloud Shell** button on the [project README](../README.md) and follow the tutorial pane ([docs/cloud-shell-tutorial.md](cloud-shell-tutorial.md)). It covers VM provisioning (`scripts/bootstrap-gcp.sh`) and GitHub App registration (`scripts/register-app.sh`). This document covers what comes after — finishing setup on the VM — plus the non-Cloud-Shell path.

At any point, run:

```bash
bash scripts/status.sh
```

It summarizes local config, dry-run/scheduler state, active GCloud account/project/billing readiness, and likely existing GoobReview VMs visible to your account, with a recommended next action.

## 4. Finish Setup On The VM

Antigravity CLI should SSH to the VM, enter the checkout, and leave you at the Antigravity CLI
CLI sign-in boundary:

```bash
gcloud compute ssh goobreview-1 --zone=us-central1-a
cd /opt/goobreview/example
agy                   # Google OAuth - sign in
```

After sign-in completes, let the setup agent continue with:

```bash
scripts/configure.sh  # auto-detects target repo + installation ID when possible
```

The `agy` step is intentionally interactive and uses Google Sign-In. Keep cached Google auth state out of this repo and checkout.

`configure.sh` is the interactive wrapper: it copies each gitignored config file from its `.example` sibling, auto-detects the target repo and installation ID when the App installation exposes exactly one repo, asks which review style should be posted, and asks whether public-repo research artifacts may be retained. It delegates deterministic writes and validation to `scripts/configure-inner.sh`, which agents and scripts can call directly:

```bash
scripts/configure-inner.sh \
  --app-id APP_ID \
  --key-path /var/lib/goobreview/example/app-key.pem \
  --posted-personality none \
  --research-consent 0
```

Add `--repo OWNER/REPO` if the App has access to multiple repos. Add
`--installation-id ID` if you already know it; otherwise the script discovers it.

The most consequential product choice is **which style gets posted**: `none` posts the neutral control reviewer, while `linus` posts the blunt Linus-style reviewer. Research consent is separate: on public repositories only, it lets live runs retain paired control/Linus prompt+response artifacts for later analysis. Consent never changes which review style is posted.

The second choice is the **blinding policy** in `config/reviewer.env`: `REVIEWER_INCLUDE_AUTHOR` (default `0` — the reviewer never learns the author's username), `REVIEWER_INCLUDE_DESCRIPTION`, and `REVIEWER_INCLUDE_COMMIT_SUBJECTS` (both default `1`, included as author claims to verify against the diff). The rest of the prompt — check-run rows, workflow/package-script context, the bot's previous review, the per-file diff, the snapshot pointer — is fixed; forks edit `scripts/reviewer/lib/prompt.sh` to change the shape.

Live posting will not fall back to example config. Before enabling the scheduler, make sure `config/required-checks.json` exists, or set `REVIEWER_REQUIRED_CHECKS_FILE` to a valid deployment-specific file.

## 5. Dry Run

Still on the VM:

```bash
scripts/dry-run.sh
```

This runs the reviewer once against your target repo with `REVIEWER_DRY_RUN=1` so nothing is posted. It makes a fresh `agy` call and writes a dry-run artifact containing the exact prompt payload plus the response.

To dry-run a specific PR:

```bash
scripts/dry-run.sh 123
```

For a specific PR, the artifact is written to:

```text
$REVIEWER_STATE/dry-pr-123.txt
```

Dry runs can target draft PRs and previously reviewed PR heads. They also bypass the required-CI gate by default so you can test prompt behavior before CI has finished. Before launching live scheduling, run at least one dry run with production CI gating enabled:

```bash
REVIEWER_DRY_RUN_BYPASS_CI=0 scripts/dry-run.sh
```

This writes a sibling `.launch.json` metadata file that records the target repo, config hashes, required-check list, and whether CI was bypassed.

To preview exactly what `agy` would receive without calling it:

```bash
scripts/render-prompt.sh 123 --explain
```

Remove `REVIEWER_DRY_RUN=1` (i.e., run `scripts/reviewer/reviewer.sh` directly with your env sourced) when you intentionally want to post a real review.

To iterate on voice or prompt shape, use the tuning wrapper:

```bash
scripts/tune.sh 123
```

It opens the active personality file and `reviewer.env` (posted style, research consent, blinding policy, budgets), then offers to run another dry run.

## 6. Enable The Scheduler

Once the dry run looks good:

```bash
scripts/enable-cron.sh
```

Installs a one-line crontab entry that rotates `cron.log` and runs `run-once.sh` every minute. It first runs `scripts/launch-check.sh`, which refuses to launch unless current live config matches the latest non-bypassed dry-run metadata and required checks are configured. Live reviewer ticks run the same launch validation before posting. Use `REVIEWER_ALLOW_ENABLE_CRON_WITHOUT_LAUNCH_CHECK=1` or `REVIEWER_ALLOW_LIVE_WITHOUT_LAUNCH_CHECK=1` only for intentional emergency bypasses. The reviewer self-throttles to one PR review per tick by default (`REVIEWER_MAX_PRS=1`), so this isn't as aggressive as it sounds.

Prefer systemd? See [docs/daemon-runbook.md#systemd-timer](daemon-runbook.md#systemd-timer).

Watch logs:

```bash
tail -f /var/lib/goobreview/example/log.txt
tail -f /var/lib/goobreview/example/cron.log
```

To pause: edit the crontab (`crontab -e`) and comment out the line, or `sudo systemctl stop goobreview.timer` if you used systemd.

---

## Manual VM Setup

For non-Cloud-Shell paths (own hardware, AWS, manual GCP, corporate GitHub, etc.), keep the same order but use the canonical references for the pieces Cloud Shell normally automates:

1. Provision a small Ubuntu LTS VM, run `bash scripts/setup-vm.sh` to install the tools and clone the template, using [docs/vm-setup.md](vm-setup.md) for details.
2. Register and install the App using [docs/github-app-setup.md](github-app-setup.md). If registering manually, place the `.pem` at `/var/lib/goobreview/example/app-key.pem` with mode `0600`. Registering under an organization: `GOOBREVIEW_GH_ORG=my-org bash scripts/register-app.sh`.
3. Continue at [Step 4 above](#4-finish-setup-on-the-vm) for Antigravity CLI auth, `scripts/configure.sh`, dry run, and scheduler enablement.
