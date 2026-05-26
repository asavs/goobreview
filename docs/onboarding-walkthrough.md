# Onboarding walkthrough (working doc)

Internal doc for walking the full setup end-to-end and noting friction at each
step. Not a user guide — for that see `docs/quickstart.md`. The goal here is
to have a single page that mirrors the actual sequence a new user goes through,
so we can audit it, mark pain points, and iterate.

Five phases:

1. **Provision** — VM exists, dependencies installed.
2. **Register** — GitHub App created, key on VM, App installed on target repo.
3. **Configure** — per-deployment config written (repo, App credentials, personality, prompt shape).
4. **Tune** — iterate personality + prompt against real PRs without posting.
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
git clone https://github.com/asavschaeffer/goobreview.git
cd goobreview
bash scripts/bootstrap-gcp.sh
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
7. `setup-vm.sh` installs: `git jq curl wget`, Node 20, `gh`, `@google/gemini-cli`,
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
2. Spins up a Node server on port 8080.
3. User clicks Cloud Shell's **Web Preview → port 8080**. A page loads with two
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

**Commands (on the VM):**
```bash
gcloud compute ssh goobreview-1 --zone=us-central1-a   # from Cloud Shell
cd /opt/goobreview/example
gemini                  # first-time Google OAuth; trust this folder; /quit
scripts/configure.sh
```

**What happens inside `configure.sh`:**
1. Preflight: `node`, `jq`, `gemini` on PATH; `~/.gemini` exists; copies
   `reviewer.env.example` → `reviewer.env` if missing.
2. **REVIEWER_REPO** prompt (target `owner/repo`).
3. **App credentials**:
   - App ID (pre-filled from Phase 2).
   - Private key path (default `$REVIEWER_STATE/app-key.pem`; alternatively
     `paste` to paste PEM contents directly).
   - Installation ID auto-discovered by calling
     `scripts/reviewer/get-installation-token.sh discover <owner/repo>`.
4. Offers to open `reviewer.env` in `$EDITOR` for other settings.
5. **Personality picker** — lists `config/personalities/*.md` files by basename
   (currently `control`, `linus`), prompts for index. Writes selection to
   `REVIEWER_PERSONALITY_FILE`.
6. **Required-checks** — copies `required-checks.example.json` → `required-checks.json`
   if missing, offers to edit.
7. **Prompt payload profile** — picks one of `lean | minimal | guided | full | custom`,
   applies it to `config/prompt-payload.json` (which controls which prompt segments
   are included). Offers to edit.
8. **Labels** — offers to create helper labels (`agent-reviewed`,
   `agent-requested-changes`, `needs-human-decision`) on the target repo.
9. Prints "next steps" pointing at `dry-run.sh` and `enable-cron.sh`.

**State after Phase 3:**
- `config/reviewer.env`, `config/required-checks.json`, `config/prompt-payload.json`
  all populated.
- Helper labels exist on target repo (if opted in).
- Reviewer is fully configured but not yet running on a schedule.

**Friction notes:**
- Re-running to change one thing (e.g. personality) walks through everything.
  Pre-filled defaults mean it's mostly "press enter 5 times", but it's the kind
  of papercut that makes you not want to iterate.
- Personality picker shows file basenames only — no description of what
  `control` vs `linus` produces.
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
- The full prompt payload sent to Gemini.
- Gemini's full response.

**To iterate:**
- **Change which personality is used:** edit `REVIEWER_PERSONALITY_FILE` in
  `config/reviewer.env`, or re-run `configure.sh`.
- **Change what the personality says:** edit `config/personalities/<file>.md`
  directly. Re-run `dry-run.sh`.
- **Add a new personality:** drop a new `.md` in `config/personalities/`,
  then point `REVIEWER_PERSONALITY_FILE` at it.
- **Change which segments go into the prompt** (CI status, file tree, diff,
  etc.): edit `config/prompt-payload.json` directly, or re-run `configure.sh`
  and pick a different profile.
- **Render the prompt without invoking Gemini** (just see what would be sent):
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
- `config/prompt-payload.json` reflects the prompt shape you want.

**Friction notes:**
- No dedicated "tune" command — the loop is a mix of `dry-run.sh`, editing
  markdown files, and occasionally re-running `configure.sh`.
- No way to diff two dry-run artifacts to see "did my edit help?"
- The split between "what the personality says" (markdown file) and "which
  personality is selected" (env var) means changing voice requires editing
  two surfaces depending on what kind of change you want.
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
- No guardrail: `enable-cron.sh` will happily install cron even if no dry-run
  has ever been written. If your personality is still pointing at the default,
  you'll start blasting reviews at every open PR within 60s.
- Two scheduler paths exist (cron + systemd timer in `deploy/systemd/`) and
  the systemd one requires manual unit-file editing — neither is obviously
  "the" recommended path.
- _(fill in as you walk through)_

---

## Cross-cutting friction (things that span phases)

- **Surface ping-pong:** Cloud Shell → browser → Cloud Shell → GitHub UI →
  SSH. Five surface switches before you've configured anything.
- **No "what's my current state?" command.** To know which phase you're in,
  you have to check: does the VM exist? does the App exist? is it installed?
  does `reviewer.env` have all values? has a dry-run ever been written? is
  cron installed? — six separate checks.
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
| Which personality is active | `REVIEWER_PERSONALITY_FILE` in `config/reviewer.env` |
| Which prompt segments are included | `config/prompt-payload.json` |
| The invariant review-event output contract | `scripts/reviewer/review-prompt.md` (rarely) |
| Which CI checks are required before reviewing | `config/required-checks.json` |
| Setup interactive flow | `scripts/configure.sh` |
| Scheduler installation | `scripts/enable-cron.sh` or `deploy/systemd/*.example` |
| Sync behavior | `scripts/reviewer/sync-worktree.sh` |
| The Gemini invocation itself | `scripts/reviewer/lib/gemini.sh` |

---

## Design direction under consideration: Gemini-driven setup

The long-term north star is that a user clicks an "Open in Cloud Shell" badge
from the README, types `gemini`, says "set this up for me", and Gemini drives
~70% of the setup while the user does the three browser-only steps. This
section captures what that would look like and what blocks it.

### What Gemini in Cloud Shell can and can't do

**Can:**
- Run `gcloud` commands — Cloud Shell's gcloud is pre-authed.
- Read repo state, edit config files, `scp` things, SSH to the VM.
- Run `configure.sh` / `dry-run.sh` / `enable-cron.sh` *if those scripts accept
  flags instead of requiring interactive prompts*.
- Read the dry-run artifact and tell the user "the bot would say X on PR Y —
  ship it?"

**Can't (these stay manual no matter what):**
1. **Google OAuth for Gemini-CLI on the VM.** The VM's `gemini` binary needs
   the user to visit a Google auth URL in a browser. Cloud Shell's Gemini can't
   sign in on the user's behalf for the VM-side install. (Cloud Shell's own
   Gemini is fine — it's authed via the session.)
2. **Filling out the GitHub App creation form.** The pre-filled link still
   requires a human to click "Create", "Generate private key", download the
   `.pem`.
3. **Installing the App on the target repo.** Browser-only.

### What needs to change in script structure

Today every script is interactive-only — `ops_prompt` blocks on stdin. Gemini
can't drive that well (heredocs and `expect` are fragile; it'll get them wrong).

**The structural change is inner/outer:**

- **Inner layer:** pure flag-driven, no stdin reads. Fails loud with a
  structured error if a required value is missing. Example:
  ```
  configure.sh --repo owner/repo --app-id 12345 \
               --key-path /var/lib/goobreview/example/app-key.pem \
               --personality config/personalities/linus.md \
               --payload-profile lean \
               --create-labels
  ```
- **Outer layer:** thin interactive wrapper that prompts for missing values,
  then calls the inner layer. Humans-without-Gemini still use this.

Gemini drives the inner layer with flags. It never fights interactive prompts.

### Sensors and orchestrators: the division of labor

A key insight: a lot of what would *seem* to want Gemini's intelligence is
actually programmable. The current `bootstrap-gcp.sh` already contains all the
state-checking logic (`list_open_billing_accounts`, `project_billing_enabled`,
`project_exists`) — buried inside a 400-line interactive script.

The cleaner architecture is **small focused diagnostic scripts as sensors, with
Gemini as the orchestrator**:

**Sensors** — pure programmatic state reads, deterministic, structured output,
no LLM. Each ~50-150 lines, fixture-testable, two output modes (`--report` for
machines, default human-readable with "next step" recommendation).

| Sensor | Reports |
| --- | --- |
| `scripts/preflight/gcloud.sh` | active project, billing accounts (direct + linked-via), Compute API state, recommended next action |
| `scripts/preflight/vm.sh` | VM exists?, zone, reachable?, dependencies installed? |
| `scripts/preflight/app.sh` | App registered?, installed on target repo?, key present on VM and 0600? |
| `scripts/preflight/config.sh` | which `reviewer.env` fields are set/missing, which config files exist |
| `scripts/preflight/runtime.sh` | dry-run artifacts present?, cron installed?, last tick timestamp, last log lines |

A composite `scripts/status.sh` is just `cat`ing all five summaries — that's
the "what phase am I in?" command.

**Started implementation:** `scripts/preflight/gcloud.sh` now prototypes the
first sensor with human-readable output and `--report` key/value output.
`scripts/status.sh` provides the first composite status surface by combining
local config/runtime checks with that GCloud preflight.

**Orchestrator (Gemini, or a human reading sensor output)** — reads structured
state, decides what to do, asks the user only for:
- Genuine choices ("3 projects with billing — which one?")
- Browser-only steps Gemini can't do itself
- "About to do X, ok?" confirmations

### Why this shape

1. **Gemini is bad at gcloud syntax**, good at conversation. Hand it parsed
   state, let it talk to the user. Don't make it write gcloud commands from
   scratch.
2. **The logic is mostly already written.** Extracting `bootstrap-gcp.sh`'s
   helper functions into standalone preflights is mostly refactoring.
3. **Sensors are testable.** Fixture "user has 2 projects, neither billed,"
   run sensor, assert recommendation. Can't easily do that with conversation.
4. **No Gemini dependency.** A user who doesn't want Gemini still gets useful
   diagnostics — `bash scripts/preflight/gcloud.sh` tells them what's wrong
   and what to do.
5. **Idempotent, replayable.** Sensors can be re-run any time. Gemini can
   resume mid-flow after a closed Cloud Shell tab, an error, or a context
   reset, by re-reading the sensors.

### The `GEMINI.md` surface

`gemini-cli` auto-loads `GEMINI.md` from the project root as context. That's
where the agent-facing playbook lives:

```markdown
# GEMINI.md — agent playbook for setting up GoobReview

You're helping a user set up GoobReview. The setup has 5 phases (see
docs/onboarding-walkthrough.md). Your job is to drive it end to end.

Start every conversation with:
    bash scripts/status.sh

That tells you which phase the user is in. Jump straight to that phase.

## Phase 1 — Provision
... commands with flags, what to ask the user, what to expect ...

## Phase 2 — Register
After register-app.sh starts the server, tell the user:
  "Click Web Preview → port 8080. Create the App, download the .pem,
   upload it back. I'll wait."
Then poll for the key arriving on the VM. When it lands, paste the
install URL and tell the user to click it.

## What you must never do
- Don't enable cron until a dry-run artifact exists.
- Don't post a real review without showing the user the dry-run first.
```

If you want Claude Code or other agents to read the same playbook, symlink
`AGENTS.md` → `GEMINI.md`.

### Suggested sequencing

Don't refactor scripts yet. Order of operations:

1. **Walk through the current 5-phase flow end-to-end** as a human. Note real
   friction in this doc.
2. **Pick one preflight as the prototype** — `scripts/preflight/gcloud.sh`,
   lifted out of `bootstrap-gcp.sh`. Two modes: human summary + `--report`.
   `bootstrap-gcp.sh` calls it instead of doing the work inline.
3. **If that feels right, roll the same pattern to the other four sensors.**
   By the time all five exist, you have a clean diagnostic surface + a natural
   `status.sh`.
4. **Inner/outer split on `configure.sh` next** — it's the most painful
   interactive script and the one Gemini most needs to drive non-interactively.
5. **Write `GEMINI.md` last** — only after the scripts it points at have
   stable flag-driven shapes.

### Open questions for the audit

- Do you actually want Gemini to do step X, or would you rather do it yourself?
  (Ask this per phase as you walk through.)
- For each interactive prompt currently in `configure.sh` etc.: is the value
  something Gemini can infer (e.g. from a sensor), something the user must
  decide, or something with a safe default?
- Where does Gemini's adaptive value stop being worth the latency/token cost?
  (e.g. maybe phase 1's gcloud chooser is better as a pure script that just
  prints a numbered list.)
