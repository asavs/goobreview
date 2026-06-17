# Agent Instructions

This repository is a template for setting up a VM-side automated GitHub PR reviewer.

When helping a user install it:

- Treat setup as operations work. Confirm before linking billing, creating projects or public repositories, storing persistent credentials, or enabling the scheduler. The free-tier VM may be created with announced defaults — say what and where, create it, report it.
- Prefer a small Ubuntu LTS VM unless the user has a cloud/provider preference.
- Keep one reviewer identity per VM checkout, GitHub App, Gemini auth, and state directory.
- Never put GitHub App private keys, Gemini credentials, or cloud credentials in this repo. The App's `.pem` lives at `REVIEWER_APP_PRIVATE_KEY_PATH` on the VM (default `$REVIEWER_STATE/app-key.pem`, mode 0600).
- Configure the target project through ignored local files copied from `config/*.example.*`: `config/reviewer.env` and `config/required-checks.json`. `scripts/configure.sh` walks the user through these interactively. Gallery files in `config/personalities/` are committed verbatim; users choose the posted review style with `REVIEWER_POSTED_PERSONALITY=none|linus`, while `REVIEWER_PERSONALITY_FILE` remains only a legacy/internal escape hatch.
- The user-facing customization surfaces are **`REVIEWER_POSTED_PERSONALITY`** (which style posts), **`REVIEWER_RESEARCH_CONSENT`** (whether public-repo paired artifacts may be retained), **`config/personalities/<name>.md`** (role and voice), and the **`REVIEWER_INCLUDE_*` blinding flags in `reviewer.env`** (author username, PR description, commit subjects). The prompt composition itself is fixed in `scripts/reviewer/lib/prompt.sh`; forks edit it to change the payload shape. The engine prompt only defines the minimal GitHub review output format - don't edit `scripts/reviewer/review-prompt.md` unless the user wants to change that format.
- Run `REVIEWER_DRY_RUN=1` before enabling cron.
- Enable cron only after a dry-run mints an installation token, Gemini headless mode works, required checks are configured, and a dry-run reviewer tick completes.

## Onboarding Design Principles

If you are changing the onboarding scripts or docs (not just running them), preserve these invariants:

- Sense with scripts, not prose. Every phase has a read-only sensor under `scripts/preflight/` with a `--report` mode; deterministic state checks live in shell, never in agent reasoning or docs.
- Reads are free, mutations are deliberate. Enumerate, infer, and prefill everything (projects, zones, VM names, App IDs, installation IDs, ports). Billing links, projects, public repos, credentials, and cron need consent; the free-tier VM needs only an announcement and a post-creation record.
- The user appears only at true boundaries: browser auth, account-level choices, credential custody. If a step is deterministic, script it; never make the user run diagnostics, copy IDs, or translate between tools.
- Everything is resumable. Rerunning any script must find existing state and continue, not duplicate resources. Report checkout divergence before mutating a checkout.
- Gemini auth and workspace trust use documented Gemini CLI mechanisms only, checked in the exact context the reviewer runs in.
- Prefer the GitHub App token over human GitHub auth wherever it can answer the question.
- The README carries at most a sentence or two of onboarding philosophy; operating procedure belongs in `GEMINI.md`, rationale here.

Important docs:

- `docs/quickstart.md`: end-to-end flow.
- `docs/github-app-setup.md`: register and install the GitHub App.
- `docs/vm-setup.md`: VM procurement and tool installation.
- `docs/daemon-runbook.md`: operations, scheduler, config reference, prompt invariants, known limits.
