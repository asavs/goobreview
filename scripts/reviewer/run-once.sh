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
LOCK_FILE="$STATE_DIR/lock"
ALLOW_STALE_CHECKOUT="${REVIEWER_ALLOW_STALE_CHECKOUT_ON_SYNC_FAILURE:-0}"
mkdir -p "$STATE_DIR"
"$SCRIPT_DIR/rotate-log.sh" "$LOG_FILE" 2>/dev/null || true

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG_FILE"; }

case "$ALLOW_STALE_CHECKOUT" in
  0|1) ;;
  *)
    log "invalid REVIEWER_ALLOW_STALE_CHECKOUT_ON_SYNC_FAILURE=$ALLOW_STALE_CHECKOUT"
    printf 'GoobReview invalid REVIEWER_ALLOW_STALE_CHECKOUT_ON_SYNC_FAILURE=%s. See %s.\n' "$ALLOW_STALE_CHECKOUT" "$LOG_FILE" >&2
    exit 1
    ;;
esac

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "sync skipped by lock; another reviewer tick is already running"
  printf 'GoobReview tick skipped; another reviewer tick holds %s.\n' "$LOCK_FILE" >&2
  exit 0
fi

if ! bash "$SCRIPT_DIR/sync-worktree.sh"; then
  {
    printf '%s sync failed before reviewer tick; review did not run\n' "$(date -Is)"
    if [ -f "$SYNC_LOG" ]; then
      tail -n 40 "$SYNC_LOG"
    fi
  } >>"$LOG_FILE"
  if [ "$ALLOW_STALE_CHECKOUT" = "1" ]; then
    log "operator override REVIEWER_ALLOW_STALE_CHECKOUT_ON_SYNC_FAILURE=1; running current checkout after sync failure"
  else
    printf 'GoobReview sync failed; review did not run. See %s and %s.\n' "$SYNC_LOG" "$LOG_FILE" >&2
    exit 1
  fi
else
  log "sync succeeded; review tick started"
fi

REVIEWER_LOCK_HELD=1 bash "$SCRIPT_DIR/reviewer.sh"
