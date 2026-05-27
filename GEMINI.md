# GEMINI.md - GoobReview Setup Playbook

You are helping a user set up GoobReview, an automated GitHub PR reviewer that
runs from a small VM. Drive the setup end to end, but keep the user in control
of cloud resources, GitHub App creation, browser-only steps, and scheduler
launch.

Start every session with:

```bash
bash scripts/status.sh
```

Use the status output to jump to the right phase. Do not restart the flow from
the beginning if a later phase is already complete.

## Non-Negotiables

- Confirm before creating cloud resources, public repos, persistent credentials,
  or enabling the scheduler.
- Never place GitHub App private keys, Gemini credentials, or cloud credentials
  in the repo.
- Keep the GitHub App `.pem` on the VM at `REVIEWER_APP_PRIVATE_KEY_PATH`
  (default: `$REVIEWER_STATE/app-key.pem`) with mode `0600`.
- Do not enable cron until at least one dry-run artifact exists and the user has
  inspected it.
- Do not post a real review during setup. Use `scripts/dry-run.sh` and
  `scripts/tune.sh`.

## Phase 1 - Provision

Goal: VM exists, dependencies are installed, and the repo is cloned on the VM.

Check:

```bash
bash scripts/preflight/gcloud.sh
bash scripts/preflight/vm.sh
```

If the VM is missing, ask the user for project, zone, and VM name, then confirm
before creating anything. For agent-driven setup, use the flag path:

```bash
bash scripts/bootstrap-gcp.sh \
  --project PROJECT_ID \
  --zone us-central1-a \
  --vm-name goobreview-1 \
  --yes
```

If there are multiple billing accounts, re-run with
`--billing-account ACCOUNT`. Let `bootstrap-gcp.sh` handle project/billing
repair and VM creation. If it prints a browser billing/project task, explain
the next click and wait for the user to return.

## Phase 2 - Register

Goal: GitHub App exists, its private key is on the VM, and the App is installed
on the target repo.

Check:

```bash
bash scripts/preflight/app.sh
```

If the App is not registered:

```bash
bash scripts/register-app.sh
```

Tell the user:

1. Open Cloud Shell Web Preview on port 8080.
2. Create the GitHub App from the pre-filled form.
3. Generate and upload the private key.
4. Click the install URL and install the App on the target repo.

You cannot complete the GitHub browser steps for them.

## Phase 3 - Configure

Goal: `reviewer.env`, App credentials, required checks, personality, and prompt
payload are configured.

For humans, use:

```bash
scripts/configure.sh
```

For agent-driven setup, prefer the non-interactive core:

```bash
scripts/configure-inner.sh \
  --repo OWNER/REPO \
  --app-id APP_ID \
  --key-path /var/lib/goobreview/example/app-key.pem \
  --personality config/personalities/control.md \
  --payload-profile lean
```

Add `--installation-id ID` only if discovery is not desired or has already been
done. Add `--create-labels` only after asking the user. Add
`--allow-missing-gemini` only if the user intentionally wants to configure
before authenticating Gemini.

Gemini CLI auth on the VM is manual:

```bash
gemini
# sign in, trust this folder, then /quit
```

## Phase 4 - Tune

Goal: the user has inspected at least one dry-run artifact and likes the
reviewer's behavior.

Run a specific PR when possible:

```bash
scripts/tune.sh PR_NUMBER
```

or:

```bash
scripts/dry-run.sh PR_NUMBER
```

Artifacts are written under `$REVIEWER_STATE` as `dry-pr-<number>.txt` or
`dry-run-<timestamp>.txt`. Summarize what the reviewer would post and ask the
user whether to adjust personality or prompt payload before launch.

## Phase 5 - Launch

Goal: scheduler enabled only after a satisfactory dry run.

Before launch:

```bash
bash scripts/status.sh
```

If dry-run artifacts exist and the user approves:

```bash
scripts/enable-cron.sh
```

Watch logs:

```bash
tail -f /var/lib/goobreview/example/log.txt
tail -f /var/lib/goobreview/example/cron.log
```

To pause, edit the crontab and comment out the line marked
`# GoobReview reviewer (managed by scripts/enable-cron.sh)`.
