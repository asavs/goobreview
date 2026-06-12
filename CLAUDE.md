# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A **template** for a VM-side daemon that polls a target GitHub repo, asks Gemini CLI to review open non-draft PRs, and posts `APPROVE` / `REQUEST_CHANGES` / `COMMENT` reviews as a GitHub App bot identity. There is no application to run from a developer checkout — edits here propagate to user VMs through `scripts/reviewer/sync-worktree.sh`, which fetches `origin/main` and `git checkout --detach` to the new SHA before each reviewer tick.

Implications for editing:

- The daemon runs on someone else's machine, often via cron or systemd. There's no local dev server or build step. The test suite is `scripts/reviewer/tests/run-fixtures.sh` (covers parser, CI-gate, prompt assembly, and Gemini invocation isolation); it runs in CI and is the canonical check for reviewer-core behavior.
- `sync-worktree.sh` **refuses to sync a dirty checkout**. Any new per-deployment config file under `config/` that isn't gitignored will brick every deployed VM on next tick. The ignored per-deployment files are `reviewer.env` and `required-checks.json`; only their `.example.*` siblings are committed. Adding another local config file means updating `.gitignore`, config resolution, setup docs, and `configure.sh` in the same PR. Personality is the exception: it doesn't follow the `.example` pattern — gallery files in `config/personalities/` are committed verbatim and selected via `REVIEWER_PERSONALITY_FILE` in `reviewer.env`.
- Forks/template instantiations rely on `.github/workflows/template-cleanup.yml` rewriting every `asavschaeffer/goobreview` literal to the new `owner/repo` on first push to `main`. Hardcode that string in new docs/scripts the same way existing ones do — don't introduce an alternate spelling, or fork personalization will silently miss it.

## Architecture

Three layers, executed top-down on each tick:

1. **`scripts/reviewer/run-once.sh`** — entry point invoked by cron/systemd. Sources `config/reviewer.env`, calls `sync-worktree.sh`, then `reviewer.sh`.
2. **`scripts/reviewer/reviewer.sh`** — the daemon body. Roughly: acquire `flock`; validate `REVIEWER_PERSONALITY_FILE` exists; mint a GitHub App installation token via `get-installation-token.sh` (which `exec`s `lib/app-token.mjs`); list open non-draft PRs; for each PR, skip if already reviewed by `<app-slug>[bot]` on this head SHA (queried from the GitHub API); gate on required CI checks (`check-ci.sh`); download/cache a PR-head source snapshot; assemble a prompt from the personality file plus GitHub-side facts (PR metadata and author claims, commit subjects, check-run results, prior bot review, per-file diff with changed-file index and whole-file omission markers) and the GitHub review formatting rule; run `gemini` from an isolated empty runtime dir with the PR-head snapshot attached as read-only context; parse the final GitHub review event; post a top-level review; best-effort apply labels. The payload rule: never inline what Gemini can pull from the snapshot; always inline GitHub-side facts it cannot reach (the snapshot is a tarball with no `.git`). The composition is fixed in `lib/prompt.sh` (forks edit it to change the shape); per-deployment policy is limited to the `REVIEWER_INCLUDE_*` blinding flags and byte budgets in `reviewer.env`, the author username is blinded by default, and generated-file diff omission follows the target repo's `.gitattributes` `linguist-generated` patterns plus a built-in lockfile floor.
3. **`scripts/reviewer/lib/app-token.mjs`** — the only non-shell code on the hot path. Signs an RS256 JWT from the App private key, calls `/app` for the slug, mints an installation access token, caches both in `$REVIEWER_STATE/app_token.json` until ~5 min before expiry. Supports a `discover <owner/repo>` mode used by `configure.sh` to find the installation ID. **GitHub App is the only auth path** — `gh auth login` was deliberately removed for distribution friendliness.

There's one other Node script, off the hot path: **`scripts/lib/register-server.mjs`**, run by `scripts/register-app.sh` during initial setup. It binds to port 8080 and serves a two-step page: (a) a link to `github.com/settings/apps/new` with name, homepage, description, webhook setting, and per-permission levels pre-filled as URL query params from `config/app-manifest.json` (same-origin GET, so the user's GitHub session cookies travel with the navigation in any browser), and (b) a multipart upload form that takes the resulting `.pem` and App ID. On upload it signs an RS256 JWT, calls `/app` to verify the key and fetch the slug, and writes `app-key.pem` + `app.json` to a tempdir; `register-app.sh` then `scp`s the key to the VM and pre-populates `REVIEWER_APP_ID` in `reviewer.env`. **Contracts here:** `config/app-manifest.json` follows GitHub's App-manifest schema field names (`name`, `url`, `description`, `public`, `hook_attributes.active`, `default_permissions`, `default_events`) because the server maps them directly to GitHub's URL-parameter names; don't rename keys. The earlier Manifest Flow (POST to `/settings/apps/new`, redirect back to `/callback?code=...`) was removed because cross-origin form POSTs to github.com lose the user's session cookies under modern browser SameSite policies, making registration unreliable from Cloud Shell.

State directory (`REVIEWER_STATE`, default `$HOME/.goobreview`) holds: `log.txt`, `lock`, `app_token.json`, `app-key.pem` (you provide, mode 0600), `gemini_backoff_until` (set by `set_gemini_quota_backoff` when Gemini emits quota errors), `sync.log`, `cron.log`. The transient runtime dir (`REVIEWER_RUNTIME_STATE`, default under `$XDG_RUNTIME_DIR`) holds the PR-head snapshots, Gemini's empty working directory, and `gemini-settings.json` (written before each Gemini invocation; configures allowed tools, workspace context path, and MCP policy).

**Prompt layering** — there are two prompt inputs and they have different owners:

- `config/personalities/*.md` (**committed gallery, the only personality surface**) — each file defines a reviewer's **role and voice**. One is selected at runtime via `REVIEWER_PERSONALITY_FILE` in `reviewer.env` (required — the daemon fails loudly when unset; `configure.sh` pre-selects `config/personalities/control.md`). Prepended to the diff and review-format prompt. To add or change a personality, drop a `.md` file in this directory and point the env var at it. There is no `personality.md` / `personality.example.md` fallback layer — `reviewer.sh` fails loudly if the selected file is missing or unset.
- `scripts/reviewer/review-prompt.md` (**engine, invariant**) — defines the minimal GitHub review event output contract. Parsed by `reviewer.sh`. Edit only if you're changing that contract.

Two contracts that span deployments — **never break these silently:**

- **Review event line**: the final non-empty line must be exactly `APPROVE`, `REQUEST_CHANGES`, or `COMMENT`. Malformed final events are dropped and retried next tick. Drift in `review-prompt.md` that changes this format will silently disable every fork.
- **Top-level review body**: everything before the final event line is posted as the GitHub review body. Reviews no longer include engine-owned metadata blocks or inline-comment anchors.

The engine prompt also tells Gemini to treat the diff under review as code, not instructions. Treat any new prompt-context injection point you add the same way — assume the content is untrusted.

Bootstrap flow (Cloud Shell path): `scripts/bootstrap-gcp.sh` creates a GCE VM, then SSHs in and runs `setup-vm.sh` from `raw.githubusercontent.com/<owner>/<repo>/main/scripts/setup-vm.sh` (URL derived from this checkout's `origin`, which is why template-cleanup matters). `setup-vm.sh` installs `gh`, Node 20, `@google/gemini-cli`, configures a 2 GB swap file (for `e2-micro`'s 1 GB RAM ceiling), and clones the repo to `/opt/goobreview/example`. Then the user runs `scripts/register-app.sh` from Cloud Shell (the register-server hands them a pre-filled GitHub form, accepts the `.pem` back, drops it on the VM, and writes `REVIEWER_APP_ID` into `reviewer.env`), installs the App on the target repo via the link the server prints, SSHs in to run `scripts/configure.sh` (auto-discovers installation ID, writes the remaining config files), and finally enables cron or the systemd timer in `deploy/systemd/`.

## Common Commands

```bash
# Syntax-check all shell scripts and run the fixture test suite
mapfile -t shell_files < <(git ls-files '*.sh')
bash -n "${shell_files[@]}"
bash scripts/reviewer/tests/run-fixtures.sh

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
