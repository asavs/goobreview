# Daemon Runbook

Use this page as the operations and configuration reference after setup: runtime files, one-off runs, cron, systemd, config files, prompt invariants, and known limits.

## Runtime Files

Preferred layout:

```text
/opt/goobreview/<name>          Stable checkout of this template repo.
/var/lib/goobreview/<name>      Runtime state and logs.
/tmp/goobreview-runtime-<user>  Default PR snapshot and Antigravity runtime root.
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
dry-pr-<number>.txt     Dry-run artifact with full agy prompt payload and response.
research-runs/          Consented public-repo paired control/Linus artifacts.
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

- run metadata, including the parsed event, resolved inline-review comments that would be submitted, and any explicitly selected bot-owned threads that would be auto-resolved if enabled;
- a sanitized agy execution context: command shape, model, timeout, runtime cwd, PR-head snapshot path/counts, runtime `AGENTS.md`/prompt/response hashes, stderr hash, and a note that agy's injected system prompt and tool definitions are not observable from GoobReview;
- the daemon-generated runtime `AGENTS.md` containing trusted reviewer instructions and GitHub API facts;
- the exact Gemini prompt payload;
- Gemini stderr;
- Gemini's full response, or stderr as the response body if Gemini failed.

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
`REVIEWER_DRY_RUN_BYPASS_CI=0` when you specifically want a dry run to wait
for the configured check gate. Set `REVIEWER_DRY_RUN_OUT=/path/to/file.txt`
to choose a different artifact path.

Render the exact prompt text for one PR without calling agy
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

`scripts/enable-cron.sh` runs `scripts/launch-check.sh` before installing the cron entry. The launch check requires current live config files and a successful dry-run metadata artifact for the current target repo. Required checks may be nonempty, meaning "review every ready PR head after those checks pass," or `[]`, meaning "review every ready PR head without waiting for CI." To bypass scheduler validation deliberately, set `REVIEWER_ALLOW_ENABLE_CRON_WITHOUT_LAUNCH_CHECK=1`.

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
8. Writes trusted material to the isolated agy runtime `AGENTS.md`: the configured posted style (`REVIEWER_POSTED_PERSONALITY=none` uses `control.md`; `linus` uses `linus.md`), a shared evidence-first reviewer contract, GitHub check-run rows with run URLs, the GitHub review formatting rule, the read-only snapshot mount path with a pointer at the repo's own `AGENTS.md`/`CONTRIBUTING.md`/`GUIDELINES.md` conventions, and the trust boundary. The snapshot directive is trusted instruction — it must sit beside the trust boundary in `AGENTS.md`, not in the prompt that boundary tells agy to treat as data, or agy stops inspecting the snapshot. The `--print` prompt then carries untrusted PR material: compact PR orientation (title, base branch, and head branch; author and PR body blinded by default), commit subjects, the subject of the prior bot review on the same PR (not its full body), unresolved bot-created inline review threads from GitHub's durable thread state, workflow files and package scripts from the PR-head snapshot, and the per-file diff with changed-file index and whole-file omission markers (lockfiles plus the repo's `.gitattributes` `linguist-generated` patterns). Composition is fixed in `scripts/reviewer/lib/prompt.sh`; posted style, research consent, blinding policy, and budgets come from `reviewer.env`.
9. Runs Gemini CLI headlessly from `REVIEWER_RUNTIME_STATE/gemini-runtime`, with the PR-head snapshot attached as read-only workspace context, PR-authored `GEMINI.md` / `.env` files excluded from automatic context, MCP servers disabled for the review invocation, and Gemini CLI's documented `GEMINI_CLI_TRUST_WORKSPACE=true` session override set for that isolated runtime directory.
10. Parses the GitHub review event line.
11. Re-reads the PR head and unresolved bot-created review threads, then atomically posts the GitHub review event, summary, and any verified inline comments through the GitHub REST API. There is no line-matching dedup: the reviewer is shown its open threads by handle and asked to address each one explicitly, so a re-raised finding at most produces a visible duplicate thread rather than silently swallowing a genuine new finding.
12. If `REVIEWER_AUTO_RESOLVE_BOT_THREADS=1`, resolves unresolved GitHub review threads originally opened by this bot only when the review body explicitly lists their handle (a slug derived from the thread's heading) in a `Resolved Prior Threads` section and GitHub reports the App can resolve them. Each resolution posts a confirming reply into the thread first, so it reads as a conversation turn rather than a silent state flip.
13. If `REVIEWER_RESEARCH_CONSENT=1` and the target repository is public, saves paired control/Linus prompt+response artifacts under `REVIEWER_STATE/research-runs/`. The posted style is still the only review posted to GitHub; the other style is counterfactual research data.

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
`REVIEWER_STATE` so the short-lived installation token can be cached. The
helper is pure shell (`openssl` signs the JWT, `curl` calls the API) and reads
everything from the `REVIEWER_*` environment, so for one-off diagnostics before
`reviewer.env` is fully populated, export the values inline:

```bash
REVIEWER_APP_ID=APP_ID \
REVIEWER_APP_PRIVATE_KEY_PATH=/var/lib/goobreview/example/app-key.pem \
  scripts/reviewer/get-installation-token.sh discover OWNER/REPO

REVIEWER_APP_ID=APP_ID \
REVIEWER_APP_INSTALLATION_ID=INSTALLATION_ID \
REVIEWER_APP_PRIVATE_KEY_PATH=/var/lib/goobreview/example/app-key.pem \
REVIEWER_STATE=/var/lib/goobreview/example \
  scripts/reviewer/get-installation-token.sh token
```

## Configuration Reference

The reviewer reads two gitignored files under `config/`, each copied from a `*.example.*` sibling. `scripts/configure.sh` writes them interactively, and the example files themselves carry the authoritative inline documentation:

- **`config/reviewer.env`** (from `reviewer.env.example`) — daemon environment. Required: `REVIEWER_REPO`, `REVIEWER_APP_ID`, `REVIEWER_APP_INSTALLATION_ID`, `REVIEWER_APP_PRIVATE_KEY_PATH`, `REVIEWER_STATE`, `REVIEWER_SYNC_REPO_DIR`, and `REVIEWER_POSTED_PERSONALITY` (`none` or `linus`; default `none`). `REVIEWER_RESEARCH_CONSENT` defaults to `0`; when set to `1`, public live reviews retain paired control/Linus artifacts under `REVIEWER_STATE/research-runs/`. Also carries the blinding policy: `REVIEWER_INCLUDE_AUTHOR` and `REVIEWER_INCLUDE_DESCRIPTION` (default `0`), and `REVIEWER_INCLUDE_COMMIT_SUBJECTS` (default `1`).
- **`config/required-checks.json`** (from `required-checks.example.json`) — exact GitHub check-run display names that gate review posting. The daemon fetches all check-run pages for the PR head before deciding whether a required check is missing, waits while required checks are missing or pending, and posts `REQUEST_CHANGES` without calling Gemini when one fails. An empty array means "review every ready PR head without waiting for CI" and is valid for repos without CI or teams that want immediate feedback.

GitHub API calls are bounded by default. Shell-based REST calls use `REVIEWER_GITHUB_CONNECT_TIMEOUT` (default `10` seconds), `REVIEWER_GITHUB_MAX_TIME` (default `60` seconds), `REVIEWER_GITHUB_RETRIES` (default `2` retries for safe transient GET failures such as network errors, 5xx, 429, or rate-limit-like 403 responses), and `REVIEWER_GITHUB_RETRY_SLEEP` (default `1` second between attempts). The App-token helper (`get-installation-token.sh`) uses `REVIEWER_GITHUB_FETCH_TIMEOUT` (default `60` seconds) as its per-request `curl --max-time`. Failed GitHub API calls log the method, path, curl status, HTTP status, attempt count, and a short redacted response snippet so operators can distinguish auth/configuration errors from transient GitHub failures without leaking tokens. Check-run summaries include whether the fetched data is complete and whether the displayed rows were intentionally truncated; set `REVIEWER_CHECK_RUN_SUMMARY_LIMIT` (default `200`) to change the display limit without changing required-check gating.

Prompt assembly is also bounded by default. The diff degrades per file: `REVIEWER_DIFF_FILE_MAX_BYTES` (default `40000`) and `REVIEWER_DIFF_MAX_BYTES` (default `120000`) cap the per-file and total patch budgets, and a file over budget (or matching a built-in lockfile pattern or the target repo's `.gitattributes` `linguist-generated` patterns, or served without a text patch by GitHub) is replaced whole by an explicit `goobreview` omission marker — never cut mid-hunk. Omitted files remain readable in the PR-head snapshot. CI coverage context includes up to `REVIEWER_CI_WORKFLOW_FILE_LIMIT` workflow files (default `8`), capped by `REVIEWER_CI_WORKFLOW_FILE_MAX_BYTES` per file (default `12000`), and package scripts from up to `REVIEWER_CI_PACKAGE_SCRIPT_FILE_LIMIT` package manifests (default `12`). Prior review-thread context is capped by `REVIEWER_PRIOR_THREAD_SUMMARY_LIMIT` (default `12`) and `REVIEWER_PRIOR_THREAD_BODY_MAX_BYTES` (default `500`). After assembly, `REVIEWER_MAX_PROMPT_BYTES` (default `240000`) is a hard fail-closed budget checked before Gemini is invoked. Dry-run output is capped by `REVIEWER_MAX_ARTIFACT_BYTES` (default `1000000`) and marked when truncated.

Live posting requires real deployment config. `scripts/reviewer/reviewer.sh` refuses live mode unless `config/required-checks.json` exists, or `REVIEWER_REQUIRED_CHECKS_FILE` explicitly points at a valid file. Run `scripts/configure.sh` to create the local file from its `.example` sibling. Dry-run and prompt-rendering paths may still use the committed example so first-run setup can inspect behavior before launching.

Before enabling cron or another live daemon, run:

```bash
scripts/dry-run.sh
scripts/launch-check.sh
```

The first command writes the normal dry-run artifact and a sibling `.launch.json` file with runtime `AGENTS.md`, prompt, response, and stderr hashes. The second confirms that the latest launch metadata targets the current repo and reports the selected review trigger from the current required-check config.

Personalities are the exception to the `.example` pattern: `config/personalities/<name>.md` files are committed verbatim. Operators choose the posted style with `REVIEWER_POSTED_PERSONALITY=none|linus`; the legacy `REVIEWER_PERSONALITY_FILE` path remains as an escape hatch for old configs when `REVIEWER_POSTED_PERSONALITY` is unset. To try Linus in a dry run without editing config:

```bash
REVIEWER_POSTED_PERSONALITY=linus scripts/dry-run.sh 42
```

The engine prompt at `scripts/reviewer/review-prompt.md` only defines the parsed output contract (first line `APPROVE`/`REQUEST_CHANGES`/`COMMENT`, rest is the review body) — edit it only to change that contract; everything voice-related belongs in a personality file.

### Optional Runtime Switches

Env vars (set in `reviewer.env` or inline) beyond the required set:

- `REVIEWER_MAX_ATTEMPTS` — maximum non-skipped PRs to attempt in one tick. Defaults to `REVIEWER_MAX_PRS`. Reaching this limit logs `Reached REVIEWER_MAX_ATTEMPTS=...` and stops the tick.
- `REVIEWER_IGNORE_AGY_BACKOFF` — set `1` to run even while an Antigravity quota backoff (`agy_backoff_until`) is active. `dry-run.sh` sets this automatically.
- `REVIEWER_REQUIRED_CHECKS_JSON` + `REVIEWER_ALLOW_REQUIRED_CHECKS_OVERRIDE=1` — override the required-check gate from the environment for one-off runs; both must be set, so a stray env var cannot loosen a production gate.
- `REVIEWER_SYNC_REMOTE`, `REVIEWER_SYNC_BRANCH`, `REVIEWER_SYNC_LOG` — which remote/branch `sync-worktree.sh` tracks (default `origin`/`main`) and where it logs.
- `REVIEWER_ALLOW_STALE_CHECKOUT_ON_SYNC_FAILURE` — emergency/manual override; set to `1` only when you intentionally want a scheduler tick to run from the current checkout after sync fails. Default `0` fails closed.
- `REVIEWER_ONLY_PR` — restrict a run (including `merge-gate.sh`) to a single PR number.
- `REVIEWER_RUNTIME_STATE`, `REVIEWER_LOG_MAX_BYTES`, `REVIEWER_LOG_ROTATE_KEEP` — runtime dir and log rotation controls; see `config/reviewer.env.example`.
- `REVIEWER_AUTO_RESOLVE_BOT_THREADS` — default `0`. When set to `1`, a live review can resolve this bot's still-unresolved inline review threads after the review posts successfully, but only for valid handles (heading-derived slugs) explicitly listed under `Resolved Prior Threads`, and it posts a confirming reply before resolving each one. It never resolves human-created threads.

## Known Limits

- A cited location becomes an inline review comment only when it resolves to a changed line in GitHub's diff. Unanchorable findings remain in the top-level review body.
- There is no automatic line-matching dedup against existing threads. The reviewer is shown its own unresolved threads by handle and is expected to address each explicitly (resolve it, or leave it open) and not re-open one for the same finding. Suppressing by cited `path:line` was dropped because a drifted line could silently swallow a genuine new finding; the accepted failure is now the louder, safer one (a visible duplicate thread). Optional auto-resolution is handle-selected: it resolves only prompt-listed bot-owned thread handles that remain unresolved and resolvable at posting time, posting a confirming reply into each first. Handles are slugs derived from the thread heading, re-derived from live thread state each tick and only echoed back within the same prompt, so no name-to-id map is persisted.
- Very large diffs may exceed useful Gemini context.
- Prompt and dry-run artifact size limits are explicit runtime knobs; truncated context is marked in the prompt/artifact, and prompts that still exceed `REVIEWER_MAX_PROMPT_BYTES` fail before Gemini is called.
- PR-head source snapshots are provided as read-only context under `REVIEWER_RUNTIME_STATE/worktrees/<repo>/current`; Gemini itself runs from `REVIEWER_RUNTIME_STATE/gemini-runtime`, and the daemon does not run project code from the snapshot. Symlinks in PR-head snapshots are neutralized into metadata stubs, and any raw symlink that reaches prompt assembly or Gemini access is skipped/refused rather than dereferenced.
- Google-account Gemini CLI auth is still an interactive, user-bound setup step. Gemini CLI's documented non-interactive auth modes are Gemini API key or Vertex AI; those do not preserve personal Google AI Pro/Ultra subscription entitlement.
- The daemon does not inspect full CI logs; it gates on the configured required-check state.
- The daemon does not create follow-up issues automatically.
- The daemon trusts the App private key at `REVIEWER_APP_PRIVATE_KEY_PATH` and local Gemini auth. Keep the key file at mode `0600`, owned by the user that runs cron, and keep the VM account locked down.
- agy auto-loads context files from the reviewer account's home directory — `~/.gemini/GEMINI.md`, `~/GEMINI.md`, and `~/.gemini/AGENTS.md` (the auto-load surface confirmed by live testing on agy 1.0.10; `~/AGENTS.md` at the home root is not loaded) — into every review as trusted instructions, independent of the daemon's prompt and the PR-head snapshot. Anything placed there steers verdicts without touching a PR, so treat the home directory as part of the trust boundary. The daemon logs a `WARNING: home-directory agy context file ...` line (and records the files in the dry-run artifact's agy execution context) when any are present; remove them unless they are intentional. The daemon-supplied `AGENTS.md` in agy's isolated runtime dir is the only context file it should depend on.
- The checkout must stay clean. `sync-worktree.sh` refuses to update a dirty checkout; `run-once.sh` logs that failure and exits before reviewing unless `REVIEWER_ALLOW_STALE_CHECKOUT_ON_SYNC_FAILURE=1` is set deliberately.
- Each cron tick attempts at most `REVIEWER_MAX_ATTEMPTS` non-skipped PRs and posts at most `REVIEWER_MAX_PRS` reviews. Both default to one.
