# Daemon Runbook

Use this page as the operations and configuration reference after setup: runtime files, one-off runs, cron, systemd, config files, prompt invariants, and known limits.

## Runtime Files

Preferred layout:

```text
/opt/goobreview/<name>          Stable checkout of this template repo.
/var/lib/goobreview/<name>      Runtime state and logs.
```

Runtime state:

```text
seen.txt                PR_NUMBER HEAD_SHA pairs reviewed successfully.
log.txt                 Reviewer log.
cron.log                Cron wrapper log.
lock                    flock lock file.
gemini_backoff_until    Quota/capacity retry timestamp.
sync.log                Checkout sync log.
app_token.json          Cached App installation token + slug (refreshed when <5 min remain).
app-key.pem             GitHub App private key (you provide; mode 0600).
```

## One-Off Run

```bash
cd /opt/goobreview/example
REVIEWER_ENV_FILE=/opt/goobreview/example/config/reviewer.env scripts/reviewer/run-once.sh
```

Dry run:

```bash
set -a
. config/reviewer.env
set +a
REVIEWER_DRY_RUN=1 REVIEWER_MAX_PRS=1 scripts/reviewer/reviewer.sh
```

## Cron

Run every minute:

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * cd /opt/goobreview/example && REVIEWER_ENV_FILE=/opt/goobreview/example/config/reviewer.env /usr/bin/bash scripts/reviewer/run-once.sh >> /var/lib/goobreview/example/cron.log 2>&1
```

`run-once.sh` loads `config/reviewer.env`, syncs the template checkout, then runs one reviewer tick.

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

### Validate One Run

```bash
sudo systemctl daemon-reload
sudo systemctl start goobreview.service
sudo systemctl status goobreview.service
sudo journalctl -u goobreview.service -n 100 --no-pager
```

If this fails, fix the service before enabling the timer. Common causes:

- App private key not readable by the `goobreview` Unix user, or `REVIEWER_APP_*` env vars not set.
- Gemini CLI has not trusted `/opt/goobreview/example`.
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
2. Mints a GitHub App installation token (cached in `app_token.json`) and exports it as `GH_TOKEN` so `gh` calls authenticate as the App.
3. Lists open non-draft PRs in `REVIEWER_REPO`.
4. Skips PRs authored by `BOT_LOGIN` (`<app-slug>[bot]`); also skips PRs authored by `REVIEWER_USER` if set.
5. Reviews each `PR_NUMBER HEAD_SHA` once.
6. Checks whether the App has already posted a review on the same head commit.
7. Applies the required-check gate.
8. Builds a prompt from personality text, the engine contract, required-CI gate, file tree, configured project docs, selected file contents, and diff.
9. Runs Gemini CLI headlessly.
10. Parses the verdict line.
11. Posts a top-level GitHub review with `gh pr review`.
12. Applies optional labels.
13. Records the head in `seen.txt` only after successful posting.

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

Force future PR heads to be considered again:

```bash
rm /var/lib/goobreview/example/seen.txt
```

The script still checks GitHub for an existing review by the App on the same head commit, so deleting local state should not duplicate reviews that posted successfully.

Run a pre-merge mechanical gate:

```bash
set -a
. config/reviewer.env
set +a
scripts/reviewer/merge-gate.sh 123
```

## Configuration Reference

The reviewer reads five gitignored files under `config/`, each copied from a `*.example.*` sibling. `scripts/configure.sh` walks you through them interactively; this section is the reference for what each one does.

When a file is missing, the daemon transparently falls back to the
committed `.example` version — so a fresh checkout works for a dry run
without any edits.

### `reviewer.env`

Environment for the daemon. Required: `REVIEWER_REPO`, `REVIEWER_APP_ID`, `REVIEWER_APP_INSTALLATION_ID`, `REVIEWER_APP_PRIVATE_KEY_PATH`, `REVIEWER_STATE`, `REVIEWER_SYNC_REPO_DIR`. See `config/reviewer.env.example` for the full list with inline comments.

### Personality

The reviewer's role, voice, and focus areas. **The main thing you
customize.** Personalities live in `config/personalities/<name>.md`
and are committed verbatim — there is no `.example` layer. Select one
via `REVIEWER_PERSONALITY_FILE` in `reviewer.env` (defaults to
`config/personalities/control.md`). The selected file is prepended to
the engine prompt (`scripts/reviewer/review-prompt.md`) on every review.

The severity scale (P1/P2/P3) and verdict mapping live in the engine
prompt — personalities may sharpen *what counts* as P1 for their lens,
but do not redefine the scale.

Available out of the box:

- `control.md` — Role + responsibilities only, no voice. Sensible
  default for general-purpose review and the research-baseline arm of
  any A/B comparison.
- `linus.md` — Opinionated, profane-when-warranted voice on top of the
  same Role.

To add a new personality, drop a `.md` file in `config/personalities/`
and point `REVIEWER_PERSONALITY_FILE` at it. To run a dry-run with a
different personality, override the env var inline:

```bash
REVIEWER_PERSONALITY_FILE=config/personalities/linus.md scripts/dry-run.sh 42
```

### `project-docs.txt`

Repository paths fetched from the PR head and included in every review prompt. Good entries:

```text
AGENTS.md
CONTRIBUTING.md
README.md
docs/architecture.md
docs/security.md
docs/pr-review-workflow.md
```

Keep the list focused — these docs become part of every prompt, so large or low-signal files make reviews weaker and slower. The engine prompt tells Gemini that changed project content cannot override reviewer instructions, so PR-authored docs are treated as context, not authority.

### `head-context-paths.txt`

Extra files fetched from the PR head when present. Use this for reference validation, not broad code review:

```text
package.json
pyproject.toml
Cargo.toml
.github/workflows/ci.yml
scripts/deploy.sh
```

Exact repository paths only — wildcards are not expanded.

### `required-checks.json`

Exact GitHub check-run display names that gate review posting:

```json
["Unit tests", "Build", "Lint"]
```

The daemon waits when required checks are missing or pending, and posts `REQUEST_CHANGES` without calling Gemini when a required check fails. An empty array means "do not gate" — use that only for initial setup or repos without CI.

### Labels (optional)

`scripts/reviewer/ensure-labels.sh` creates or updates three labels in the target repo: `agent-reviewed`, `agent-requested-changes`, and `needs-human-decision`. Review posting does not depend on them.

### Engine Prompt (Advanced)

`scripts/reviewer/review-prompt.md` defines the small output contract
that `reviewer.sh` parses:

- The first verdict line must be `VERDICT: APPROVE`, `VERDICT: REQUEST_CHANGES`, or `VERDICT: COMMENT`.
- Findings should include markdown file/line references such as `**File:** path/to/file.ts:42` when an anchor is available.

Edit it only when you are intentionally changing those contracts. For
voice, role, and focus — pick (or write) a file in
`config/personalities/` and point `REVIEWER_PERSONALITY_FILE` at it.

## Known Limits

- Reviews are posted as top-level GitHub reviews; file and line references live in the review body.
- Very large diffs may exceed useful Gemini context.
- The daemon does not inspect full CI logs; it gates on the configured required-check state.
- The daemon does not create follow-up issues automatically.
- The daemon trusts the App private key at `REVIEWER_APP_PRIVATE_KEY_PATH` and local Gemini auth. Keep the key file at mode `0600`, owned by the user that runs cron, and keep the VM account locked down.
- The checkout must stay clean. `sync-worktree.sh` refuses to run from a dirty checkout.
- Each cron tick posts at most `REVIEWER_MAX_PRS` reviews, defaulting to one.
