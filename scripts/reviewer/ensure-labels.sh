#!/usr/bin/env bash
set -euo pipefail

REPO="${REVIEWER_REPO:-}"

if [ -z "$REPO" ]; then
  printf 'missing REVIEWER_REPO; set it to owner/repo\n' >&2
  exit 2
fi

require() { command -v "$1" >/dev/null || { printf 'missing: %s\n' "$1" >&2; exit 1; }; }
require gh

ensure_label() {
  local name="$1"
  local color="$2"
  local description="$3"

  if gh api "repos/$REPO/labels/$name" >/dev/null 2>&1; then
    gh api -X PATCH "repos/$REPO/labels/$name" \
      -f color="$color" \
      -f description="$description" >/dev/null
  else
    gh api -X POST "repos/$REPO/labels" \
      -f name="$name" \
      -f color="$color" \
      -f description="$description" >/dev/null
  fi

  printf 'ensured label: %s\n' "$name"
}

ensure_label "agent-reviewed" "0e8a16" "Reviewed by the peer-account reviewer cron."
ensure_label "agent-requested-changes" "d73a4a" "Agent review found blocking changes."
ensure_label "needs-human-decision" "fbca04" "Agent review needs a human decision before merge."
