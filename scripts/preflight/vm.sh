#!/usr/bin/env bash
# Report VM provisioning state from the Cloud Shell handoff and gcloud.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_FILE="$REPO_ROOT/.goobreview-cloud-shell.env"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/ops.sh"
export OPS_LOG_PREFIX="preflight-vm"

report=0

usage() {
  cat <<EOF
Usage: bash scripts/preflight/vm.sh [--report]

Checks the saved Cloud Shell VM handoff, VM existence, SSH reachability,
checkout presence, and key setup dependencies on the VM when reachable.

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

state_file_present=0
if [ -f "$STATE_FILE" ]; then
  state_file_present=1
  # shellcheck disable=SC1090
  . "$STATE_FILE"
fi

vm_name="${GOOBREVIEW_VM_NAME:-goobreview-1}"
zone="${GOOBREVIEW_ZONE:-us-central1-a}"
project="${GOOBREVIEW_GCP_PROJECT:-}"
repo_url="${GOOBREVIEW_REPO_URL:-}"

gcloud_found=0
vm_exists="unknown"
ssh_reachable="unknown"
checkout_present="unknown"
dependencies_present="unknown"
dependency_report=""

if command -v gcloud >/dev/null 2>&1; then
  gcloud_found=1
  if [ -z "$project" ]; then
    project="$(gcloud config get-value project 2>/dev/null || true)"
  fi

  if gcloud compute instances describe "$vm_name" --zone="$zone" >/dev/null 2>&1; then
    vm_exists="true"
  else
    vm_exists="false"
  fi

  if [ "$vm_exists" = "true" ] && command -v timeout >/dev/null 2>&1; then
    if timeout 15 gcloud compute ssh "$vm_name" --zone="$zone" --quiet --command='true' >/dev/null 2>&1; then
      ssh_reachable="true"
      # The command runs on the VM; keep $cmd expansion remote-side.
      # shellcheck disable=SC2016
      remote_probe="$(timeout 30 gcloud compute ssh "$vm_name" --zone="$zone" --quiet --command='
        set -eu
        if [ -d /opt/goobreview/example ]; then
          printf "checkout_present=true\n"
        else
          printf "checkout_present=false\n"
        fi
        for cmd in git jq curl wget node gh gemini; do
          if command -v "$cmd" >/dev/null 2>&1; then
            printf "%s=true\n" "$cmd"
          else
            printf "%s=false\n" "$cmd"
          fi
        done
      ' 2>/dev/null || true)"
      checkout_present="$(report_value checkout_present "$remote_probe")"
      missing=""
      for cmd in git jq curl wget node gh gemini; do
        if [ "$(report_value "$cmd" "$remote_probe")" != "true" ]; then
          missing="${missing}${missing:+,}$cmd"
        fi
      done
      if [ -z "$missing" ]; then
        dependencies_present="true"
        dependency_report="all present"
      else
        dependencies_present="false"
        dependency_report="missing: $missing"
      fi
    else
      ssh_reachable="false"
    fi
  fi
fi

recommendation="VM looks ready for GitHub App registration."
if [ "$gcloud_found" -ne 1 ]; then
  recommendation="Run from Cloud Shell or install/authenticate gcloud."
elif [ "$vm_exists" != "true" ]; then
  recommendation="Run bash scripts/bootstrap-gcp.sh to provision the VM."
elif [ "$ssh_reachable" = "false" ]; then
  recommendation="Wait for SSH or run: gcloud compute ssh $vm_name --zone=$zone"
elif [ "$checkout_present" = "false" ] || [ "$dependencies_present" = "false" ]; then
  recommendation="Re-run scripts/setup-vm.sh on the VM or rerun bootstrap-gcp.sh."
fi

if [ "$report" -eq 1 ]; then
  print_field "state_file" "$STATE_FILE"
  print_field "state_file_present" "$(bool "$state_file_present")"
  print_field "project" "$project"
  print_field "vm_name" "$vm_name"
  print_field "zone" "$zone"
  print_field "repo_url" "$repo_url"
  print_field "gcloud_found" "$(bool "$gcloud_found")"
  print_field "vm_exists" "$vm_exists"
  print_field "ssh_reachable" "$ssh_reachable"
  print_field "checkout_present" "$checkout_present"
  print_field "dependencies_present" "$dependencies_present"
  print_field "dependency_report" "$dependency_report"
  print_field "recommendation" "$recommendation"
  exit 0
fi

cat <<EOF
VM preflight
------------
handoff file:           $(bool "$state_file_present") ($STATE_FILE)
project:                ${project:-unknown}
VM name:                $vm_name
zone:                   $zone
source repo:            ${repo_url:-unknown}
gcloud installed:       $(bool "$gcloud_found")
VM exists:              $vm_exists
SSH reachable:          $ssh_reachable
checkout present:       $checkout_present
dependencies present:   $dependencies_present${dependency_report:+ ($dependency_report)}

Next: $recommendation
EOF
