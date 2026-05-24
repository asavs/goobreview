#!/usr/bin/env bash
# Render the exact prompt text that would be sent to Gemini for one PR.
# No Gemini call is made, no review is posted, and seen.txt is not updated.
#
# Usage:
#   scripts/render-prompt.sh PR_NUMBER [OUTPUT_FILE] [--explain]
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

pr_number=""
output_file=""
explain=""

for arg in "$@"; do
  case "$arg" in
    --explain) explain=1 ;;
    *)
      if [ -z "$pr_number" ]; then
        pr_number="$arg"
      elif [ -z "$output_file" ]; then
        output_file="$arg"
      else
        ops_die "Unexpected argument: $arg"
      fi
      ;;
  esac
done

if [ -z "$pr_number" ]; then
  ops_die "Usage: scripts/render-prompt.sh PR_NUMBER [OUTPUT_FILE] [--explain]"
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

if [ -n "$explain" ] && [ -z "$output_file" ]; then
  output_file="/tmp/goobreview-prompt-${pr_number}.md"
fi

CONFIG_DIR="$REPO_ROOT/config"
PROMPT_PAYLOAD_FILE="${REVIEWER_PROMPT_PAYLOAD_FILE:-$CONFIG_DIR/prompt-payload.json}"
if [ ! -f "$PROMPT_PAYLOAD_FILE" ] && [ -f "$CONFIG_DIR/prompt-payload.example.json" ]; then
  PROMPT_PAYLOAD_FILE="$CONFIG_DIR/prompt-payload.example.json"
fi
ops_require_file "$PROMPT_PAYLOAD_FILE" "Run scripts/configure.sh first."

export REVIEWER_RENDER_PROMPT_ONLY=1
export REVIEWER_MAX_PRS=1
export REVIEWER_ONLY_PR="$pr_number"
if [ -n "$output_file" ]; then
  export REVIEWER_PROMPT_OUT="$output_file"
fi

"$REVIEWER_SH"

if [ -n "$explain" ]; then
  echo
  echo "Included prompt segments from $PROMPT_PAYLOAD_FILE:"
  jq -r '
    .segments
    | to_entries[]
    | (if (.value.enabled == true) then "[x] " else "[ ] " end) + .key
  ' "$PROMPT_PAYLOAD_FILE"
fi

if [ -n "$output_file" ]; then
  ops_log "Wrote prompt text for $REVIEWER_REPO PR #$pr_number to $output_file"
fi
