#!/usr/bin/env bash
# Safely list likely existing GoobReview VMs across accessible GCP projects.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/ops.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/gcloud.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/vm.sh"
export OPS_LOG_PREFIX="preflight-vm-discovery"

report=0
name_pattern="${GOOBREVIEW_VM_DISCOVERY_PATTERN:-goobreview}"
max_projects="${GOOBREVIEW_VM_DISCOVERY_MAX_PROJECTS:-50}"
case "$name_pattern" in
  ''|*[!A-Za-z0-9_.-]*)
    ops_die "GOOBREVIEW_VM_DISCOVERY_PATTERN may only contain letters, numbers, dot, underscore, or dash."
    ;;
esac
ops_validate_uint GOOBREVIEW_VM_DISCOVERY_MAX_PROJECTS "$max_projects"

usage() {
  cat <<EOF
Usage: bash scripts/preflight/vm-discovery.sh [--report]

Lists likely GoobReview Compute Engine VMs across accessible projects. This is
read-only and uses ordinary gcloud compute instances list calls.

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

append_line() {
  local line="$1"
  if [ -n "$discovered" ]; then
    discovered="${discovered}
${line}"
  else
    discovered="$line"
  fi
}

gcloud_found=0
project_count=0
searched_count=0
truncated=false
discovered=""
recommendation="Run from Cloud Shell or install/authenticate gcloud."

if gcloud_command_found gcloud; then
  gcloud_found=1
  projects="$(gcloud_list_accessible_projects)"
  project_count="$(printf '%s\n' "$projects" | awk 'NF {count++} END {print count + 0}')"

  while IFS= read -r project; do
    [ -n "$project" ] || continue
    if [ "$searched_count" -ge "$max_projects" ]; then
      truncated=true
      break
    fi
    searched_count=$((searched_count + 1))

    rows="$(vm_list_matching_instances "$project" "$name_pattern")"
    while IFS=$'\t' read -r name zone machine status; do
      [ -n "$name" ] || continue
      append_line "$project	$zone	$name	$machine	$status"
    done <<< "$rows"
  done <<< "$projects"

  if [ -n "$discovered" ]; then
    recommendation="Use the project/zone/name above with scripts/status.sh, register-app.sh, or gcloud compute ssh."
  elif [ "$project_count" -eq 0 ]; then
    recommendation="No accessible GCP projects were found for this gcloud account."
  else
    recommendation="No likely GoobReview VMs found by name across searched projects."
  fi
  if [ "$truncated" = "true" ]; then
    recommendation="$recommendation Set GOOBREVIEW_VM_DISCOVERY_MAX_PROJECTS to search more than $max_projects projects."
  fi
fi

match_count="$(printf '%s\n' "$discovered" | awk 'NF {count++} END {print count + 0}')"
truncated_note=""
if [ "$truncated" = "true" ]; then
  truncated_note=" (limited by GOOBREVIEW_VM_DISCOVERY_MAX_PROJECTS=$max_projects)"
fi

if [ "$report" -eq 1 ]; then
  print_field "gcloud_found" "$(bool "$gcloud_found")"
  print_field "project_count" "$project_count"
  print_field "searched_project_count" "$searched_count"
  print_field "truncated" "$truncated"
  print_field "match_count" "$match_count"
  print_field "name_pattern" "$name_pattern"
  print_field "recommendation" "$recommendation"
  exit 0
fi

cat <<EOF
VM discovery
------------
gcloud installed:       $(bool "$gcloud_found")
accessible projects:    $project_count
searched projects:      $searched_count$truncated_note
name pattern:           $name_pattern
likely VMs found:       $match_count
EOF

if [ -n "$discovered" ]; then
  printf '\n%-28s %-18s %-24s %-14s %s\n' "PROJECT" "ZONE" "NAME" "MACHINE" "STATUS"
  printf '%s\n' "$discovered" | while IFS=$'\t' read -r project zone name machine status; do
    printf '%-28s %-18s %-24s %-14s %s\n' "$project" "$zone" "$name" "$machine" "$status"
  done
fi

cat <<EOF

Next: $recommendation
EOF
