# Daemon Runbook

Use this page as the operations and configuration reference after setup: runtime files, one-off runs, cron, systemd, config files, prompt invariants, and known limits.

## Runtime Files

Preferred layout:

```text
/opt/goobreview/<name>          Stable checkout of this template repo.
/var/lib/goobreview/<name>      Runtime state and logs.
/tmp/goobreview-runtime-<user>  Default PR snapshot and Gemini runtime root.
```

Runtime state:

```text
log.txt                 Reviewer log.
cron.log                Cron wrapper log.
lock                    flock lock file.
gemini_backoff_until    Quota/capacity retry timestamp.
sync.log                Checkout sync log.
app_token.json          Cached App installation token + slug (refreshed when <5 min remain).
app-key.pem             GitHub App private key (you provide; mode 0600).
dry-pr-<number>.txt     Dry-run artifact with full Gemini prompt payload and response.
```

PR-head source snapshots, Gemini's isolated working directory, and
`gemini-settings.json` are written under `REVIEWER_RUNTIME_STATE`, which
defaults to `${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/goobreview-runtime-$USER`.
Keeping those files away from `REVIEWER_APP_PRIVATE_KEY_PATH` provides
defense in depth if a model is ever tricked into path traversal.

Gemini's Google-account OAuth cache lives under the VM user's home directory,
usually `~/.gemini`, not in `REVIEWER_STATE`. Keep it owned by the Unix user
that runs the reviewer.

## One-Off Run

```bash
cd /opt/goobreview/example
REVIEWER_ENV_FILE=/opt/goobreview/example/config/reviewer.env scripts/reviewer/run-once.sh
```

Dry run:

```bash
scripts/dry-run.sh 123
```

For a numbered PR, the dry run writes
`$REVIEWER_STATE/dry-pr-123.txt`. The artifact includes:

- run metadata;
- the exact Gemini prompt payload;
- Gemini's full response, or stderr if Gemini failed.

Dry runs do not post reviews, do not mark PRs reviewed, can target draft
PRs by number, and bypass the required-CI gate by default so prompt
configuration can be tested before CI is terminal. Set
`REVIEWER_DRY_RUN_BYPASS_CI=0` to keep production CI gating during a dry
run. Set `REVIEWER_DRY_RUN_OUT=/path/to/file.txt` to choose a different
artifact path.

Render the exact Gemini prompt text for one PR without calling Gemini
or posting a review:

```bash
scripts/render-prompt.sh 123 /tmp/goobreview-prompt.md
```

Omit the output path to print the prompt to stdout. The PR must pass the
configured required-check gate, because failing or pending CI means the
daemon would not send a prompt to Gemini for that head commit.
Add `--explain` to print the enabled prompt payload segments; when no
output path is provided, the prompt is written to `/tmp/goobreview-prompt-<PR>.md`.

## Cron

Run every minute:

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * cd /opt/goobreview/example && REVIEWER_ENV_FILE=/opt/goobreview/example/config/reviewer.env /usr/bin/bash scripts/reviewer/rotate-log.sh /var/lib/goobreview/example/cron.log && REVIEWER_ENV_FILE=/opt/goobreview/example/config/reviewer.env /usr/bin/bash scripts/reviewer/run-once.sh >> /var/lib/goobreview/example/cron.log 2>&1
```

`scripts/enable-cron.sh` installs this with shell-quoted paths. The
`rotate-log.sh` pre-step keeps `cron.log` from growing forever. The daemon
also rotates `log.txt` and `sync.log`; tune this with
`REVIEWER_LOG_MAX_BYTES` and `REVIEWER_LOG_ROTATE_KEEP`.

`run-once.sh` loads `config/reviewer.env`, syncs the template checkout, then runs one reviewer tick.

`scripts/enable-cron.sh` refuses to install the cron entry until it finds at least one dry-run artifact (`dry-run-*.txt` or `dry-pr-*.txt`) in `$REVIEWER_STATE`. To bypass that deliberately, set `REVIEWER_ALLOW_ENABLE_CRON_WITHOUT_DRY_RUN=1`.

## Systemd Timer

A systemd timer is the recommended durable scheduler when you control the VM. Cron is fine for quick setup, but systemd gives better status, logs, restart behavior, and auditable unit files.

This section assumes:

- checkout: `/opt/goobreview/example`
- state directory: `/var/lib/goobreview/example`
- Unix user: `goobreview`
- config file: `/opt/goobreview/example/config/reviewer.env`

Adjust names and paths for each reviewer identity.

### Create The User And Directories

```bash
sudo useradd --system --create-home --shell /bin/bash goobreview
sudo mkdir -p /opt/goobreview/example /var/lib/goobreview/example
sudo chown -R goobreview:goobreview /opt/goobreview /var/lib/goobreview
```

Clone and configure the repo as that user, install the App private key as that user (e.g. `scp` it to `/var/lib/goobreview/example/app-key.pem`, then `chmod 600`), and authenticate Gemini CLI as that same user.

### Install Unit Files

```bash
sudo cp deploy/systemd/goobreview.service.example /etc/systemd/system/goobreview.service
sudo cp deploy/systemd/goobreview.timer.example /etc/systemd/system/goobreview.timer
sudo systemctl edit --full goobreview.service   # adjust paths/user if needed
sudo systemctl edit --full goobreview.timer
```

The example service includes a dry-run artifact gate. It refuses to run until
`$REVIEWER_STATE` contains `dry-run-*.txt` or `dry-pr-*.txt`; set
`REVIEWER_ALLOW_ENABLE_SYSTEMD_WITHOUT_DRY_RUN=1` only for an intentional
override.

### Validate One Run

```bash
sudo systemctl daemon-reload
sudo systemctl start goobreview.service
sudo systemctl status goobreview.service
sudo journalctl -u goobreview.service -n 100 --no-pager
```

If this fails, fix the service before enabling the timer. Common causes:

- App private key not readable by the `goobreview` Unix user, or `REVIEWER_APP_*` env vars not set.
- Gemini CLI has not authenticated for the Unix user that runs the service, or the checkout trust prompt was never completed. The daemon runtime under `REVIEWER_RUNTIME_STATE/gemini-runtime` uses Gemini CLI's documented `GEMINI_CLI_TRUST_WORKSPACE=true` session override, but initial Google-account auth still needs to exist.
- `config/reviewer.env` is missing or points to the wrong target repo.
- The App is not installed on `REVIEWER_REPO` (token mint will fail).
- The checkout is dirty, so `sync-worktree.sh` refuses to run.

### Enable The Timer

```bash
sudo systemctl enable --now goobreview.timer
systemctl list-timers goobreview.timer
sudo journalctl -u goobreview.service -f
```

### Multiple Reviewers

Use one unit pair per reviewer identity (`goobreview-alice.service`/`.timer`, `goobreview-bob.service`/`.timer`, ...). Each identity needs its own Unix user, checkout, App credentials, Gemini auth + trusted checkout, state directory, and `config/reviewer.env`.

## What The Reviewer Does

1. Acquires a non-blocking `flock`.
2. Mints a GitHub App installation token (cached in `app_token.json`) and exports it as `GH_TOKEN` so direct API calls and the final `gh pr review` authenticate as the App.
3. Lists open non-draft PRs in `REVIEWER_REPO`.
4. Skips PRs authored by `BOT_LOGIN` (`<app-slug>[bot]`); also skips PRs authored by `REVIEWER_USER` if set.
5. Checks whether the App has already posted a review on the same head commit (via the GitHub API); skips if so.
6. Applies the required-check gate.
7. Downloads a PR-head source snapshot to `REVIEWER_RUNTIME_STATE/worktrees/<repo>/current`.
8. Builds a prompt from the enabled segments in `config/prompt-payload.json` (for example: personality, compact PR metadata, CI one-liner, changed paths, relevant guidance, diff, and the GitHub review formatting rule).
9. Runs Gemini CLI headlessly from `REVIEWER_RUNTIME_STATE/gemini-runtime`, with the PR-head snapshot attached as read-only workspace context, PR-authored `GEMINI.md` / `.env` files excluded from automatic context, MCP servers disabled for the review invocation, and Gemini CLI's documented `GEMINI_CLI_TRUST_WORKSPACE=true` session override set for that isolated runtime directory.
10. Parses the GitHub review event line.
11. Posts a top-level GitHub review with `gh pr review`.
12. Applies optional labels.

## Operations

Pause:

```bash
crontab -e
```

Comment out the cron line.

Watch logs:

```bash
tail -f /var/lib/goobreview/example/log.txt
tail -f /var/lib/goobreview/example/cron.log
tail -f /var/lib/goobreview/example/sync.log
```

Force a re-review of a PR at its current head commit:

Delete the bot's review on GitHub (via the pull request UI or `gh api -X DELETE "repos/OWNER/REPO/pulls/PR/reviews/REVIEW_ID"`), then the daemon will re-review on the next tick.

Run a pre-merge mechanical gate:

```bash
set -a
. config/reviewer.env
set +a
scripts/reviewer/merge-gate.sh 123
```

Inspect GitHub App token setup:

```bash
scripts/reviewer/get-installation-token.sh discover OWNER/REPO
scripts/reviewer/get-installation-token.sh token
scripts/reviewer/get-installation-token.sh slug
```

`discover` only needs `REVIEWER_APP_ID` and `REVIEWER_APP_PRIVATE_KEY_PATH`.
`token` and `slug` also need `REVIEWER_APP_INSTALLATION_ID` and
`REVIEWER_STATE` so the short-lived installation token can be cached. For
one-off diagnostics before `reviewer.env` is fully populated, the underlying
Node helper accepts direct flags:

```bash
node scripts/reviewer/lib/app-token.mjs discover OWNER/REPO \
  --app-id APP_ID \
  --key-path /var/lib/goobreview/example/app-key.pem

node scripts/reviewer/lib/app-token.mjs token \
  --app-id APP_ID \
  --installation-id INSTALLATION_ID \
  --key-path /var/lib/goobreview/example/app-key.pem \
  --state /var/lib/goobreview/example
```

## Configuration Reference

The reviewer reads three gitignored files under `config/`, each copied from a `*.example.*` sibling. `scripts/configure.sh` writes them interactively, and the example files themselves carry the authoritative inline documentation:

- **`config/reviewer.env`** (from `reviewer.env.example`) — daemon environment. Required: `REVIEWER_REPO`, `REVIEWER_APP_ID`, `REVIEWER_APP_INSTALLATION_ID`, `REVIEWER_APP_PRIVATE_KEY_PATH`, `REVIEWER_STATE`, `REVIEWER_SYNC_REPO_DIR`, and `REVIEWER_PERSONALITY_FILE` (no default — the daemon fails loudly when it is unset; `configure.sh` pre-selects `config/personalities/control.md`).
- **`config/prompt-payload.json`** (from `prompt-payload.example.json`) — which prompt segments Gemini receives. Each segment has an `enabled` flag, description, and example; the example file documents every segment. `configure.sh` offers `minimal`/`lean`/`guided`/`full` presets, with `lean` as the default. Inspect the assembled payload with `scripts/render-prompt.sh 123 --explain`.
- **`config/required-checks.json`** (from `required-checks.example.json`) — exact GitHub check-run display names that gate review posting. The daemon waits while required checks are missing or pending, and posts `REQUEST_CHANGES` without calling Gemini when one fails. An empty array means "do not gate" — only for initial setup or repos without CI.

When a file is missing, the daemon transparently falls back to the committed `.example` version, so a fresh checkout works for a dry run without any edits.

Personalities are the exception to the `.example` pattern: `config/personalities/<name>.md` files are committed verbatim and selected via `REVIEWER_PERSONALITY_FILE`. To try one in a dry run without editing config:

```bash
REVIEWER_PERSONALITY_FILE=config/personalities/linus.md scripts/dry-run.sh 42
```

The engine prompt at `scripts/reviewer/review-prompt.md` only defines the parsed output contract (first line `APPROVE`/`REQUEST_CHANGES`/`COMMENT`, rest is the review body) — edit it only to change that contract; everything voice-related belongs in a personality file.

### Optional Runtime Switches

Env vars (set in `reviewer.env` or inline) beyond the required set:

- `REVIEWER_APPLY_LABELS` — apply the helper labels after posting (default `1`; set `0` to disable). `scripts/reviewer/ensure-labels.sh` creates the labels; review posting never depends on them.
- `REVIEWER_IGNORE_GEMINI_BACKOFF` — set `1` to run even while a Gemini quota backoff (`gemini_backoff_until`) is active. `dry-run.sh` sets this automatically.
- `REVIEWER_REQUIRED_CHECKS_JSON` + `REVIEWER_ALLOW_REQUIRED_CHECKS_OVERRIDE=1` — override the required-check gate from the environment for one-off runs; both must be set, so a stray env var cannot loosen a production gate.
- `REVIEWER_SYNC_REMOTE`, `REVIEWER_SYNC_BRANCH`, `REVIEWER_SYNC_LOG` — which remote/branch `sync-worktree.sh` tracks (default `origin`/`main`) and where it logs.
- `REVIEWER_ONLY_PR` — restrict a run (including `merge-gate.sh`) to a single PR number.
- `REVIEWER_RUNTIME_STATE`, `REVIEWER_LOG_MAX_BYTES`, `REVIEWER_LOG_ROTATE_KEEP` — runtime dir and log rotation controls; see `config/reviewer.env.example`.

## Known Limits

- Reviews are posted as top-level GitHub reviews; file and line references live in the review body.
- Very large diffs may exceed useful Gemini context.
- PR-head source snapshots are provided as read-only context under `REVIEWER_RUNTIME_STATE/worktrees/<repo>/current`; Gemini itself runs from `REVIEWER_RUNTIME_STATE/gemini-runtime`, and the daemon does not run project code from the snapshot.
- Google-account Gemini CLI auth is still an interactive, user-bound setup step. Gemini CLI's documented non-interactive auth modes are Gemini API key or Vertex AI; those do not preserve personal Google AI Pro/Ultra subscription entitlement.
- The daemon does not inspect full CI logs; it gates on the configured required-check state.
- The daemon does not create follow-up issues automatically.
- The daemon trusts the App private key at `REVIEWER_APP_PRIVATE_KEY_PATH` and local Gemini auth. Keep the key file at mode `0600`, owned by the user that runs cron, and keep the VM account locked down.
- The checkout must stay clean. `sync-worktree.sh` refuses to update a dirty checkout; `run-once.sh` logs that failure and continues one reviewer tick with the current checkout.
- Each cron tick posts at most `REVIEWER_MAX_PRS` reviews, defaulting to one.
