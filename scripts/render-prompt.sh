#!/usr/bin/env bash
# Render the exact prompt payload that would be sent to Gemini for one PR.
# No Gemini call is made, no review is posted, and seen.txt is not updated.
#
# Usage:
#   scripts/render-prompt.sh PR_NUMBER [OUTPUT_FILE]
#
# Without OUTPUT_FILE, the prompt is written to stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${REVIEWER_ENV_FILE:-$REPO_ROOT/config/reviewer.env}"
REVIEWER_SH="$SCRIPT_DIR/reviewer/reviewer.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/ops.sh"
export OPS_LOG_PREFIX="render-prompt"

pr_number="${1:-}"
output_file="${2:-}"

if [ -z "$pr_number" ]; then
  ops_die "Usage: scripts/render-prompt.sh PR_NUMBER [OUTPUT_FILE]"
fi

ops_validate_uint PR_NUMBER "$pr_number"
ops_require_file "$ENV_FILE" "Run scripts/configure.sh first."
ops_require_executable "$REVIEWER_SH" "This checkout looks incomplete."

ops_source_env "$ENV_FILE"
ops_require_envs REVIEWER_REPO REVIEWER_APP_ID REVIEWER_APP_INSTALLATION_ID REVIEWER_APP_PRIVATE_KEY_PATH
ops_validate_owner_repo "$REVIEWER_REPO" REVIEWER_REPO
ops_validate_uint REVIEWER_APP_ID "$REVIEWER_APP_ID"
ops_validate_uint REVIEWER_APP_INSTALLATION_ID "$REVIEWER_APP_INSTALLATION_ID"
ops_require_file "$REVIEWER_APP_PRIVATE_KEY_PATH" "Set REVIEWER_APP_PRIVATE_KEY_PATH in $ENV_FILE."
if [ ! -s "$REVIEWER_APP_PRIVATE_KEY_PATH" ] || [ ! -r "$REVIEWER_APP_PRIVATE_KEY_PATH" ]; then
  ops_die "Private key is empty or unreadable: $REVIEWER_APP_PRIVATE_KEY_PATH"
fi
for cmd in gh jq node tar flock; do
  ops_require_command "$cmd" "Run scripts/setup-vm.sh first."
done

export REVIEWER_RENDER_PROMPT_ONLY=1
export REVIEWER_MAX_PRS=1
export REVIEWER_ONLY_PR="$pr_number"
if [ -n "$output_file" ]; then
  export REVIEWER_PROMPT_OUT="$output_file"
fi

"$REVIEWER_SH"

if [ -n "$output_file" ]; then
  ops_log "Wrote prompt payload for $REVIEWER_REPO PR #$pr_number to $output_file"
fi
