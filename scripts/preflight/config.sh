#!/usr/bin/env bash
# Report local GoobReview configuration readiness.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_FILE="$REPO_ROOT/.goobreview-cloud-shell.env"
ENV_FILE="${REVIEWER_ENV_FILE:-$REPO_ROOT/config/reviewer.env}"
CONFIG_DIR="$REPO_ROOT/config"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/ops.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/vm.sh"
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
personality_file=""
posted_personality_valid=1
required_checks="$CONFIG_DIR/required-checks.json"
config_scope="local"

if [ -f "$ENV_FILE" ]; then
  file_present=1
  repo="$(ops_env_get "$ENV_FILE" REVIEWER_REPO)"
  app_id="$(ops_env_get "$ENV_FILE" REVIEWER_APP_ID)"
  installation_id="$(ops_env_get "$ENV_FILE" REVIEWER_APP_INSTALLATION_ID)"
  key_path="$(ops_env_get "$ENV_FILE" REVIEWER_APP_PRIVATE_KEY_PATH)"
  state_from_env="$(ops_env_get "$ENV_FILE" REVIEWER_STATE)"
  posted_personality="$(ops_env_get "$ENV_FILE" REVIEWER_POSTED_PERSONALITY)"
  research_consent="$(ops_env_get "$ENV_FILE" REVIEWER_RESEARCH_CONSENT)"
  personality_file="$(ops_env_get "$ENV_FILE" REVIEWER_PERSONALITY_FILE)"
  [ -z "$state_from_env" ] || state_dir="$state_from_env"
fi
[ -n "$posted_personality" ] || posted_personality="none"
[ -n "$research_consent" ] || research_consent="0"

if [ -f "$STATE_FILE" ] && command -v gcloud >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  vm_name="${GOOBREVIEW_VM_NAME:-goobreview-1}"
  zone="${GOOBREVIEW_ZONE:-us-central1-a}"
  vm_checkout="${GOOBREVIEW_VM_CHECKOUT:-/opt/goobreview/example}"
  vm_env_path="${GOOBREVIEW_VM_ENV_PATH:-$vm_checkout/config/reviewer.env}"
  if vm_instance_exists "$vm_name" "$zone" && vm_ssh_reachable "$vm_name" "$zone" 15; then
    remote_report="$(vm_remote_preflight_report "$vm_name" "$zone" "$vm_checkout" "$vm_env_path" config 30)"
    if [ -n "$remote_report" ]; then
      config_scope="vm"
      ENV_FILE="$(ops_report_value env_file "$remote_report")"
      file_present="$(ops_report_bool_int env_file_present "$remote_report")"
      repo="$(ops_report_value reviewer_repo "$remote_report")"
      repo_ready="$(ops_report_value reviewer_repo_set "$remote_report")"
      app_id_ready="$(ops_report_value app_id_set "$remote_report")"
      installation_ready="$(ops_report_value installation_id_set "$remote_report")"
      key_path="$(ops_report_value private_key_path "$remote_report")"
      key_present="$(ops_report_bool_int private_key_present "$remote_report")"
      key_readable="$(ops_report_bool_int private_key_readable "$remote_report")"
      posted_personality="$(ops_report_value posted_personality "$remote_report")"
      research_consent="$(ops_report_value research_consent "$remote_report")"
      personality_file="$(ops_report_value personality_file "$remote_report")"
      personality_ready="$(ops_report_bool_int personality_file_present "$remote_report")"
      required_checks_ready="$(ops_report_bool_int required_checks_present "$remote_report")"
      state_dir="$(ops_report_value reviewer_state "$remote_report")"
      agy_auth="$(ops_report_bool_int agy_auth_present "$remote_report")"
      recommendation="$(ops_report_value recommendation "$remote_report")"
      if [ "$report" -eq 1 ]; then
        print_field "config_scope" "$config_scope"
        print_field "vm_name" "$vm_name"
        print_field "zone" "$zone"
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
config source:          VM ($vm_name/$zone)
reviewer.env:           $(bool "$file_present") ($ENV_FILE)
target repo set:        $repo_ready${repo:+ ($repo)}
App ID set:             $app_id_ready
installation ID set:    $installation_ready
private key present:    $(bool "$key_present")${key_path:+ ($key_path)}
private key readable:   $(bool "$key_readable")
posted personality:     $posted_personality
research consent:       $(bool "$research_consent")
personality valid:      $(bool "$personality_ready")${personality_file:+ ($personality_file)}
required checks file:   $(bool "$required_checks_ready")
Antigravity auth dir:   $(bool "$agy_auth")

Next: $recommendation
EOF
      exit 0
    fi
  fi
fi

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
  angry)
    personality_path="$CONFIG_DIR/personalities/angry.md"
    personality_file="config/personalities/angry.md"
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
required_checks_valid=0
required_checks_count=""
review_trigger="unknown"
if [ -f "$required_checks" ]; then
  required_checks_ready=1
  if jq -e 'type == "array" and all(.[]; type == "string" and length > 0)' "$required_checks" >/dev/null 2>&1; then
    required_checks_valid=1
    required_checks_count="$(jq 'length' "$required_checks")"
    if [ "$required_checks_count" -eq 0 ]; then
      review_trigger="every ready PR head"
    else
      review_trigger="every ready PR head after required checks pass"
    fi
  fi
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
  recommendation="Set REVIEWER_POSTED_PERSONALITY to none, linus, or angry."
elif [ "$personality_ready" -ne 1 ]; then
  recommendation="Select REVIEWER_POSTED_PERSONALITY=none, linus, or angry with scripts/configure.sh."
elif [ "$required_checks_ready" -ne 1 ]; then
  recommendation="Run scripts/configure.sh to create required-checks.json."
elif [ "$required_checks_valid" -ne 1 ]; then
  recommendation="Fix required-checks.json; expected a JSON array of nonempty strings."
elif [ "$agy_auth" -ne 1 ]; then
  recommendation="Run agy once on the VM and complete Google sign-in."
fi

if [ "$report" -eq 1 ]; then
  print_field "config_scope" "$config_scope"
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
  print_field "personality_file" "$personality_file"
  print_field "personality_file_present" "$(bool "$personality_ready")"
  print_field "required_checks_present" "$(bool "$required_checks_ready")"
  print_field "required_checks_valid" "$(bool "$required_checks_valid")"
  print_field "required_checks_count" "$required_checks_count"
  print_field "review_trigger" "$review_trigger"
  print_field "reviewer_state" "$state_dir"
  print_field "agy_auth_present" "$(bool "$agy_auth")"
  print_field "recommendation" "$recommendation"
  exit 0
fi

cat <<EOF
Config preflight
----------------
config source:          local
reviewer.env:           $(bool "$file_present") ($ENV_FILE)
target repo set:        $repo_ready${repo:+ ($repo)}
App ID set:             $app_id_ready
installation ID set:    $installation_ready
private key present:    $(bool "$key_present")${key_path:+ ($key_path)}
private key readable:   $(bool "$key_readable")
posted personality:     $posted_personality
research consent:       $(bool "$research_consent")
personality valid:      $(bool "$personality_ready")${personality_file:+ ($personality_file)}
required checks file:   $(bool "$required_checks_ready") ($required_checks)
required checks valid:  $(bool "$required_checks_valid")${required_checks_count:+ ($required_checks_count)}
review trigger:         $review_trigger
Antigravity auth dir:   $(bool "$agy_auth") ($HOME/.gemini/antigravity-cli)

Next: $recommendation
EOF
