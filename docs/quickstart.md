# Quickstart

End-to-end setup from a fresh fork to a posting reviewer in about 10 minutes. Assumes one target repository and one reviewer identity.

The recommended path is Cloud Shell: click the **Open in Cloud Shell** button on the [project README](../README.md) and follow the tutorial pane ([docs/cloud-shell-tutorial.md](cloud-shell-tutorial.md)). It covers VM provisioning (`scripts/bootstrap-gcp.sh`) and GitHub App registration (`scripts/register-app.sh`). This document covers what comes after — finishing setup on the VM — plus the non-Cloud-Shell path.

At any point, run:

```bash
bash scripts/status.sh
```

It summarizes local config, dry-run/scheduler state, active GCloud project/billing readiness, and likely existing GoobReview VMs visible to your account, with a recommended next action.

## 4. Finish Setup On The VM

Gemini should SSH to the VM, enter the checkout, and leave you at the Gemini
CLI sign-in boundary:

```bash
gcloud compute ssh goobreview-1 --zone=us-central1-a
cd /opt/goobreview/example
gemini                # Google OAuth - sign in, trust this folder, then /quit
```

After you quit Gemini CLI, let the setup agent continue with:

```bash
scripts/configure.sh  # auto-detects target repo + installation ID when possible
```

The `gemini` step is intentionally interactive when you want Google-account quota, including Google AI Pro or Ultra entitlement. Gemini CLI's documented non-interactive auth paths are `GEMINI_API_KEY` and Vertex AI credentials, which use API/Vertex quota and billing rather than personal subscription quota. Keep any Gemini API keys, Vertex credentials, or cached Google auth state out of this repo and checkout.

`configure.sh` is the interactive wrapper: it copies each gitignored config file from its `.example` sibling, auto-detects the target repo and installation ID when the App installation exposes exactly one repo, walks you through personality and prompt-payload choices, and offers to create helper labels. It delegates deterministic writes and validation to `scripts/configure-inner.sh`, which agents and scripts can call directly:

```bash
scripts/configure-inner.sh \
  --app-id APP_ID \
  --key-path /var/lib/goobreview/example/app-key.pem \
  --personality config/personalities/control.md \
  --payload-profile lean
```

Add `--create-labels` only when you want the helper labels created. Add
`--repo OWNER/REPO` if the App has access to multiple repos. Add
`--installation-id ID` if you already know it; otherwise the script discovers it.

The most consequential choice is **which personality**: it defines the reviewer's role, voice, and focus areas. Out of the box: `control.md` (general-purpose, no voice direction) or `linus.md` (opinionated, profane-when-warranted). To add a new one, drop a `.md` file in `config/personalities/` in your fork and select it.

The second major choice is **prompt payload**. `lean` keeps reviews centered on the PR by sending compact metadata, a CI pass line, changed paths, relevant guidance paths, the diff, and the response format. `full` turns on the verbose streams, including author body, all-check summary, full file tree, and selected file contents.

Live posting will not fall back to example config. Before enabling the scheduler, make sure `config/required-checks.json` and `config/prompt-payload.json` exist, or set `REVIEWER_REQUIRED_CHECKS_FILE` and `REVIEWER_PROMPT_PAYLOAD_FILE` to valid deployment-specific files.

## 5. Dry Run

Still on the VM:

```bash
scripts/dry-run.sh
```

This runs the reviewer once against your target repo with `REVIEWER_DRY_RUN=1` so nothing is posted. It makes a fresh Gemini call and writes a dry-run artifact containing the exact prompt payload plus Gemini's full response.

To dry-run a specific PR:

```bash
scripts/dry-run.sh 123
```

For a specific PR, the artifact is written to:

```text
$REVIEWER_STATE/dry-pr-123.txt
```

Dry runs can target draft PRs and previously reviewed PR heads. They also bypass the required-CI gate by default so you can test prompt behavior before CI has finished. Set `REVIEWER_DRY_RUN_BYPASS_CI=0` if you want dry runs to match production CI gating.

To preview exactly what Gemini would receive without calling Gemini:

```bash
scripts/render-prompt.sh 123 --explain
```

Remove `REVIEWER_DRY_RUN=1` (i.e., run `scripts/reviewer/reviewer.sh` directly with your env sourced) when you intentionally want to post a real review.

To iterate on voice or prompt shape, use the tuning wrapper:

```bash
scripts/tune.sh 123
```

It opens the active personality and prompt payload files, then offers to run another dry run.

## 6. Enable The Scheduler

Once the dry run looks good:

```bash
scripts/enable-cron.sh
```

Installs a one-line crontab entry that rotates `cron.log` and runs `run-once.sh` every minute. It refuses to launch until at least one dry-run artifact exists in `$REVIEWER_STATE`; set `REVIEWER_ALLOW_ENABLE_CRON_WITHOUT_DRY_RUN=1` only when you intentionally want to bypass that guard. The reviewer self-throttles to one PR review per tick by default (`REVIEWER_MAX_PRS=1`), so this isn't as aggressive as it sounds.

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
3. Continue at [Step 4 above](#4-finish-setup-on-the-vm) for Gemini auth, `scripts/configure.sh`, dry run, and scheduler enablement.
