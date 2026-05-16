# Agent Instructions

This repository is a template for setting up a VM-side automated GitHub PR reviewer.

When helping a user install it:

- Treat setup as operations work. Confirm before creating cloud resources, public repositories, or persistent credentials.
- Prefer a small Ubuntu LTS VM unless the user has a cloud/provider preference.
- Keep one reviewer identity per VM account, checkout, `gh` auth, Gemini auth, and state directory.
- Never put GitHub tokens, Gemini credentials, or cloud credentials in this repo.
- Configure the target project through ignored local files copied from `config/*.example.*`: `config/reviewer.env`, `config/project-docs.txt`, `config/head-context-paths.txt`, and `config/required-checks.json`.
- Run `REVIEWER_DRY_RUN=1` before enabling cron.
- Enable cron only after `gh auth status`, Gemini headless mode, required checks, and a dry-run reviewer tick all work.

Important docs:

- `docs/quickstart.md`: end-to-end flow.
- `docs/vm-setup.md`: VM procurement and tool installation.
- `docs/project-configuration.md`: target repo docs and check configuration.
- `docs/daemon-runbook.md`: operations, cron, logs, and known limits.
