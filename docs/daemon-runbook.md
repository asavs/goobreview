# Daemon Runbook

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

For a more durable VM setup, use the example unit files under `deploy/systemd/`:

```text
deploy/systemd/goobreview.service.example
deploy/systemd/goobreview.timer.example
```

See [systemd-timer.md](systemd-timer.md) for install, logging, and multi-reviewer setup.

## What The Reviewer Does

1. Acquires a non-blocking `flock`.
2. Lists open non-draft PRs in `REVIEWER_REPO`.
3. Skips PRs authored by the authenticated `gh` user unless overridden.
4. Reviews each `PR_NUMBER HEAD_SHA` once.
5. Checks whether the authenticated user already reviewed the same head commit.
6. Applies the required-check gate.
7. Builds a prompt from base instructions, configured project docs, PR metadata, check summaries, file tree, selected file contents, and diff.
8. Runs Gemini CLI headlessly.
9. Parses the verdict and optional metadata.
10. Posts a GitHub review and best-effort inline comments.
11. Updates the managed checklist block in the PR body.
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

The script still checks GitHub for an existing same-user review on the same head commit, so deleting local state should not duplicate reviews that posted successfully.

Run a pre-merge mechanical gate:

```bash
set -a
. config/reviewer.env
set +a
scripts/reviewer/merge-gate.sh 123
```

## Known Limits

- Inline comments are best-effort. Invalid anchors fall back to a top-level review body.
- Very large diffs may exceed useful Gemini context.
- The daemon does not inspect full CI logs; it sees check summaries and the configured required-check state.
- The daemon does not create follow-up issues automatically.
- The daemon trusts local `gh` and Gemini auth. Keep the VM account locked down.
- The checkout must stay clean. `sync-worktree.sh` refuses to run from a dirty checkout.
- Each cron tick posts at most `REVIEWER_MAX_PRS` reviews, defaulting to one.
