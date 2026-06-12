#!/usr/bin/env bash
# Non-interactive configuration core for GoobReview.
#
# This script never reads from stdin. Pass flags, or pre-populate reviewer.env.
# Humans should usually run scripts/configure.sh, which prompts and delegates here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
ENV_FILE="${REVIEWER_ENV_FILE:-$CONFIG_DIR/reviewer.env}"
APP_TOKEN_SH="$SCRIPT_DIR/reviewer/get-installation-token.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/ops.sh"
export OPS_LOG_PREFIX="configure-inner"

repo=""
app_id=""
installation_id=""
key_path=""
personality=""
payload_profile="lean"
create_labels=0
allow_missing_gemini=0

usage() {
  cat <<EOF
Usage: scripts/configure-inner.sh [options]

Non-interactive GoobReview configuration. Values omitted from flags may be
read from config/reviewer.env when present; otherwise required values fail.

Required before dry-run:
  --app-id ID
  --key-path PATH

Options:
  --repo OWNER/REPO           Target repository. If omitted, auto-detect when
                             the App installation exposes exactly one repo.
  --installation-id ID       Use an existing App installation ID. If omitted,
                             auto-discover from --repo.
  --personality PATH         Personality file, relative to repo root or absolute.
                             Default: config/personalities/control.md.
  --payload-profile NAME     lean, minimal, full, or custom. Default: lean.
  --create-labels           Create/update helper labels on the target repo.
  --allow-missing-gemini    Warn instead of failing when Gemini auth is missing.
  --env-file PATH           Override config/reviewer.env path.
  -h, --help                Show this help.
EOF
}

apply_prompt_payload_profile() {
  local file="$1"
  local profile="$2"
  local tmp

  tmp=$(mktemp)
  case "$profile" in
    minimal)
      jq '
        .profile = "minimal"
        | .segments.personality.enabled = true
        | .segments.pr_metadata.enabled = false
        | .segments.commit_subjects.enabled = false
        | .segments.ci_status.enabled = false
        | .segments.previous_bot_review.enabled = false
        | .segments.changed_paths.enabled = false
        | .segments.relevant_guidance.enabled = false
        | .segments.source_snapshot_hint.enabled = false
        | .segments.all_check_summary.enabled = false
        | .segments.diff.enabled = true
        | .segments.response_format.enabled = true
      ' "$file" >"$tmp"
      ;;
    lean)
      jq '
        .profile = "lean"
        | .segments.personality.enabled = true
        | .segments.pr_metadata.enabled = true
        | .segments.pr_metadata.include_description = true
        | .segments.commit_subjects.enabled = true
        | .segments.ci_status.enabled = true
        | .segments.ci_status.mode = "one_line"
        | .segments.previous_bot_review.enabled = true
        | .segments.changed_paths.enabled = true
        | .segments.relevant_guidance.enabled = true
        | .segments.source_snapshot_hint.enabled = true
        | .segments.all_check_summary.enabled = false
        | .segments.diff.enabled = true
        | .segments.response_format.enabled = true
      ' "$file" >"$tmp"
      ;;
    full)
      jq '
        .profile = "full"
        | .segments.personality.enabled = true
        | .segments.pr_metadata.enabled = true
        | .segments.pr_metadata.include_description = true
        | .segments.commit_subjects.enabled = true
        | .segments.ci_status.enabled = true
        | .segments.ci_status.mode = "one_line"
        | .segments.previous_bot_review.enabled = true
        | .segments.changed_paths.enabled = true
        | .segments.relevant_guidance.enabled = true
        | .segments.source_snapshot_hint.enabled = true
        | .segments.all_check_summary.enabled = true
        | .segments.diff.enabled = true
        | .segments.response_format.enabled = true
      ' "$file" >"$tmp"
      ;;
    custom)
      rm -f "$tmp"
      return 0
      ;;
    *)
      rm -f "$tmp"
      ops_die "Unknown prompt payload profile: $profile"
      ;;
  esac

  mv "$tmp" "$file"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      repo="${2:-}"
      shift
      ;;
    --app-id)
      app_id="${2:-}"
      shift
      ;;
    --installation-id)
      installation_id="${2:-}"
      shift
      ;;
    --key-path)
      key_path="${2:-}"
      shift
      ;;
    --personality)
      personality="${2:-}"
      shift
      ;;
    --payload-profile)
      payload_profile="${2:-}"
      shift
      ;;
    --create-labels)
      create_labels=1
      ;;
    --allow-missing-gemini)
      allow_missing_gemini=1
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      ops_die "Unknown option: $1"
      ;;
  esac
  shift
done

ops_require_command node "Run scripts/setup-vm.sh first."
ops_require_command jq "Run scripts/setup-vm.sh first."
ops_require_command gemini "Run scripts/setup-vm.sh first, then authenticate Gemini."
ops_require_executable "$APP_TOKEN_SH" "This checkout looks incomplete."
ops_require_file "$CONFIG_DIR/reviewer.env.example" "This checkout looks incomplete."
ops_require_file "$CONFIG_DIR/required-checks.example.json" "This checkout looks incomplete."
ops_require_file "$CONFIG_DIR/prompt-payload.example.json" "This checkout looks incomplete."

if [ ! -d "$HOME/.gemini" ]; then
  if [ "$allow_missing_gemini" -eq 1 ]; then
    ops_warn "$HOME/.gemini not found; dry runs will fail until Gemini is authenticated."
  else
    ops_die "$HOME/.gemini not found. Run 'gemini' once, sign in, trust this folder, then /quit. Use --allow-missing-gemini to configure anyway."
  fi
fi

mkdir -p "$(dirname "$ENV_FILE")"
ops_copy_if_missing "$ENV_FILE" "$CONFIG_DIR/reviewer.env.example" || exit 1

[ -n "$repo" ] || repo="$(ops_env_get "$ENV_FILE" REVIEWER_REPO)"
[ "$repo" != "owner/repo" ] || repo=""
[ -n "$app_id" ] || app_id="$(ops_env_get "$ENV_FILE" REVIEWER_APP_ID)"
[ -n "$installation_id" ] || installation_id="$(ops_env_get "$ENV_FILE" REVIEWER_APP_INSTALLATION_ID)"
[ -n "$key_path" ] || key_path="$(ops_env_get "$ENV_FILE" REVIEWER_APP_PRIVATE_KEY_PATH)"
[ -n "$personality" ] || personality="$(ops_env_get "$ENV_FILE" REVIEWER_PERSONALITY_FILE)"
[ -n "$personality" ] || personality="config/personalities/control.md"

ops_require_nonempty "REVIEWER_APP_ID" "$app_id" "Pass --app-id ID."
ops_validate_uint REVIEWER_APP_ID "$app_id"

ops_source_env "$ENV_FILE"
ops_require_nonempty "REVIEWER_STATE" "${REVIEWER_STATE:-}" "Set it in $ENV_FILE."

[ -n "$key_path" ] || key_path="$REVIEWER_STATE/app-key.pem"
if [ ! -f "$key_path" ]; then
  ops_die "Key file $key_path does not exist. Upload it first or pass --key-path."
fi
if [ ! -s "$key_path" ]; then
  ops_die "Key file $key_path is empty."
fi
chmod 600 "$key_path"
ops_env_set "$ENV_FILE" REVIEWER_APP_PRIVATE_KEY_PATH "$key_path"
export REVIEWER_APP_PRIVATE_KEY_PATH="$key_path"
export REVIEWER_APP_ID="$app_id"

if [ -z "$repo" ]; then
  if [ -n "$installation_id" ]; then
    export REVIEWER_APP_INSTALLATION_ID="$installation_id"
  else
    unset REVIEWER_APP_INSTALLATION_ID
  fi
  ops_log "Looking up target repo from GitHub App installation..."
  if discovered_target=$("$APP_TOKEN_SH" discover-target 2>&1); then
    repo="$(printf '%s' "$discovered_target" | jq -r '.repo // empty')"
    discovered_installation_id="$(printf '%s' "$discovered_target" | jq -r '.installation_id // empty')"
    if [ -z "$installation_id" ] && [ -n "$discovered_installation_id" ]; then
      installation_id="$discovered_installation_id"
    fi
    ops_log "Found target repo: $repo"
  else
    ops_die "Auto-discover target repo failed: $discovered_target. Pass --repo OWNER/REPO."
  fi
fi

ops_require_nonempty "REVIEWER_REPO" "$repo" "Pass --repo OWNER/REPO."
ops_validate_owner_repo "$repo" REVIEWER_REPO
ops_env_set "$ENV_FILE" REVIEWER_REPO "$repo"
ops_env_set "$ENV_FILE" REVIEWER_APP_ID "$app_id"

if [ -n "$installation_id" ]; then
  ops_validate_uint REVIEWER_APP_INSTALLATION_ID "$installation_id"
  ops_env_set "$ENV_FILE" REVIEWER_APP_INSTALLATION_ID "$installation_id"
else
  ops_log "Looking up installation ID for $repo..."
  if discovered_id=$("$APP_TOKEN_SH" discover "$repo" 2>&1); then
    ops_validate_uint REVIEWER_APP_INSTALLATION_ID "$discovered_id"
    ops_log "Found installation ID: $discovered_id"
    ops_env_set "$ENV_FILE" REVIEWER_APP_INSTALLATION_ID "$discovered_id"
  else
    ops_die "Auto-discover failed: $discovered_id"
  fi
fi

case "$personality" in
  /*) personality_path="$personality" ;;
  *) personality_path="$REPO_ROOT/$personality" ;;
esac
ops_require_file "$personality_path" "Pass --personality config/personalities/<name>.md."
case "$personality" in
  "$REPO_ROOT"/*) personality="${personality#"$REPO_ROOT"/}" ;;
esac
ops_env_set "$ENV_FILE" REVIEWER_PERSONALITY_FILE "$personality"

required_checks="$CONFIG_DIR/required-checks.json"
prompt_payload="$CONFIG_DIR/prompt-payload.json"
ops_copy_if_missing "$required_checks" "$CONFIG_DIR/required-checks.example.json" || exit 1
ops_copy_if_missing "$prompt_payload" "$CONFIG_DIR/prompt-payload.example.json" || exit 1
apply_prompt_payload_profile "$prompt_payload" "$payload_profile"

if [ "$create_labels" -eq 1 ]; then
  ops_require_command curl "curl is needed for App-token label creation; setup-vm.sh installs it."
  if token=$("$APP_TOKEN_SH" 2>/dev/null); then
    GH_TOKEN="$token" "$SCRIPT_DIR/reviewer/ensure-labels.sh"
  else
    ops_die "Could not mint a token to create labels. Make sure the App is installed on $repo."
  fi
fi

ops_log "Configuration written:"
cat <<EOF
  env:              $ENV_FILE
  repo:             $repo
  key path:         $key_path
  personality:      $personality
  payload profile:  $payload_profile

Next:
  scripts/status.sh
  scripts/dry-run.sh
  scripts/tune.sh
EOF
