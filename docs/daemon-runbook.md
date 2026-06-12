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
*.txt.launch.json       Launch metadata from a dry run: repo, config hashes, required checks, and CI-bypass state.
```

`REVIEWER_STATE` is created and repaired to mode `0700` by the reviewer.
If the daemon cannot make it owner-only, it fails before reviewing. Files
that may contain prompt, model, token-cache, or diagnostic material are
written with mode `0600` by default, including dry-run artifacts,
dry-run launch metadata, prompt render outputs, invalid-output artifacts,
and App token cache files. Keep the state directory owned by the Unix user
that runs the reviewer.

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

Dry-run artifacts are stored under `REVIEWER_STATE` by default and are
installed with mode `0600`. Before writing the artifact, the reviewer scans
the assembled content for high-confidence secret material such as private-key
blocks and credential-style assignments for GitHub, Gemini, Google Cloud,
AWS, Azure, and App key path variables. If such material is detected, the
reviewer logs a clear refusal and does not write the artifact. The scan is
intended to reject obvious secret values while still allowing ordinary PR
diffs or docs that mention environment variable names without printing values.

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
Add `--explain` to print the active blinding-policy flags; when no
output path is provided, the prompt is written to a `mktemp` file under
`REVIEWER_STATE` with mode `0600`.

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

`run-once.sh` loads `config/reviewer.env`, takes the reviewer lock, syncs
the template checkout, then runs one reviewer tick under that same lock. If
another scheduler invocation already holds the lock, the tick logs `sync
skipped by lock` and exits without touching the checkout. If sync fails, the
tick logs `sync failed before reviewer tick; review did not run` and exits
before any review can be posted. A successful handoff logs `sync succeeded;
review tick started`.

For emergency/manual operation only, set
`REVIEWER_ALLOW_STALE_CHECKOUT_ON_SYNC_FAILURE=1` to let `run-once.sh`
continue from the current checkout after a sync failure. Leave it unset or
`0` for scheduled live operation.

`scripts/enable-cron.sh` runs `scripts/launch-check.sh` before installing the cron entry. Live `reviewer.sh` ticks run the same validation before posting. The launch check requires current live config files, matching dry-run launch metadata, nonempty required checks, and a dry run that used production CI gating (`REVIEWER_DRY_RUN_BYPASS_CI=0`). To bypass scheduler validation deliberately, set `REVIEWER_ALLOW_ENABLE_CRON_WITHOUT_LAUNCH_CHECK=1`. To bypass live tick validation deliberately, set `REVIEWER_ALLOW_LIVE_WITHOUT_LAUNCH_CHECK=1`. Narrower launch-check bypasses are `REVIEWER_ALLOW_LAUNCH_WITH_BYPASSED_CI=1` and `REVIEWER_ALLOW_LAUNCH_WITHOUT_REQUIRED_CHECKS=1`.

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

The example service includes a dry-run artifact gate. Prefer running
`scripts/launch-check.sh` before enabling any live daemon path so systemd gets
the same current-config validation as cron.

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
2. Mints a GitHub App installation token (cached in `app_token.json`) and exports it as `GH_TOKEN` for GitHub API calls.
3. Lists open non-draft PRs in `REVIEWER_REPO`.
4. Skips PRs authored by `BOT_LOGIN` (`<app-slug>[bot]`); also skips PRs authored by `REVIEWER_USER` if set.
5. Checks whether the App has already posted a review on the same head commit (via the GitHub API); skips if so.
6. Counts the PR against `REVIEWER_MAX_ATTEMPTS`, then applies the required-check gate.
7. Downloads a PR-head source snapshot to `REVIEWER_RUNTIME_STATE/worktrees/<repo>/current` and neutralizes any symlinks into metadata stubs before prompt assembly or Gemini access.
8. Builds the prompt: personality, trust preamble, compact PR metadata with the author's description as claims to verify (author username blinded by default), commit subjects, GitHub check-run results, previous bot review on the same PR, the snapshot mount path with a pointer at the repo's own `AGENTS.md`/`CONTRIBUTING.md`/`GUIDELINES.md` conventions, the per-file diff with changed-file index and whole-file omission markers (lockfiles plus the repo's `.gitattributes` `linguist-generated` patterns), and the GitHub review formatting rule. Composition is fixed in `scripts/reviewer/lib/prompt.sh`; blinding policy and budgets come from `reviewer.env`.
9. Runs Gemini CLI headlessly from `REVIEWER_RUNTIME_STATE/gemini-runtime`, with the PR-head snapshot attached as read-only workspace context, PR-authored `GEMINI.md` / `.env` files excluded from automatic context, MCP servers disabled for the review invocation, and Gemini CLI's documented `GEMINI_CLI_TRUST_WORKSPACE=true` session override set for that isolated runtime directory.
10. Parses the GitHub review event line.
11. Posts a top-level GitHub review through the GitHub REST API.
12. Applies optional labels.

Queued skips, attempted reviews, and posted reviews are separate counters.
Drafts, self-authored PRs, PRs outside `REVIEWER_ONLY_PR`, and
already-reviewed PR heads are queued skips and stay cheap. A PR becomes an
attempted review when the daemon starts work that can spend API/model/runtime
budget, such as CI reads, worktree preparation, prompt assembly, Gemini
invocation, or posting. Posted reviews are the successful dry-run/render/post
actions counted by `REVIEWER_MAX_PRS`.

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

This optional operator helper uses GitHub CLI (`gh`); the reviewer daemon and
VM setup path do not require it.

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

The reviewer reads two gitignored files under `config/`, each copied from a `*.example.*` sibling. `scripts/configure.sh` writes them interactively, and the example files themselves carry the authoritative inline documentation:

- **`config/reviewer.env`** (from `reviewer.env.example`) — daemon environment. Required: `REVIEWER_REPO`, `REVIEWER_APP_ID`, `REVIEWER_APP_INSTALLATION_ID`, `REVIEWER_APP_PRIVATE_KEY_PATH`, `REVIEWER_STATE`, `REVIEWER_SYNC_REPO_DIR`, and `REVIEWER_PERSONALITY_FILE` (no default — the daemon fails loudly when it is unset; `configure.sh` pre-selects `config/personalities/control.md`). Also carries the blinding policy: `REVIEWER_INCLUDE_AUTHOR` (default `0`), `REVIEWER_INCLUDE_DESCRIPTION` and `REVIEWER_INCLUDE_COMMIT_SUBJECTS` (default `1`).
- **`config/required-checks.json`** (from `required-checks.example.json`) — exact GitHub check-run display names that gate review posting. The daemon fetches all check-run pages for the PR head before deciding whether a required check is missing, waits while required checks are missing or pending, and posts `REQUEST_CHANGES` without calling Gemini when one fails. An empty array means "do not gate" — only for initial setup or repos without CI.

GitHub API calls are bounded by default. Shell-based REST calls use `REVIEWER_GITHUB_CONNECT_TIMEOUT` (default `10` seconds), `REVIEWER_GITHUB_MAX_TIME` (default `60` seconds), `REVIEWER_GITHUB_RETRIES` (default `2` retries for safe transient GET failures such as network errors, 5xx, 429, or rate-limit-like 403 responses), and `REVIEWER_GITHUB_RETRY_SLEEP` (default `1` second between attempts). The Node App-token helper uses `REVIEWER_GITHUB_FETCH_TIMEOUT` (default `60` seconds) as its fetch abort timeout. Failed GitHub API calls log the method, path, curl status, HTTP status, attempt count, and a short redacted response snippet so operators can distinguish auth/configuration errors from transient GitHub failures without leaking tokens. Check-run summaries include whether the fetched data is complete and whether the displayed rows were intentionally truncated; set `REVIEWER_CHECK_RUN_SUMMARY_LIMIT` (default `200`) to change the display limit without changing required-check gating.

Prompt assembly is also bounded by default. The diff degrades per file: `REVIEWER_DIFF_FILE_MAX_BYTES` (default `40000`) and `REVIEWER_DIFF_MAX_BYTES` (default `120000`) cap the per-file and total patch budgets, and a file over budget (or matching a built-in lockfile pattern or the target repo's `.gitattributes` `linguist-generated` patterns, or served without a text patch by GitHub) is replaced whole by an explicit `goobreview` omission marker — never cut mid-hunk. Omitted files remain readable in the PR-head snapshot. After assembly, `REVIEWER_MAX_PROMPT_BYTES` (default `240000`) is a hard fail-closed budget checked before Gemini is invoked. Dry-run output is capped by `REVIEWER_MAX_ARTIFACT_BYTES` (default `1000000`) and marked when truncated.

Live posting requires real deployment config. `scripts/reviewer/reviewer.sh` refuses live mode unless `config/required-checks.json` exists, or `REVIEWER_REQUIRED_CHECKS_FILE` explicitly points at a valid file. Run `scripts/configure.sh` to create the local file from its `.example` sibling. Dry-run and prompt-rendering paths may still use the committed example so first-run setup can inspect behavior before launching.

Before enabling cron or another live daemon, run:

```bash
REVIEWER_DRY_RUN_BYPASS_CI=0 scripts/dry-run.sh
scripts/launch-check.sh
```

The first command writes the normal dry-run artifact and a sibling `.launch.json` file. The second confirms that the launch metadata still matches the current target repo and required-check config.

Personalities are the exception to the `.example` pattern: `config/personalities/<name>.md` files are committed verbatim and selected via `REVIEWER_PERSONALITY_FILE`. To try one in a dry run without editing config:

```bash
REVIEWER_PERSONALITY_FILE=config/personalities/linus.md scripts/dry-run.sh 42
```

The engine prompt at `scripts/reviewer/review-prompt.md` only defines the parsed output contract (first line `APPROVE`/`REQUEST_CHANGES`/`COMMENT`, rest is the review body) — edit it only to change that contract; everything voice-related belongs in a personality file.

### Optional Runtime Switches

Env vars (set in `reviewer.env` or inline) beyond the required set:

- `REVIEWER_APPLY_LABELS` — apply the helper labels after posting (default `1`; set `0` to disable). `scripts/reviewer/ensure-labels.sh` creates the labels; review posting never depends on them.
- `REVIEWER_MAX_ATTEMPTS` — maximum non-skipped PRs to attempt in one tick. Defaults to `REVIEWER_MAX_PRS`. Reaching this limit logs `Reached REVIEWER_MAX_ATTEMPTS=...` and stops the tick.
- `REVIEWER_IGNORE_GEMINI_BACKOFF` — set `1` to run even while a Gemini quota backoff (`gemini_backoff_until`) is active. `dry-run.sh` sets this automatically.
- `REVIEWER_REQUIRED_CHECKS_JSON` + `REVIEWER_ALLOW_REQUIRED_CHECKS_OVERRIDE=1` — override the required-check gate from the environment for one-off runs; both must be set, so a stray env var cannot loosen a production gate.
- `REVIEWER_ALLOW_LIVE_WITHOUT_LAUNCH_CHECK` — emergency bypass for the live tick launch gate. Prefer rerunning `REVIEWER_DRY_RUN_BYPASS_CI=0 scripts/dry-run.sh` and `scripts/launch-check.sh`.
- `REVIEWER_SYNC_REMOTE`, `REVIEWER_SYNC_BRANCH`, `REVIEWER_SYNC_LOG` — which remote/branch `sync-worktree.sh` tracks (default `origin`/`main`) and where it logs.
- `REVIEWER_ALLOW_STALE_CHECKOUT_ON_SYNC_FAILURE` — emergency/manual override; set to `1` only when you intentionally want a scheduler tick to run from the current checkout after sync fails. Default `0` fails closed.
- `REVIEWER_ONLY_PR` — restrict a run (including `merge-gate.sh`) to a single PR number.
- `REVIEWER_RUNTIME_STATE`, `REVIEWER_LOG_MAX_BYTES`, `REVIEWER_LOG_ROTATE_KEEP` — runtime dir and log rotation controls; see `config/reviewer.env.example`.

## Known Limits

- Reviews are posted as top-level GitHub reviews; file and line references live in the review body.
- Very large diffs may exceed useful Gemini context.
- Prompt and dry-run artifact size limits are explicit runtime knobs; truncated context is marked in the prompt/artifact, and prompts that still exceed `REVIEWER_MAX_PROMPT_BYTES` fail before Gemini is called.
- PR-head source snapshots are provided as read-only context under `REVIEWER_RUNTIME_STATE/worktrees/<repo>/current`; Gemini itself runs from `REVIEWER_RUNTIME_STATE/gemini-runtime`, and the daemon does not run project code from the snapshot. Symlinks in PR-head snapshots are neutralized into metadata stubs, and any raw symlink that reaches prompt assembly or Gemini access is skipped/refused rather than dereferenced.
- Google-account Gemini CLI auth is still an interactive, user-bound setup step. Gemini CLI's documented non-interactive auth modes are Gemini API key or Vertex AI; those do not preserve personal Google AI Pro/Ultra subscription entitlement.
- The daemon does not inspect full CI logs; it gates on the configured required-check state.
- The daemon does not create follow-up issues automatically.
- The daemon trusts the App private key at `REVIEWER_APP_PRIVATE_KEY_PATH` and local Gemini auth. Keep the key file at mode `0600`, owned by the user that runs cron, and keep the VM account locked down.
- The checkout must stay clean. `sync-worktree.sh` refuses to update a dirty checkout; `run-once.sh` logs that failure and exits before reviewing unless `REVIEWER_ALLOW_STALE_CHECKOUT_ON_SYNC_FAILURE=1` is set deliberately.
- Each cron tick attempts at most `REVIEWER_MAX_ATTEMPTS` non-skipped PRs and posts at most `REVIEWER_MAX_PRS` reviews. Both default to one.
