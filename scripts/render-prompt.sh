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
ops_require_private_key "$REVIEWER_APP_PRIVATE_KEY_PATH"
for cmd in curl jq node tar flock; do
  ops_require_command "$cmd" "Run scripts/setup-vm.sh first."
done

if [ -n "$explain" ] && [ -z "$output_file" ]; then
  state_dir="${REVIEWER_STATE:-$HOME/.goobreview}"
  mkdir -p "$state_dir" || ops_die "Failed to create REVIEWER_STATE: $state_dir"
  chmod 700 "$state_dir" 2>/dev/null || ops_die "Failed to set REVIEWER_STATE permissions to 0700: $state_dir"
  output_file=$(mktemp "$state_dir/prompt-pr-${pr_number}.XXXXXX.md")
  chmod 600 "$output_file" 2>/dev/null || ops_die "Failed to set prompt output permissions to 0600: $output_file"
fi

export REVIEWER_RENDER_PROMPT_ONLY=1
export REVIEWER_MAX_PRS=1
export REVIEWER_ONLY_PR="$pr_number"
if [ -n "$output_file" ]; then
  export REVIEWER_PROMPT_OUT="$output_file"
fi

"$REVIEWER_SH"

if [ -n "$explain" ]; then
  echo
  echo "Prompt composition is fixed in scripts/reviewer/lib/prompt.sh (build_review_prompt)."
  echo "Deployment policy knobs live in config/reviewer.env: REVIEWER_POSTED_PERSONALITY=${REVIEWER_POSTED_PERSONALITY:-none}, REVIEWER_RESEARCH_CONSENT=${REVIEWER_RESEARCH_CONSENT:-0}, REVIEWER_INCLUDE_AUTHOR=${REVIEWER_INCLUDE_AUTHOR:-0}, REVIEWER_INCLUDE_DESCRIPTION=${REVIEWER_INCLUDE_DESCRIPTION:-1}, REVIEWER_INCLUDE_COMMIT_SUBJECTS=${REVIEWER_INCLUDE_COMMIT_SUBJECTS:-1}."
fi

if [ -n "$output_file" ]; then
  ops_log "Wrote prompt text for $REVIEWER_REPO PR #$pr_number to $output_file"
fi
