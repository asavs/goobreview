#!/usr/bin/env bash
set -euo pipefail

REPO="${REVIEWER_REPO:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/github-api.sh"

if [ -z "$REPO" ]; then
  printf 'missing REVIEWER_REPO; set it to owner/repo\n' >&2
  exit 2
fi

require() { command -v "$1" >/dev/null || { printf 'missing: %s\n' "$1" >&2; exit 1; }; }
require curl
require jq
if [ -z "${GH_TOKEN:-}" ]; then
  printf 'missing GH_TOKEN; mint an App installation token first\n' >&2
  exit 2
fi

ensure_label() {
  local name="$1"
  local color="$2"
  local description="$3"
  local payload

  payload="$(jq -n -c --arg name "$name" --arg color "$color" --arg description "$description" \
    '{name: $name, color: $color, description: $description}')"

  if github_api_get "repos/$REPO/labels/$name" >/dev/null 2>&1; then
    github_api_patch_json "repos/$REPO/labels/$name" "$payload" >/dev/null
  else
    github_api_post_json "repos/$REPO/labels" "$payload" >/dev/null
  fi

  printf 'ensured label: %s\n' "$name"
}

ensure_label "agent-reviewed" "0e8a16" "Reviewed by the peer-account reviewer cron."
ensure_label "agent-requested-changes" "d73a4a" "Agent review found blocking changes."
ensure_label "needs-human-decision" "fbca04" "Agent review needs a human decision before merge."
