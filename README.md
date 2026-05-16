# GoobReview

An end-to-end pull request reviewer template powered by Gemini CLI and GitHub.

GoobReview is designed for users who want to point a Google AI Pro-backed Gemini CLI setup at their repository and get real GitHub PR reviews from a reviewer identity. It turns a small VM into a durable review daemon that reads your project docs, waits for CI, reviews non-draft PRs, and posts `APPROVE`, `REQUEST_CHANGES`, or `COMMENT` reviews.

The intended setup is:

1. Clone this template onto a small Linux VM.
2. Configure the target GitHub repository and the project docs the reviewer should read.
3. Authenticate `gh` as the account that should post reviews.
4. Authenticate Gemini CLI with the Google account you want to use, including Google AI Pro or Ultra accounts where available.
5. Run the reviewer from cron.

This is useful when you want normal GitHub review semantics from an account that is not the PR author. The daemon can submit `APPROVE`, `REQUEST_CHANGES`, or `COMMENT` reviews, add best-effort inline comments, update a managed PR checklist, and re-review every new PR head commit.

## What It Does

- Polls open, non-draft pull requests.
- Skips PRs authored by the authenticated reviewer account.
- Gates reviews on configured GitHub check-run names.
- Fetches selected project documentation from the PR head.
- Sends PR metadata, CI status, file tree, selected file contents, and diff to Gemini CLI.
- Posts one consolidated GitHub review.
- Records `PR_NUMBER HEAD_SHA` pairs only after successful review posting.

## Fast Path For An Agent

Give your coding agent this repository and ask:

```text
Use this template to set up an automated peer-account PR reviewer for OWNER/REPO.
Walk me through creating or selecting a small Ubuntu VM, installing gh and Gemini CLI,
authenticating both tools, choosing project docs/checks, running a dry-run review,
and enabling cron only after the dry run is clean.
```

The agent should follow:

- [docs/quickstart.md](docs/quickstart.md)
- [docs/vm-setup.md](docs/vm-setup.md)
- [docs/project-configuration.md](docs/project-configuration.md)
- [docs/daemon-runbook.md](docs/daemon-runbook.md)

## Repository Layout

```text
config/
  reviewer.env.example      Example environment file for the target repo.
  required-checks.example.json      Example required GitHub check-run names.
  project-docs.example.txt          Example review docs fetched from the PR head.
  head-context-paths.example.txt    Example extra files fetched for validation.
scripts/reviewer/
  reviewer.sh               Poll, prompt Gemini, and post reviews.
  run-once.sh               Load config, sync checkout, run one review tick.
  sync-worktree.sh          Keep this checkout detached at the configured branch.
  check-ci.sh               Required check-run gate.
  ensure-labels.sh          Optional label setup.
  merge-gate.sh             Mechanical pre-merge checks.
  review-prompt.md          Base reviewer prompt.
docs/
  quickstart.md
  vm-setup.md
  project-configuration.md
  daemon-runbook.md
  publish-template-repo.md
```

## Safety Model

The daemon trusts local `gh` and `gemini` authentication on the VM. Use a dedicated reviewer account or dedicated machine user when possible. The reviewer account needs repository read access and pull-request write access. Do not run this from a developer's active working checkout.

The daemon does not merge PRs and does not edit source code. It only posts reviews, updates a managed checklist block in PR bodies, and applies optional labels.
