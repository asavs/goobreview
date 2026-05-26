#!/usr/bin/env bash
# Summarize the current GoobReview setup state and next likely action.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${REVIEWER_ENV_FILE:-$REPO_ROOT/config/reviewer.env}"
CONFIG_DIR="$REPO_ROOT/config"
GCLOUD_PREFLIGHT="$SCRIPT_DIR/preflight/gcloud.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/ops.sh"
export OPS_LOG_PREFIX="status"

bool() {
  case "$1" in
    1|true|True|TRUE|yes) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

present() {
  local value="$1" placeholder="${2:-}"
  if [ -z "$value" ] || { [ -n "$placeholder" ] && [ "$value" = "$placeholder" ]; }; then
    printf 'false'
  else
    printf 'true'
  fi
}

count_dry_runs() {
  local state_dir="$1"
  if [ -z "$state_dir" ] || [ ! -d "$state_dir" ]; then
    printf '0'
    return
  fi
  find "$state_dir" -maxdepth 1 -type f \( -name 'dry-run-*.txt' -o -name 'dry-pr-*.txt' \) \
    2>/dev/null | wc -l | tr -d ' '
}

cron_installed() {
  local current marker
  marker="# GoobReview reviewer (managed by scripts/enable-cron.sh)"
  if ! command -v crontab >/dev/null 2>&1; then
    printf 'unknown'
    return
  fi
  current="$(crontab -l 2>/dev/null || true)"
  if printf '%s\n' "$current" | grep -Fq "$marker"; then
    printf 'true'
  else
    printf 'false'
  fi
}

repo=""
app_id=""
installation_id=""
key_path=""
state_dir="/var/lib/goobreview/example"
personality_file=""

if [ -f "$ENV_FILE" ]; then
  repo="$(ops_env_get "$ENV_FILE" REVIEWER_REPO)"
  app_id="$(ops_env_get "$ENV_FILE" REVIEWER_APP_ID)"
  installation_id="$(ops_env_get "$ENV_FILE" REVIEWER_APP_INSTALLATION_ID)"
  key_path="$(ops_env_get "$ENV_FILE" REVIEWER_APP_PRIVATE_KEY_PATH)"
  state_from_env="$(ops_env_get "$ENV_FILE" REVIEWER_STATE)"
  personality_file="$(ops_env_get "$ENV_FILE" REVIEWER_PERSONALITY_FILE)"
  [ -z "$state_from_env" ] || state_dir="$state_from_env"
fi

required_checks="$CONFIG_DIR/required-checks.json"
prompt_payload="$CONFIG_DIR/prompt-payload.json"
dry_run_count="$(count_dry_runs "$state_dir")"
cron_state="$(cron_installed)"

repo_ready="$(present "$repo" "owner/repo")"
app_id_ready="$(present "$app_id")"
installation_ready="$(present "$installation_id")"
key_ready=0
if [ -n "$key_path" ] && [ -s "$key_path" ]; then
  key_ready=1
fi
required_checks_ready=0
if [ -f "$required_checks" ]; then
  required_checks_ready=1
fi
prompt_payload_ready=0
if [ -f "$prompt_payload" ]; then
  prompt_payload_ready=1
fi

next="Run bash scripts/bootstrap-gcp.sh in Cloud Shell to provision the VM."
if [ -f "$ENV_FILE" ]; then
  if [ "$repo_ready" != "true" ] || [ "$app_id_ready" != "true" ] || \
     [ "$installation_ready" != "true" ] || [ "$key_ready" -ne 1 ] || \
     [ "$required_checks_ready" -ne 1 ] || [ "$prompt_payload_ready" -ne 1 ]; then
    next="Run scripts/configure.sh on the VM to finish repo, App, and prompt config."
  elif [ "$dry_run_count" -eq 0 ]; then
    next="Run scripts/dry-run.sh and inspect the generated artifact before launching."
  elif [ "$cron_state" = "true" ]; then
    next="GoobReview appears launched; inspect logs under $state_dir."
  else
    next="Dry-run artifacts exist; run scripts/enable-cron.sh when you are ready to launch."
  fi
fi

cat <<EOF
GoobReview status
=================

Local checkout
--------------
repo root:              $REPO_ROOT
reviewer.env:          $(bool "$([ -f "$ENV_FILE" ] && printf 1 || printf 0)") ($ENV_FILE)
target repo set:        $repo_ready${repo:+ ($repo)}
App ID set:             $app_id_ready
installation ID set:    $installation_ready
private key present:    $(bool "$key_ready")${key_path:+ ($key_path)}
personality selected:   $(present "$personality_file")${personality_file:+ ($personality_file)}
required checks file:   $(bool "$required_checks_ready") ($required_checks)
prompt payload file:    $(bool "$prompt_payload_ready") ($prompt_payload)
state dir:              $state_dir
dry-run artifacts:      $dry_run_count
cron installed:         $cron_state

Next: $next

EOF

if [ -f "$GCLOUD_PREFLIGHT" ]; then
  bash "$GCLOUD_PREFLIGHT"
else
  ops_warn "Missing $GCLOUD_PREFLIGHT; skipping GCloud preflight."
fi
