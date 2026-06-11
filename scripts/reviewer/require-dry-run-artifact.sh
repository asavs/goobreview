#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${REVIEWER_ENV_FILE:-$REPO_ROOT/config/reviewer.env}"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

STATE_DIR="${REVIEWER_STATE:-$HOME/.goobreview}"
if [ "${REVIEWER_ALLOW_ENABLE_SYSTEMD_WITHOUT_DRY_RUN:-0}" = "1" ]; then
  exit 0
fi

dry_run_count=$(find "$STATE_DIR" -maxdepth 1 -type f \( -name 'dry-run-*.txt' -o -name 'dry-pr-*.txt' \) \
  2>/dev/null | wc -l | tr -d ' ')

if [ "$dry_run_count" -eq 0 ]; then
  printf 'GoobReview systemd dry-run gate failed: no dry-run artifact found in %s.\n' "$STATE_DIR" >&2
  printf 'Run scripts/dry-run.sh successfully and inspect the artifact before enabling the timer.\n' >&2
  printf 'To override intentionally, set REVIEWER_ALLOW_ENABLE_SYSTEMD_WITHOUT_DRY_RUN=1.\n' >&2
  exit 1
fi
