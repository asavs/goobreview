#!/usr/bin/env bash
# Dry-run the reviewer once against the configured target repo. No reviews are
# posted. A fresh artifact is written for each run containing the exact agy
# prompt payload and agy's full response.
#
# Usage:  scripts/dry-run.sh [PR_NUMBER]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${REVIEWER_ENV_FILE:-$REPO_ROOT/config/reviewer.env}"
REVIEWER_SH="$SCRIPT_DIR/reviewer/reviewer.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/ops.sh"
export OPS_LOG_PREFIX="dry-run"

ops_require_file "$ENV_FILE" "Run scripts/configure.sh first."
ops_require_executable "$REVIEWER_SH" "This checkout looks incomplete."

ops_source_env "$ENV_FILE"
ops_require_envs REVIEWER_REPO REVIEWER_APP_ID REVIEWER_APP_INSTALLATION_ID REVIEWER_APP_PRIVATE_KEY_PATH
ops_validate_owner_repo "$REVIEWER_REPO" REVIEWER_REPO
ops_validate_uint REVIEWER_APP_ID "$REVIEWER_APP_ID"
ops_validate_uint REVIEWER_APP_INSTALLATION_ID "$REVIEWER_APP_INSTALLATION_ID"
ops_require_private_key "$REVIEWER_APP_PRIVATE_KEY_PATH"
if [ ! -d "$HOME/.gemini/antigravity-cli" ]; then
  ops_die "Antigravity CLI auth state not found at $HOME/.gemini/antigravity-cli. Run 'agy' once in this checkout and complete Google sign-in."
fi
for cmd in curl agy jq node sha256sum tar flock timeout; do
  ops_require_command "$cmd" "Run scripts/setup-vm.sh first."
done

export REVIEWER_DRY_RUN=1
export REVIEWER_MAX_PRS=1
export REVIEWER_DRY_RUN_BYPASS_CI="${REVIEWER_DRY_RUN_BYPASS_CI:-1}"
export REVIEWER_IGNORE_AGY_BACKOFF="${REVIEWER_IGNORE_AGY_BACKOFF:-1}"

LOG_FILE="${REVIEWER_STATE:-/var/lib/goobreview/example}/log.txt"
mkdir -p "$(dirname "$LOG_FILE")"
log_start_line=0
if [ -f "$LOG_FILE" ]; then
  log_start_line=$(wc -l < "$LOG_FILE" | tr -d ' ')
fi

if [ -n "${1:-}" ]; then
  ops_validate_uint PR_NUMBER "$1"
  export REVIEWER_ONLY_PR="$1"
  export REVIEWER_DRY_RUN_OUT="${REVIEWER_DRY_RUN_OUT:-${REVIEWER_STATE:-/var/lib/goobreview/example}/dry-pr-${REVIEWER_ONLY_PR}.txt}"
  echo "[dry-run] Reviewing $REVIEWER_REPO PR #$REVIEWER_ONLY_PR (no review will be posted)..."
  echo "[dry-run] Writing prompt + agy response to $REVIEWER_DRY_RUN_OUT"
else
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  export REVIEWER_DRY_RUN_OUT="${REVIEWER_DRY_RUN_OUT:-${REVIEWER_STATE:-/var/lib/goobreview/example}/dry-run-${stamp}.txt}"
  echo "[dry-run] Reviewing the oldest unseen PR in $REVIEWER_REPO (no review will be posted)..."
  echo "[dry-run] Writing prompt + agy response to $REVIEWER_DRY_RUN_OUT"
fi

set +e
"$REVIEWER_SH"
reviewer_status=$?
set -e

if [ -f "$LOG_FILE" ]; then
  echo
  echo "--- new log lines from $LOG_FILE ---"
  tail -n +"$((log_start_line + 1))" "$LOG_FILE"
else
  echo "Log file not found: $LOG_FILE" >&2
fi

if [ -f "${REVIEWER_DRY_RUN_OUT:-}" ]; then
  echo
  echo "Dry-run artifact:"
  echo "  $REVIEWER_DRY_RUN_OUT"
else
  echo
  echo "Dry-run artifact was not written. Check the new log lines above for the reason." >&2
fi

exit "$reviewer_status"
