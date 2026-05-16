#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

REPO_DIR="${REVIEWER_SYNC_REPO_DIR:-$DEFAULT_REPO_DIR}"
REMOTE="${REVIEWER_SYNC_REMOTE:-origin}"
BRANCH="${REVIEWER_SYNC_BRANCH:-main}"
STATE_DIR="${REVIEWER_STATE:-$HOME/.goobreview}"
LOG_FILE="${REVIEWER_SYNC_LOG:-$STATE_DIR/sync.log}"

mkdir -p "$STATE_DIR"

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG_FILE"; }

require() { command -v "$1" >/dev/null || { log "missing: $1"; exit 1; }; }
require git

repo_root=$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null) || {
  log "not a git worktree: $REPO_DIR"
  exit 1
}

dirty_status=$(git -C "$repo_root" status --porcelain=v1 --untracked-files=normal)
if [ -n "$dirty_status" ]; then
  log "refusing to sync dirty reviewer checkout at $repo_root"
  printf '%s\n' "$dirty_status" >> "$LOG_FILE"
  exit 1
fi

log "sync start repo=$repo_root remote=$REMOTE branch=$BRANCH"

git -C "$repo_root" fetch --prune "$REMOTE" "+refs/heads/$BRANCH:refs/remotes/$REMOTE/$BRANCH" >> "$LOG_FILE" 2>&1

target_ref="refs/remotes/$REMOTE/$BRANCH"
target_sha=$(git -C "$repo_root" rev-parse --verify "$target_ref^{commit}") || {
  log "failed to resolve $target_ref"
  exit 1
}
current_sha=$(git -C "$repo_root" rev-parse --verify HEAD)

if [ "$current_sha" != "$target_sha" ]; then
  log "updating reviewer checkout $current_sha -> $target_sha"
  git -C "$repo_root" checkout --detach "$target_sha" >> "$LOG_FILE" 2>&1
fi

post_sync_status=$(git -C "$repo_root" status --porcelain=v1 --untracked-files=normal)
if [ -n "$post_sync_status" ]; then
  log "reviewer checkout became dirty after sync at $repo_root"
  printf '%s\n' "$post_sync_status" >> "$LOG_FILE"
  exit 1
fi

final_sha=$(git -C "$repo_root" rev-parse --verify HEAD)
log "sync complete sha=$final_sha"
