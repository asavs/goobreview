# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A **template** for a VM-side daemon that polls a target GitHub repo, asks Gemini CLI to review open non-draft PRs, and posts `APPROVE` / `REQUEST_CHANGES` / `COMMENT` reviews as a GitHub App bot identity. There is no application to run from a developer checkout — edits here propagate to user VMs through `scripts/reviewer/sync-worktree.sh`, which fetches `origin/main` and `git checkout --detach` to the new SHA before each reviewer tick.

Implications for editing:

- The daemon runs on someone else's machine, often via cron or systemd. There's no local dev server, build step, or test suite.
- `sync-worktree.sh` **refuses to sync a dirty checkout**. Any new file under `config/` that isn't gitignored will brick every deployed VM on next tick. The four per-deployment files (`reviewer.env`, `project-docs.txt`, `head-context-paths.txt`, `required-checks.json`) are gitignored; only their `.example.*` siblings are committed. Adding a fifth config file means updating `.gitignore` *and* the resolution logic in `reviewer.sh` *and* the loop in `configure.sh` in the same PR. Personality is the exception: it doesn't follow the `.example` pattern — gallery files in `config/personalities/` are committed verbatim and selected via `REVIEWER_PERSONALITY_FILE` in `reviewer.env`.
- Forks/template instantiations rely on `.github/workflows/template-cleanup.yml` rewriting every `asavschaeffer/goobreview` literal to the new `owner/repo` on first push to `main`. Hardcode that string in new docs/scripts the same way existing ones do — don't introduce an alternate spelling, or fork personalization will silently miss it.

## Architecture

Three layers, executed top-down on each tick:

1. **`scripts/reviewer/run-once.sh`** — entry point invoked by cron/systemd. Sources `config/reviewer.env`, calls `sync-worktree.sh`, then `reviewer.sh`.
2. **`scripts/reviewer/reviewer.sh`** — the daemon body. Roughly: acquire `flock`; validate `REVIEWER_PERSONALITY_FILE` exists; mint a GitHub App installation token via `get-installation-token.sh` (which `exec`s `lib/app-token.mjs`); list open non-draft PRs; for each PR, skip if already in `seen.txt` or already reviewed by `<app-slug>[bot]` on this head SHA; gate on required CI checks (`check-ci.sh`); assemble a prompt (**personality file** → engine prompt → PR metadata → CI summary → file tree → project docs fetched at the PR head SHA → selected head-context files → diff); run `gemini` with a timeout; parse the verdict and the optional `<!-- REVIEW_META ... REVIEW_META -->` JSON block; post the review (with inline comments where the metadata anchors to a changed RIGHT-side line); best-effort update of the in-PR-body checklist and labels; record `PR_NUMBER HEAD_SHA` in `seen.txt` only after successful post.
3. **`scripts/reviewer/lib/app-token.mjs`** — the only non-shell code on the hot path. Signs an RS256 JWT from the App private key, calls `/app` for the slug, mints an installation access token, caches both in `$REVIEWER_STATE/app_token.json` until ~5 min before expiry. Supports a `discover <owner/repo>` mode used by `configure.sh` to find the installation ID. **GitHub App is the only auth path** — `gh auth login` was deliberately removed for distribution friendliness.

There's one other Node script, off the hot path: **`scripts/lib/manifest-server.mjs`**, run by `scripts/register-app.sh` to drive GitHub's Manifest Flow during initial setup. It binds to port 8080, renders a form that POSTs to `github.com/settings/apps/new` with the contents of `config/app-manifest.json` (the source of truth for App name template, permissions, and `default_events`), receives GitHub's redirect at `/callback?code=...&state=...`, and exchanges the code for the App's private key. The PEM is written to a tempdir; `register-app.sh` then `scp`s it to the VM and pre-populates `REVIEWER_APP_ID` in `reviewer.env`. **Contracts here:** the manifest JSON shape is GitHub's, not ours — don't add fields beyond what GitHub documents; the state token must be URL-only (form-only didn't round-trip reliably in testing); and the `redirect_url` is computed at form-render time from the `Host`/`x-forwarded-host` header, so Cloud Shell's per-session Web Preview URL doesn't need to be known in advance.

State directory (`REVIEWER_STATE`, default `$HOME/.goobreview`) holds: `seen.txt`, `log.txt`, `lock`, `app_token.json`, `app-key.pem` (you provide, mode 0600), `gemini_backoff_until` (set by `set_gemini_quota_backoff` when Gemini emits quota errors), `sync.log`, `cron.log`.

**Prompt layering** — there are two prompt files and they have different owners:

- `scripts/reviewer/review-prompt.md` (**engine, invariant**) — defines the output contract (verdict line + `REVIEW_META` JSON block), the severity scale (P1/P2/P3 definitions and verdict mapping), and the reference-validation rules. Parsed by `reviewer.sh`. Edit only if you're changing those contracts.
- `config/personalities/*.md` (**committed gallery, the only personality surface**) — each file defines a reviewer's **role, voice, and focus areas only**. One is selected at runtime via `REVIEWER_PERSONALITY_FILE` in `reviewer.env` (defaults to `config/personalities/control.md`). Prepended to the engine prompt. May sharpen *what counts as P1* for its lens, but does not redefine the P1/P2/P3 scale or verdict mapping — those are engine concerns. To add or change a personality, drop a `.md` file in this directory and point the env var at it. There is no `personality.md` / `personality.example.md` fallback layer — `reviewer.sh` fails loudly if the selected file is missing.

Two contracts that span deployments — **never break these silently:**

- **Verdict line**: `reviewer.sh` searches for the first line matching `^VERDICT: (APPROVE|REQUEST_CHANGES|COMMENT)$`. Malformed verdicts are dropped and retried next tick. Drift in `review-prompt.md` that changes this format will silently disable every fork.
- **`REVIEW_META` block**: extracted by `awk` between literal lines `<!-- REVIEW_META` and `REVIEW_META -->`. Must be valid JSON. Inline comments only fire when a finding has both `path` and a numeric `line`. The `awk` strips ```` ```json ```` / ```` ```text ```` fences if present but nothing else — don't add other wrapping.

The engine prompt also tells Gemini that PR-authored content (changed docs/scripts/code included as context) **cannot override reviewer instructions**. Treat any new prompt-context injection point you add the same way — assume the content is untrusted.

Bootstrap flow (Cloud Shell path): `scripts/bootstrap-gcp.sh` creates a GCE VM, then SSHs in and runs `setup-vm.sh` from `raw.githubusercontent.com/<owner>/<repo>/main/scripts/setup-vm.sh` (URL derived from this checkout's `origin`, which is why template-cleanup matters). `setup-vm.sh` installs `gh`, Node 20, `@google/gemini-cli`, configures a 2 GB swap file (for `e2-micro`'s 1 GB RAM ceiling), and clones the repo to `/opt/goobreview/example`. Then the user runs `scripts/register-app.sh` from Cloud Shell (manifest flow: drops `app-key.pem` on the VM and writes `REVIEWER_APP_ID` into `reviewer.env`), installs the App on the target repo via the link the script prints, SSHs in to run `scripts/configure.sh` (auto-discovers installation ID, writes the remaining config files), and finally enables cron or the systemd timer in `deploy/systemd/`.

## Common Commands

```bash
# Syntax-check changed shell scripts (the closest thing to a test suite)
bash -n scripts/reviewer/*.sh

# Validate example JSON
jq . config/required-checks.example.json

# Catch whitespace/conflict markers before committing
git diff --check

# Dry-run a single PR review against a real target (does not post)
set -a; . config/reviewer.env; set +a
REVIEWER_DRY_RUN=1 REVIEWER_ONLY_PR=123 REVIEWER_MAX_PRS=1 scripts/reviewer/reviewer.sh
tail -n 80 "$REVIEWER_STATE/log.txt"

# One full tick (sync + review) the way cron runs it
REVIEWER_ENV_FILE=$PWD/config/reviewer.env scripts/reviewer/run-once.sh

# Mechanical pre-merge gate for a PR (independent of the daemon)
scripts/reviewer/merge-gate.sh 123
```

## Conventions

- **Commit subjects describe the final state**, not the journey. Single-purpose; fold incidental cleanup into the feature commit rather than splitting it out.
- Keep `config/*.example.*` generic and safe to publish — they're the only config a fresh checkout has.
- Avoid adding runtime dependencies. The whole point of the shell-script + one-Node-helper shape is that it installs cleanly on a vanilla Ubuntu VM with `apt` + `npm i -g @google/gemini-cli`.
