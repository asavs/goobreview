#!/usr/bin/env bash
# Dry-run the reviewer once against the configured target repo. No reviews
# are posted; everything else runs (token mint, file fetch, prompt assembly,
# Gemini call, verdict parse) so you can inspect the result in the log.
#
# Usage:  scripts/dry-run.sh [PR_NUMBER]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${REVIEWER_ENV_FILE:-$REPO_ROOT/config/reviewer.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE. Run scripts/configure.sh first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

export REVIEWER_DRY_RUN=1
export REVIEWER_MAX_PRS=1
if [ -n "${1:-}" ]; then
  export REVIEWER_ONLY_PR="$1"
  echo "[dry-run] Reviewing $REVIEWER_REPO PR #$REVIEWER_ONLY_PR (no review will be posted)..."
else
  echo "[dry-run] Reviewing the oldest unseen PR in $REVIEWER_REPO (no review will be posted)..."
fi

"$SCRIPT_DIR/reviewer/reviewer.sh" || true

LOG_FILE="${REVIEWER_STATE:-/var/lib/goobreview/example}/log.txt"
if [ -f "$LOG_FILE" ]; then
  echo
  echo "--- tail -n 80 $LOG_FILE ---"
  tail -n 80 "$LOG_FILE"
else
  echo "Log file not found: $LOG_FILE" >&2
fi
