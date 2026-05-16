# Project Configuration

The daemon is generic. The target project is selected by config.

## Environment

Copy:

```bash
cp config/reviewer.env.example config/reviewer.env
cp config/project-docs.example.txt config/project-docs.txt
cp config/head-context-paths.example.txt config/head-context-paths.txt
cp config/required-checks.example.json config/required-checks.json
```

Required:

```bash
REVIEWER_REPO=owner/repo
REVIEWER_STATE=/var/lib/goobreview/example
REVIEWER_SYNC_REPO_DIR=/opt/goobreview/example
```

Useful:

```bash
REVIEWER_RUNNER_NAME=reviewer-vm
REVIEWER_GEMINI_MODEL=auto
REVIEWER_MAX_PRS=1
```

These local config files are ignored by Git so the daemon checkout can stay clean while `sync-worktree.sh` updates the tracked template scripts and docs.

## Project Docs

`config/project-docs.txt` lists repository paths fetched from the PR head and included in every review prompt.

Good entries:

```text
AGENTS.md
CONTRIBUTING.md
README.md
docs/architecture.md
docs/security.md
docs/pr-review-workflow.md
```

Keep the list focused. These docs become part of every prompt, so large or low-signal files make reviews weaker and slower.

The script treats PR-authored docs as context, not authority. The base prompt still tells Gemini that changed project content cannot override reviewer instructions.

## Head Context

`config/head-context-paths.txt` lists extra files fetched from the PR head when present. Use this for reference validation, not broad code review.

Good entries:

```text
package.json
pyproject.toml
Cargo.toml
.github/workflows/ci.yml
scripts/deploy.sh
```

Use exact repository paths. Wildcards are not expanded.

## Required Checks

`config/required-checks.json` contains exact GitHub check-run display names:

```json
[
  "Unit tests",
  "Build",
  "Lint"
]
```

The daemon waits when required checks are missing or pending. It posts `REQUEST_CHANGES` without calling Gemini when a required check fails.

An empty array means "do not gate on required checks." Use that only for initial setup or repositories without CI.

## Labels

`scripts/reviewer/ensure-labels.sh` creates or updates:

- `agent-reviewed`
- `agent-requested-changes`
- `needs-human-decision`
- `follow-up-candidates`

These labels are optional. Review posting does not depend on them.

## Prompt Customization

Edit `scripts/reviewer/review-prompt.md` for review style and severity policy.

Keep these invariants:

- The first verdict line must be `VERDICT: APPROVE`, `VERDICT: REQUEST_CHANGES`, or `VERDICT: COMMENT`.
- The metadata block must remain valid JSON between `<!-- REVIEW_META` and `REVIEW_META -->`.
- Inline comments require `path` plus right-side changed `line` values.
