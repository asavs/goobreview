#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${REVIEWER_ENV_FILE:-$REPO_DIR/config/reviewer.env}"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

STATE_DIR="${REVIEWER_STATE:-$HOME/.goobreview}"
LOG_FILE="$STATE_DIR/log.txt"
SYNC_LOG="${REVIEWER_SYNC_LOG:-$STATE_DIR/sync.log}"
mkdir -p "$STATE_DIR"

if ! bash "$SCRIPT_DIR/sync-worktree.sh"; then
  {
    printf '%s sync failed before reviewer tick; continuing with current checkout\n' "$(date -Is)"
    if [ -f "$SYNC_LOG" ]; then
      tail -n 40 "$SYNC_LOG"
    fi
  } >>"$LOG_FILE"
  printf 'GoobReview sync failed; continuing with current checkout. See %s and %s.\n' "$SYNC_LOG" "$LOG_FILE" >&2
fi

bash "$SCRIPT_DIR/reviewer.sh"
