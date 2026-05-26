#!/usr/bin/env bash
# Report GitHub App registration/configuration state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_FILE="$REPO_ROOT/.goobreview-cloud-shell.env"
ENV_FILE="${REVIEWER_ENV_FILE:-$REPO_ROOT/config/reviewer.env}"
VM_ENV_PATH="${GOOBREVIEW_VM_ENV_PATH:-/opt/goobreview/example/config/reviewer.env}"
DEFAULT_VM_KEY_PATH="/var/lib/goobreview/example/app-key.pem"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/ops.sh"
export OPS_LOG_PREFIX="preflight-app"

report=0

usage() {
  cat <<EOF
Usage: bash scripts/preflight/app.sh [--report]

Checks GitHub App ID, installation ID, and private-key presence locally and,
when Cloud Shell handoff + gcloud are available, on the VM.

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

report_value() {
  local key="$1" data="$2"
  printf '%s' "$data" | awk -F= -v k="$key" '$1 == k {print $2; found=1; exit} END {if (!found) print ""}'
}

file_mode() {
  local path="$1"
  if [ ! -f "$path" ]; then
    printf ''
    return
  fi
  if stat -c '%a' "$path" >/dev/null 2>&1; then
    stat -c '%a' "$path" 2>/dev/null
  elif stat -f '%Lp' "$path" >/dev/null 2>&1; then
    stat -f '%Lp' "$path" 2>/dev/null
  else
    printf 'unknown'
  fi
}

if [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  . "$STATE_FILE"
fi

vm_name="${GOOBREVIEW_VM_NAME:-goobreview-1}"
zone="${GOOBREVIEW_ZONE:-us-central1-a}"
repo=""
app_id=""
installation_id=""
key_path=""

if [ -f "$ENV_FILE" ]; then
  repo="$(ops_env_get "$ENV_FILE" REVIEWER_REPO)"
  app_id="$(ops_env_get "$ENV_FILE" REVIEWER_APP_ID)"
  installation_id="$(ops_env_get "$ENV_FILE" REVIEWER_APP_INSTALLATION_ID)"
  key_path="$(ops_env_get "$ENV_FILE" REVIEWER_APP_PRIVATE_KEY_PATH)"
fi

local_env_present=0
if [ -f "$ENV_FILE" ]; then
  local_env_present=1
fi
local_key_present=0
if [ -n "$key_path" ] && [ -s "$key_path" ]; then
  local_key_present=1
fi
local_key_mode="$(file_mode "$key_path")"

vm_env_present="unknown"
vm_app_id_set="unknown"
vm_key_path="$DEFAULT_VM_KEY_PATH"
vm_key_present="unknown"
vm_key_mode="unknown"

if command -v gcloud >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
  if timeout 15 gcloud compute instances describe "$vm_name" --zone="$zone" >/dev/null 2>&1 &&
     timeout 15 gcloud compute ssh "$vm_name" --zone="$zone" --quiet --command='true' >/dev/null 2>&1; then
    remote_probe="$(timeout 30 gcloud compute ssh "$vm_name" --zone="$zone" --quiet --command="
      set -eu
      env_file='$VM_ENV_PATH'
      default_key='$DEFAULT_VM_KEY_PATH'
      if [ -f \"\$env_file\" ]; then
        printf 'vm_env_present=true\n'
        app_id=\$(awk -F= '\$1==\"REVIEWER_APP_ID\" {sub(/^[^=]*=/,\"\"); print; exit}' \"\$env_file\" 2>/dev/null || true)
        key_path=\$(awk -F= '\$1==\"REVIEWER_APP_PRIVATE_KEY_PATH\" {sub(/^[^=]*=/,\"\"); print; exit}' \"\$env_file\" 2>/dev/null || true)
      else
        printf 'vm_env_present=false\n'
        app_id=''
        key_path=''
      fi
      [ -n \"\$key_path\" ] || key_path=\"\$default_key\"
      if [ -n \"\$app_id\" ]; then printf 'vm_app_id_set=true\n'; else printf 'vm_app_id_set=false\n'; fi
      printf 'vm_key_path=%s\n' \"\$key_path\"
      if [ -s \"\$key_path\" ]; then printf 'vm_key_present=true\n'; else printf 'vm_key_present=false\n'; fi
      if [ -f \"\$key_path\" ]; then
        if stat -c '%a' \"\$key_path\" >/dev/null 2>&1; then
          printf 'vm_key_mode=%s\n' \"\$(stat -c '%a' \"\$key_path\" 2>/dev/null)\"
        else
          printf 'vm_key_mode=unknown\n'
        fi
      else
        printf 'vm_key_mode=\n'
      fi
    " 2>/dev/null || true)"
    vm_env_present="$(report_value vm_env_present "$remote_probe")"
    vm_app_id_set="$(report_value vm_app_id_set "$remote_probe")"
    vm_key_path="$(report_value vm_key_path "$remote_probe")"
    vm_key_present="$(report_value vm_key_present "$remote_probe")"
    vm_key_mode="$(report_value vm_key_mode "$remote_probe")"
  fi
fi

repo_set="$(present "$repo" "owner/repo")"
app_id_set="$(present "$app_id")"
installation_set="$(present "$installation_id")"

recommendation="GitHub App config looks ready for configure/dry-run."
if [ "$app_id_set" != "true" ] && [ "$vm_app_id_set" != "true" ]; then
  recommendation="Run scripts/register-app.sh to create the App, upload the key, and write REVIEWER_APP_ID."
elif [ "$local_key_present" -ne 1 ] && [ "$vm_key_present" != "true" ]; then
  recommendation="Upload the GitHub App private key to the VM, usually via scripts/register-app.sh."
elif [ "$repo_set" != "true" ] || [ "$installation_set" != "true" ]; then
  recommendation="Install the App on the target repo, then run scripts/configure.sh to discover the installation ID."
elif [ "$local_key_mode" != "" ] && [ "$local_key_mode" != "600" ]; then
  recommendation="Run chmod 600 on REVIEWER_APP_PRIVATE_KEY_PATH."
elif [ "$vm_key_mode" != "unknown" ] && [ "$vm_key_mode" != "" ] && [ "$vm_key_mode" != "600" ]; then
  recommendation="Run chmod 600 on the VM App private key."
fi

if [ "$report" -eq 1 ]; then
  print_field "local_env_file" "$ENV_FILE"
  print_field "local_env_present" "$(bool "$local_env_present")"
  print_field "reviewer_repo" "$repo"
  print_field "reviewer_repo_set" "$repo_set"
  print_field "local_app_id_set" "$app_id_set"
  print_field "installation_id_set" "$installation_set"
  print_field "local_key_path" "$key_path"
  print_field "local_key_present" "$(bool "$local_key_present")"
  print_field "local_key_mode" "$local_key_mode"
  print_field "vm_name" "$vm_name"
  print_field "zone" "$zone"
  print_field "vm_env_file" "$VM_ENV_PATH"
  print_field "vm_env_present" "$vm_env_present"
  print_field "vm_app_id_set" "$vm_app_id_set"
  print_field "vm_key_path" "$vm_key_path"
  print_field "vm_key_present" "$vm_key_present"
  print_field "vm_key_mode" "$vm_key_mode"
  print_field "recommendation" "$recommendation"
  exit 0
fi

cat <<EOF
GitHub App preflight
--------------------
local reviewer.env:     $(bool "$local_env_present") ($ENV_FILE)
target repo set:        $repo_set${repo:+ ($repo)}
local App ID set:       $app_id_set
installation ID set:    $installation_set
local key present:      $(bool "$local_key_present")${key_path:+ ($key_path)}
local key mode:         ${local_key_mode:-unknown}
VM env present:         $vm_env_present ($VM_ENV_PATH)
VM App ID set:          $vm_app_id_set
VM key present:         $vm_key_present${vm_key_path:+ ($vm_key_path)}
VM key mode:            ${vm_key_mode:-unknown}

Next: $recommendation
EOF
