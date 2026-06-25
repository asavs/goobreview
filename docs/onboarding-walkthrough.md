# Onboarding walkthrough (working doc)

Internal doc for walking the full setup end-to-end and noting friction at each
step. Not a user guide — for that see `docs/quickstart.md`. The goal here is
to have a single page that mirrors the actual sequence a new user goes through,
so we can audit it, mark pain points, and iterate.

Five phases:

1. **Provision** — VM exists, dependencies installed.
2. **Register** — GitHub App created, key on VM, App installed on target repo.
3. **Configure** - per-deployment config written (repo, App credentials, posted style, research consent, prompt policy).
4. **Tune** - iterate posted style, personality files, and prompt policy against real PRs without posting.
5. **Launch** — flip on the scheduler.

For each step: what the user types, what actually happens, what they need to
have already done, and a "friction" line to fill in.

---

## Phase 1 — Provision

**Surface:** Google Cloud Shell (or any machine with `gcloud` + a billed GCP
project).

**Prereqs:**
- A Google account.
- Willingness to create a GCP project + attach a billing account. (`e2-micro`
  in `us-central1` is on the always-free tier, so the steady-state cost is $0,
  but a billing account must exist.)

**Commands:**
```bash
git clone https://github.com/asavs/goobreview.git
cd goobreview
bash scripts/bootstrap-gcp.sh
```

Agent-driven:
```bash
bash scripts/bootstrap-gcp.sh --project PROJECT_ID --zone us-central1-a --vm-name goobreview-1 --yes
```

**What happens inside `bootstrap-gcp.sh`:**
1. Reads `gcloud config get-value project`; if unset or a Cloud Shell ephemeral
   project, offers to create a new GCP project + link billing inline.
2. Prompts: project ID, zone (`us-central1-a`), VM name (`goobreview-1`).
3. Enables `compute.googleapis.com` if not already.
4. `gcloud compute instances create` an `e2-micro` Ubuntu 24.04 VM.
5. Waits up to ~3min for SSH to come up.
6. SSHes in and pipes `scripts/setup-vm.sh` (fetched from
   `raw.githubusercontent.com/<this-fork>/main/...`) into `bash`.
7. `setup-vm.sh` installs: `git jq curl wget openssl`, Antigravity CLI (`agy`),
   2GB swapfile, clones the repo into `/opt/goobreview/example`, creates state
   dir at `/var/lib/goobreview/example`.

**State after Phase 1:**
- VM running, repo at `/opt/goobreview/example`, state dir at
  `/var/lib/goobreview/example`, dependencies installed.
- `.goobreview-cloud-shell.env` written locally with VM name + zone for the
  next step to pick up.

**Friction notes:**
- _(fill in as you walk through)_

---

## Phase 2 — Register

**Surface:** Cloud Shell → browser → upload .pem back to Cloud Shell → VM.

**Prereqs:**
- Phase 1 complete (VM exists; `.goobreview-cloud-shell.env` has VM name + zone).
- Browser with Cloud Shell's Web Preview reachable.

**Commands (Cloud Shell):**
```bash
bash scripts/register-app.sh
```

**What happens:**
1. Validates the VM exists.
2. Spins up a Node server on an open local port unless one was supplied.
3. User clicks Cloud Shell's **Web Preview** and chooses the printed port. A page loads with two
   steps:
   - **a.** Click through to a pre-filled GitHub App-creation form
     (`github.com/settings/apps/new?...` with fields from `config/app-manifest.json`).
     User clicks "Create GitHub App", then on the App page generates and
     downloads a private key.
   - **b.** Back on the local page, upload the `.pem` and paste the App ID.
4. Server `scp`s the `.pem` to `${REVIEWER_APP_PRIVATE_KEY_PATH}` on the VM
   (default `/var/lib/goobreview/example/app-key.pem`, mode 0600).
5. Server SSHes to the VM and pre-populates `REVIEWER_APP_ID` in
   `/opt/goobreview/example/config/reviewer.env` (creating it from the example
   if needed).
6. Prints an install URL: `https://github.com/apps/<slug>/installations/new`.

**Manual step in between:**
7. User opens the install URL, installs the App on the target repo
   (single-repo or all-repos in scope).

**State after Phase 2:**
- GitHub App exists, key on VM, App ID written to `reviewer.env`, App installed
  on target repo.

**Friction notes:**
- Two-surface flow (Cloud Shell ↔ browser ↔ GitHub) — error recovery is hard
  if anything goes wrong mid-flight.
- _(fill in as you walk through)_

---

## Phase 3 — Configure

**Surface:** SSH session to the VM.

**Prereqs:**
- Phases 1 + 2 complete.
- App installed on target repo (Phase 2 step 7).

**Commands Antigravity CLI should run to reach the VM:**
```bash
gcloud compute ssh goobreview-1 --zone=us-central1-a   # from Cloud Shell
cd /opt/goobreview/example
agy                     # first-time Google OAuth
scripts/configure.sh
```

The user should only take over for the `agy` browser sign-in, then return
control to the setup agent for `scripts/configure.sh`.

**What happens inside `configure.sh`:**
1. Preflight: `openssl`, `jq`, `agy` on PATH; Antigravity auth state exists; copies
   `reviewer.env.example` → `reviewer.env` if missing.
2. **REVIEWER_REPO** prompt (target `owner/repo`).
3. **App credentials**:
   - App ID (pre-filled from Phase 2).
   - Private key path (default `$REVIEWER_STATE/app-key.pem`; alternatively
     `paste` to paste PEM contents directly).
   - Installation ID auto-discovered by calling
     `scripts/reviewer/get-installation-token.sh discover <owner/repo>`.
4. Offers to open `reviewer.env` in `$EDITOR` for other settings.
5. **Posted style picker** - prompts for `none` or `linus` and writes
   `REVIEWER_POSTED_PERSONALITY`.
6. **Research consent** - prompts whether public-repo paired artifacts may be
   retained and writes `REVIEWER_RESEARCH_CONSENT`.
7. **Required-checks** - copies `required-checks.example.json` → `required-checks.json`
   if missing, offers to edit.
8. Prints "next steps" pointing at `dry-run.sh` and `enable-cron.sh`.

**State after Phase 3:**
- `config/reviewer.env` and `config/required-checks.json` populated.
- Reviewer is fully configured but not yet running on a schedule.

**Friction notes:**
- Re-running to change one thing (e.g. posted style) walks through everything.
  Pre-filled defaults mean it's mostly "press enter 5 times", but it's the kind
  of papercut that makes you not want to iterate.
- Posted style picker should make clear that `none` maps to control and `linus`
  maps to the blunt gallery file.
- Personality *content* lives in `config/personalities/<file>.md`; nothing in
  the configure flow tells you that's the file to edit if you want to change
  the reviewer's voice.
- _(fill in as you walk through)_

---

## Phase 4 — Tune

**Surface:** SSH session to the VM. Loop.

**Prereqs:** Phase 3 complete.

**Commands:**
```bash
# Dry-run against a specific PR (no posting):
scripts/dry-run.sh 123          # writes $REVIEWER_STATE/dry-pr-123.txt

# Or dry-run against the oldest unseen PR:
scripts/dry-run.sh              # writes $REVIEWER_STATE/dry-run-<timestamp>.txt

# Inspect the artifact:
cat /var/lib/goobreview/example/dry-pr-123.txt
```

**What's in the artifact:**
- Repo, PR number, head SHA, parsed review event (APPROVE / REQUEST_CHANGES /
  COMMENT), timestamp.
- The full prompt payload sent to `agy`.
- `agy`'s full response.

**To iterate:**
- **Change which review style is posted:** edit `REVIEWER_POSTED_PERSONALITY`
  in `config/reviewer.env`, or re-run `configure.sh`.
- **Change whether paired artifacts are retained:** edit
  `REVIEWER_RESEARCH_CONSENT` in `config/reviewer.env`. Consent only affects
  public-repo artifact retention; it never changes which review posts.
- **Change what the personality says:** edit `config/personalities/<file>.md`
  directly. Re-run `dry-run.sh`.
- **Add a new personality:** drop a new `.md` in `config/personalities/` and
  update the product mapping before exposing it as a supported posted style.
- **Change the blinding policy** (author username, PR description, commit
  subjects): edit the `REVIEWER_INCLUDE_*` flags in `config/reviewer.env`.
  The prompt composition itself is fixed; forks edit
  `scripts/reviewer/lib/prompt.sh` to change the payload shape.
- **Render the prompt without invoking `agy`** (just see what would be sent):
  ```bash
  REVIEWER_RENDER_PROMPT_ONLY=1 REVIEWER_ONLY_PR=123 scripts/reviewer/reviewer.sh
  ```

**What's intentionally not happening in this phase:**
- Nothing is posted to GitHub.
- The bot doesn't see any other PRs (limit to one via `REVIEWER_MAX_PRS=1`,
  which `dry-run.sh` sets).
- CI gating is bypassed (`REVIEWER_DRY_RUN_BYPASS_CI=1`).

**State after Phase 4:**
- You have at least one dry-run artifact you're happy with.
- `config/personalities/<file>.md` reflects the voice you want.
- The `REVIEWER_INCLUDE_*` flags in `config/reviewer.env` reflect the
  blinding policy you want.

**Friction notes:**
- Dedicated `scripts/tune.sh` now wraps the loop of editing the active
  personality/blinding policy and running another dry run.
- No way to diff two dry-run artifacts to see "did my edit help?"
- The split between posted style, consent, and personality file content is now
  explicit, but `scripts/status.sh` should keep reporting the active state.
- _(fill in as you walk through)_

---

## Phase 5 — Launch

**Surface:** SSH session to the VM.

**Prereqs:** Phase 4 complete and you're happy with the dry-run output.

**Commands:**
```bash
scripts/enable-cron.sh
```

**What happens:**
1. Validates: `crontab` available, `reviewer.env` present, `run-once.sh`
   executable, App ID + installation ID + key path valid.
2. Refuses to add a duplicate (idempotent).
3. Installs a once-per-minute crontab entry that runs
   `scripts/reviewer/run-once.sh` and appends to `$REVIEWER_STATE/cron.log`.
4. Prints how to tail the log and how to pause.

**Each tick (run-once.sh):**
1. `sync-worktree.sh` — `git fetch origin main`, `git checkout --detach <sha>`
   if HEAD differs. **Refuses to sync a dirty checkout** — any untracked or
   modified files block all future syncs.
2. `reviewer.sh` — acquires `flock`, mints an App installation token, lists
   open non-draft PRs, skips ones already reviewed by `<bot>[bot]` on the
   current head SHA, gates on CI, posts a review.

**State after Phase 5:**
- Cron fires every minute.
- Every push to `main` in this repo propagates to the VM within ~60s.
- Every new PR or new commit on an existing PR triggers a review within ~60s
  of CI going green.

**Pause / stop:**
- `crontab -e`, comment out the line marked
  `# GoobReview reviewer (managed by scripts/enable-cron.sh)`.

**Friction notes:**
- Two scheduler paths exist (cron + systemd timer in `deploy/systemd/`) and
  the systemd one requires manual unit-file editing — neither is obviously
  "the" recommended path.
- _(fill in as you walk through)_

---

## Cross-cutting friction (things that span phases)

- **Surface ping-pong:** Cloud Shell → browser → Cloud Shell → GitHub UI →
  SSH. Five surface switches before you've configured anything.
- **No undo / reset.** If you want to start over, you mostly have to figure
  out which files to delete by reading scripts.
- **Two prompt surfaces, one owned by the user (`personalities/*.md`), one
  owned by the engine (`scripts/reviewer/review-prompt.md`).** Easy to forget
  which controls what.

---

## Where to make changes (file map for iterators)

| Want to change... | Edit... |
| --- | --- |
| What the reviewer "sounds like" | `config/personalities/<file>.md` |
| Which review style is posted | `REVIEWER_POSTED_PERSONALITY` in `config/reviewer.env` |
| Whether paired artifacts are retained | `REVIEWER_RESEARCH_CONSENT` in `config/reviewer.env` |
| Blinding policy (author, description, commit subjects) | `REVIEWER_INCLUDE_*` in `config/reviewer.env` |
| The prompt payload shape itself | `scripts/reviewer/lib/prompt.sh` (fork-owned) |
| The invariant review-event output contract | `scripts/reviewer/review-prompt.md` (rarely) |
| Which CI checks are required before reviewing | `config/required-checks.json` |
| Setup interactive flow | `scripts/configure.sh` |
| Scheduler installation | `scripts/enable-cron.sh` or `deploy/systemd/*.example` |
| Sync behavior | `scripts/reviewer/sync-worktree.sh` |
| The Antigravity CLI invocation itself | `scripts/reviewer/lib/agy.sh` |
