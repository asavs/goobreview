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

bash "$SCRIPT_DIR/sync-worktree.sh"
bash "$SCRIPT_DIR/reviewer.sh"
