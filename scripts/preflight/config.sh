#!/usr/bin/env bash
# Report local GoobReview configuration readiness.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${REVIEWER_ENV_FILE:-$REPO_ROOT/config/reviewer.env}"
CONFIG_DIR="$REPO_ROOT/config"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/ops.sh"
export OPS_LOG_PREFIX="preflight-config"

report=0

usage() {
  cat <<EOF
Usage: bash scripts/preflight/config.sh [--report]

Checks reviewer.env, GitHub App credential fields, and local config files.

Options:
  --report   Emit machine-readable key=value output.
  -h, --help Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --report)
      report=1
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

shell_value() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

print_field() {
  local key="$1" value="$2"
  printf '%s=%s\n' "$key" "$(shell_value "$value")"
}

file_present=0
repo=""
app_id=""
installation_id=""
key_path=""
state_dir="/var/lib/goobreview/example"
posted_personality=""
research_consent="0"
research_allow_private="0"
personality_file=""
posted_personality_valid=1
required_checks="$CONFIG_DIR/required-checks.json"

if [ -f "$ENV_FILE" ]; then
  file_present=1
  repo="$(ops_env_get "$ENV_FILE" REVIEWER_REPO)"
  app_id="$(ops_env_get "$ENV_FILE" REVIEWER_APP_ID)"
  installation_id="$(ops_env_get "$ENV_FILE" REVIEWER_APP_INSTALLATION_ID)"
  key_path="$(ops_env_get "$ENV_FILE" REVIEWER_APP_PRIVATE_KEY_PATH)"
  state_from_env="$(ops_env_get "$ENV_FILE" REVIEWER_STATE)"
  posted_personality="$(ops_env_get "$ENV_FILE" REVIEWER_POSTED_PERSONALITY)"
  research_consent="$(ops_env_get "$ENV_FILE" REVIEWER_RESEARCH_CONSENT)"
  research_allow_private="$(ops_env_get "$ENV_FILE" REVIEWER_RESEARCH_ALLOW_PRIVATE)"
  personality_file="$(ops_env_get "$ENV_FILE" REVIEWER_PERSONALITY_FILE)"
  [ -z "$state_from_env" ] || state_dir="$state_from_env"
fi
[ -n "$posted_personality" ] || posted_personality="none"
[ -n "$research_consent" ] || research_consent="0"
[ -n "$research_allow_private" ] || research_allow_private="0"

repo_ready="$(present "$repo" "owner/repo")"
app_id_ready="$(present "$app_id")"
installation_ready="$(present "$installation_id")"
key_present=0
key_readable=0
if [ -n "$key_path" ] && [ -s "$key_path" ]; then
  key_present=1
fi
if [ -n "$key_path" ] && [ -r "$key_path" ]; then
  key_readable=1
fi

personality_ready=0
case "$posted_personality" in
  none)
    personality_path="$CONFIG_DIR/personalities/control.md"
    personality_file="config/personalities/control.md"
    ;;
  linus)
    personality_path="$CONFIG_DIR/personalities/linus.md"
    personality_file="config/personalities/linus.md"
    ;;
  *)
    posted_personality_valid=0
    personality_path=""
    ;;
esac
if [ -n "$personality_path" ] && [ -f "$personality_path" ]; then
  personality_ready=1
elif [ "$posted_personality_valid" -eq 1 ] && [ -n "$personality_file" ]; then
  case "$personality_file" in
    /*) personality_path="$personality_file" ;;
    *) personality_path="$REPO_ROOT/$personality_file" ;;
  esac
  if [ -f "$personality_path" ]; then
    personality_ready=1
  fi
else
  personality_path=""
fi

required_checks_ready=0
if [ -f "$required_checks" ]; then
  required_checks_ready=1
fi

agy_auth=0
if [ -d "$HOME/.gemini/antigravity-cli" ]; then
  agy_auth=1
fi

recommendation="Config looks ready for dry-run."
if [ "$file_present" -ne 1 ]; then
  recommendation="Run scripts/configure.sh on the VM to create config/reviewer.env."
elif [ "$repo_ready" != "true" ]; then
  recommendation="Set REVIEWER_REPO with scripts/configure.sh."
elif [ "$app_id_ready" != "true" ] || [ "$installation_ready" != "true" ]; then
  recommendation="Finish GitHub App registration/install, then re-run scripts/configure.sh."
elif [ "$key_present" -ne 1 ] || [ "$key_readable" -ne 1 ]; then
  recommendation="Place the GitHub App private key at REVIEWER_APP_PRIVATE_KEY_PATH with mode 0600."
elif [ "$posted_personality_valid" -ne 1 ]; then
  recommendation="Set REVIEWER_POSTED_PERSONALITY to none or linus."
elif [ "$personality_ready" -ne 1 ]; then
  recommendation="Select REVIEWER_POSTED_PERSONALITY=none or linus with scripts/configure.sh."
elif [ "$required_checks_ready" -ne 1 ]; then
  recommendation="Run scripts/configure.sh to create required-checks.json."
elif [ "$agy_auth" -ne 1 ]; then
  recommendation="Run agy once on the VM and complete Google sign-in."
fi

if [ "$report" -eq 1 ]; then
  print_field "env_file" "$ENV_FILE"
  print_field "env_file_present" "$(bool "$file_present")"
  print_field "reviewer_repo" "$repo"
  print_field "reviewer_repo_set" "$repo_ready"
  print_field "app_id_set" "$app_id_ready"
  print_field "installation_id_set" "$installation_ready"
  print_field "private_key_path" "$key_path"
  print_field "private_key_present" "$(bool "$key_present")"
  print_field "private_key_readable" "$(bool "$key_readable")"
  print_field "posted_personality" "$posted_personality"
  print_field "research_consent" "$research_consent"
  print_field "research_allow_private" "$research_allow_private"
  print_field "personality_file" "$personality_file"
  print_field "personality_file_present" "$(bool "$personality_ready")"
  print_field "required_checks_present" "$(bool "$required_checks_ready")"
  print_field "reviewer_state" "$state_dir"
  print_field "agy_auth_present" "$(bool "$agy_auth")"
  print_field "recommendation" "$recommendation"
  exit 0
fi

cat <<EOF
Config preflight
----------------
reviewer.env:           $(bool "$file_present") ($ENV_FILE)
target repo set:        $repo_ready${repo:+ ($repo)}
App ID set:             $app_id_ready
installation ID set:    $installation_ready
private key present:    $(bool "$key_present")${key_path:+ ($key_path)}
private key readable:   $(bool "$key_readable")
posted personality:     $posted_personality
research consent:       $(bool "$research_consent")
allow private capture:  $(bool "$research_allow_private")
personality valid:      $(bool "$personality_ready")${personality_file:+ ($personality_file)}
required checks file:   $(bool "$required_checks_ready") ($required_checks)
Antigravity auth dir:   $(bool "$agy_auth") ($HOME/.gemini/antigravity-cli)

Next: $recommendation
EOF
