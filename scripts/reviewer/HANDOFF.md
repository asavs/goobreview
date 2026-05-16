# Reviewer Cron Handoff

This directory contains the VM-side peer review cron script for the repository named by `REVIEWER_REPO`.

Read the durable runbook first:

```text
docs/daemon-runbook.md
```

The short version:

- `reviewer.sh` polls open PRs in `REVIEWER_REPO` when cron runs it.
- It skips PRs authored by the account configured as `REVIEWER_USER`.
- It reviews each PR head commit once, so follow-up commits trigger a new review.
- It posts at most `REVIEWER_MAX_PRS` reviews per cron run, defaulting to one.
- It sends PR metadata, CI summaries, the PR head file tree, selected PR-head file contents, configured project review docs, and the full diff to `gemini`.
- It uses `REVIEWER_GEMINI_MODEL`, defaulting to Gemini CLI's `auto` model routing.
- `sync-worktree.sh` should run immediately before `reviewer.sh`; it keeps the daemon checkout detached at `origin/master` and fails closed if the checkout is dirty.
- It expects a `VERDICT: APPROVE`, `VERDICT: REQUEST_CHANGES`, or `VERDICT: COMMENT` line plus an optional `REVIEW_META` JSON block.
- It submits the result through GitHub's review API under the peer account logged in on the VM, using inline comments when Gemini supplies valid changed-line anchors.
- It can update a managed PR checklist for current P1 findings and apply lightweight labels when those labels exist in GitHub.
- `ensure-labels.sh` creates or updates the lightweight labels used by the reviewer.

This is intentionally a peer-account reviewer, not the PR author's own account. GitHub does not allow a user to approve or request changes on their own PR, so formal automated reviews need to run under a collaborator account or a separate review identity.

Cron should run from a stable checkout of this template repo that Gemini has trusted interactively. Do not use `/tmp` or an active development branch as the canonical cron target.

Use `scripts/reviewer/merge-gate.sh <PR_NUMBER>` before merge to verify latest-head approval, mergeability, checks, and unresolved review threads.
