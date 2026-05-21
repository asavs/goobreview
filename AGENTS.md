# Agent Instructions

This repository is a template for setting up a VM-side automated GitHub PR reviewer.

When helping a user install it:

- Treat setup as operations work. Confirm before creating cloud resources, public repositories, or persistent credentials.
- Prefer a small Ubuntu LTS VM unless the user has a cloud/provider preference.
- Keep one reviewer identity per VM checkout, GitHub App, Gemini auth, and state directory.
- Never put GitHub App private keys, Gemini credentials, or cloud credentials in this repo. The App's `.pem` lives at `REVIEWER_APP_PRIVATE_KEY_PATH` on the VM (default `$REVIEWER_STATE/app-key.pem`, mode 0600).
- Configure the target project through ignored local files copied from `config/*.example.*`: `config/reviewer.env`, `config/personality.md`, `config/project-docs.txt`, `config/head-context-paths.txt`, and `config/required-checks.json`. `scripts/configure.sh` walks the user through these interactively.
- The user-facing customization surface is **`config/personality.md`** (role, voice, focus areas — pre-built options live in `config/personalities/`) and **`config/project-docs.txt`** (repo paths inlined into every prompt). The severity scale (P1/P2/P3) and verdict mapping live in the engine prompt — don't edit `scripts/reviewer/review-prompt.md` unless the user wants to change those contracts or the output format.
- Run `REVIEWER_DRY_RUN=1` before enabling cron.
- Enable cron only after a dry-run mints an installation token, Gemini headless mode works, required checks are configured, and a dry-run reviewer tick completes.

Important docs:

- `docs/quickstart.md`: end-to-end flow.
- `docs/github-app-setup.md`: register and install the GitHub App.
- `docs/vm-setup.md`: VM procurement and tool installation.
- `docs/daemon-runbook.md`: operations, scheduler, config reference, prompt invariants, known limits.
