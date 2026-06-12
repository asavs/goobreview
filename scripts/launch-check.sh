#!/usr/bin/env bash
# Validate that the current checkout/config completed the dry-run safety path
# required before enabling a live scheduler.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${REVIEWER_ENV_FILE:-$REPO_ROOT/config/reviewer.env}"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/ops.sh"
export OPS_LOG_PREFIX="launch-check"

ops_require_command jq "Run scripts/setup-vm.sh first."
ops_require_command sha256sum "Run scripts/setup-vm.sh first."
ops_require_file "$ENV_FILE" "Run scripts/configure.sh first."

ops_source_env "$ENV_FILE"
ops_require_envs REVIEWER_REPO REVIEWER_APP_ID REVIEWER_APP_INSTALLATION_ID REVIEWER_APP_PRIVATE_KEY_PATH
ops_validate_owner_repo "$REVIEWER_REPO" REVIEWER_REPO
ops_validate_uint REVIEWER_APP_ID "$REVIEWER_APP_ID"
ops_validate_uint REVIEWER_APP_INSTALLATION_ID "$REVIEWER_APP_INSTALLATION_ID"
ops_require_private_key "$REVIEWER_APP_PRIVATE_KEY_PATH"

CONFIG_DIR="${REVIEWER_CONFIG_DIR:-$REPO_ROOT/config}"
REQUIRED_CHECKS_FILE="${REVIEWER_REQUIRED_CHECKS_FILE:-$CONFIG_DIR/required-checks.json}"
PROMPT_PAYLOAD_FILE="${REVIEWER_PROMPT_PAYLOAD_FILE:-$CONFIG_DIR/prompt-payload.json}"
STATE_DIR="${REVIEWER_STATE:-/var/lib/goobreview/example}"

ops_require_file "$REQUIRED_CHECKS_FILE" "Run scripts/configure.sh to create config/required-checks.json from config/required-checks.example.json, or set REVIEWER_REQUIRED_CHECKS_FILE."
ops_require_file "$PROMPT_PAYLOAD_FILE" "Run scripts/configure.sh to create config/prompt-payload.json from config/prompt-payload.example.json, or set REVIEWER_PROMPT_PAYLOAD_FILE."

if ! jq -e 'type == "array" and all(.[]; type == "string" and length > 0)' "$REQUIRED_CHECKS_FILE" >/dev/null; then
  ops_die "Invalid required-check config in $REQUIRED_CHECKS_FILE. Use config/required-checks.example.json as the shape, then list the GitHub check names that gate live posting."
fi
if ! jq -e '.segments | type == "object"' "$PROMPT_PAYLOAD_FILE" >/dev/null; then
  ops_die "Invalid prompt payload config in $PROMPT_PAYLOAD_FILE. Run scripts/configure.sh or compare with config/prompt-payload.example.json."
fi

required_count="$(jq 'length' "$REQUIRED_CHECKS_FILE")"
if [ "$required_count" -eq 0 ] && [ "${REVIEWER_ALLOW_LAUNCH_WITHOUT_REQUIRED_CHECKS:-0}" != "1" ]; then
  ops_die "Required-check gate is empty in $REQUIRED_CHECKS_FILE. Configure real required checks, then run REVIEWER_DRY_RUN_BYPASS_CI=0 scripts/dry-run.sh. To intentionally launch without required checks, set REVIEWER_ALLOW_LAUNCH_WITHOUT_REQUIRED_CHECKS=1."
fi

if [ ! -d "$STATE_DIR" ]; then
  ops_die "Runtime state dir not found: $STATE_DIR. Run scripts/dry-run.sh first."
fi

latest_metadata="$(find "$STATE_DIR" -maxdepth 1 -type f \( -name 'dry-run-*.txt.launch.json' -o -name 'dry-pr-*.txt.launch.json' \) 2>/dev/null | sort | tail -n 1)"
if [ -z "$latest_metadata" ]; then
  ops_die "No launch metadata found in $STATE_DIR. Run REVIEWER_DRY_RUN_BYPASS_CI=0 scripts/dry-run.sh, inspect the artifact, then retry."
fi

required_sha="$(sha256sum "$REQUIRED_CHECKS_FILE" | awk '{print $1}')"
prompt_sha="$(sha256sum "$PROMPT_PAYLOAD_FILE" | awk '{print $1}')"

metadata_repo="$(jq -r '.repo // ""' "$latest_metadata")"
metadata_required_sha="$(jq -r '.required_checks_sha256 // ""' "$latest_metadata")"
metadata_prompt_sha="$(jq -r '.prompt_payload_sha256 // ""' "$latest_metadata")"
metadata_bypass_ci="$(jq -r '.dry_run_bypass_ci // ""' "$latest_metadata")"
metadata_required_count="$(jq '.required_checks | length' "$latest_metadata")"
metadata_event="$(jq -r '.event // ""' "$latest_metadata")"
metadata_text="$(jq -r '.dry_run_out // ""' "$latest_metadata")"

if [ "$metadata_repo" != "$REVIEWER_REPO" ]; then
  ops_die "Latest dry-run launch metadata targets $metadata_repo, but current REVIEWER_REPO is $REVIEWER_REPO. Run REVIEWER_DRY_RUN_BYPASS_CI=0 scripts/dry-run.sh for the current repo."
fi
if [ "$metadata_required_sha" != "$required_sha" ]; then
  ops_die "required-check config changed after the latest dry run. Run REVIEWER_DRY_RUN_BYPASS_CI=0 scripts/dry-run.sh again."
fi
if [ "$metadata_prompt_sha" != "$prompt_sha" ]; then
  ops_die "prompt-payload config changed after the latest dry run. Run REVIEWER_DRY_RUN_BYPASS_CI=0 scripts/dry-run.sh again."
fi
if [ "$metadata_required_count" -eq 0 ] && [ "${REVIEWER_ALLOW_LAUNCH_WITHOUT_REQUIRED_CHECKS:-0}" != "1" ]; then
  ops_die "Latest dry run did not exercise a required-check gate. Configure config/required-checks.json and run REVIEWER_DRY_RUN_BYPASS_CI=0 scripts/dry-run.sh, or set REVIEWER_ALLOW_LAUNCH_WITHOUT_REQUIRED_CHECKS=1 intentionally."
fi
if [ "$metadata_bypass_ci" != "0" ] && [ "${REVIEWER_ALLOW_LAUNCH_WITH_BYPASSED_CI:-0}" != "1" ]; then
  ops_die "Latest dry run used REVIEWER_DRY_RUN_BYPASS_CI=$metadata_bypass_ci. Run REVIEWER_DRY_RUN_BYPASS_CI=0 scripts/dry-run.sh so launch validation exercises production CI gating, or set REVIEWER_ALLOW_LAUNCH_WITH_BYPASSED_CI=1 intentionally."
fi
case "$metadata_event" in
  APPROVE|COMMENT|REQUEST_CHANGES)
    ;;
  *)
    ops_die "Latest dry-run metadata recorded event '$metadata_event', not a successful review verdict. Run scripts/dry-run.sh again and inspect the artifact."
    ;;
esac
if [ -n "$metadata_text" ] && [ ! -f "$metadata_text" ]; then
  ops_die "Dry-run text artifact referenced by $latest_metadata is missing: $metadata_text. Run scripts/dry-run.sh again."
fi

cat <<EOF
Launch validation passed.
  repo:                $REVIEWER_REPO
  state dir:           $STATE_DIR
  dry-run metadata:    $latest_metadata
  dry-run artifact:    ${metadata_text:-unknown}
  dry-run event:       ${metadata_event:-unknown}
  required checks:     $required_count
  CI bypass:           $metadata_bypass_ci
EOF
