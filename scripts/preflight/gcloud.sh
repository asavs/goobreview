#!/usr/bin/env bash
# Report Google Cloud readiness for the Cloud Shell provisioner.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/ops.sh"
export OPS_LOG_PREFIX="preflight-gcloud"

report=0

usage() {
  cat <<EOF
Usage: bash scripts/preflight/gcloud.sh [--report]

Checks the active gcloud project, billing state, Compute Engine API state,
and prints the recommended next setup action.

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

command_found() {
  command -v "$1" >/dev/null 2>&1
}

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

lines_to_csv() {
  local value="$1"

  printf '%s\n' "$value" | awk 'NF { if (out) out = out "," $0; else out = $0 } END { print out }'
}

has_count() {
  case "$1" in
    ''|unknown|0) return 1 ;;
    *) return 0 ;;
  esac
}

project_is_usable() {
  local project="$1"
  case "$project" in
    ''|'(unset)'|cloudshell-*) return 1 ;;
    *) return 0 ;;
  esac
}

ACCESSIBLE_PROJECTS_CACHE=""
ACCESSIBLE_PROJECTS_CACHE_SET=0

list_accessible_projects() {
  if [ "$ACCESSIBLE_PROJECTS_CACHE_SET" -ne 1 ]; then
    ACCESSIBLE_PROJECTS_CACHE="$(gcloud projects list --format='value(projectId)' 2>/dev/null || true)"
    ACCESSIBLE_PROJECTS_CACHE_SET=1
  fi
  if [ -n "$ACCESSIBLE_PROJECTS_CACHE" ]; then
    printf '%s\n' "$ACCESSIBLE_PROJECTS_CACHE"
  fi
}

list_direct_billing_accounts() {
  gcloud billing accounts list --filter='open=true' \
    --format='value(name,displayName)' 2>/dev/null || true
}

list_project_linked_billing_accounts() {
  local project_id info billing_account billing_enabled seen
  seen=""

  while IFS= read -r project_id; do
    [ -n "$project_id" ] || continue
    info=$(gcloud billing projects describe "$project_id" \
      --format='value(billingAccountName,billingEnabled)' 2>/dev/null || true)
    IFS=$'\t' read -r billing_account billing_enabled <<< "$info"
    case "$billing_enabled" in
      True|true|TRUE) ;;
      *) continue ;;
    esac
    billing_account="${billing_account#billingAccounts/}"
    [ -n "$billing_account" ] || continue
    case "$seen" in
      *"|$billing_account|"*) continue ;;
    esac
    seen="${seen}|$billing_account|"
    printf '%s\tlinked via %s\n' "$billing_account" "$project_id"
  done < <(list_accessible_projects)
}

list_open_billing_accounts() {
  local direct linked

  direct=$(list_direct_billing_accounts)
  linked=$(list_project_linked_billing_accounts)
  printf '%s\n%s\n' "$direct" "$linked" | awk -F '\t' 'NF && !seen[$1]++'
}

project_exists() {
  gcloud projects describe "$1" --format='value(projectId)' >/dev/null 2>&1
}

project_billing_enabled() {
  local enabled
  enabled=$(gcloud billing projects describe "$1" --format='value(billingEnabled)' 2>/dev/null || true)
  case "$enabled" in
    True|true|TRUE) return 0 ;;
    *) return 1 ;;
  esac
}

list_billing_enabled_projects() {
  local project_id

  while IFS= read -r project_id; do
    [ -n "$project_id" ] || continue
    if project_billing_enabled "$project_id"; then
      printf '%s\n' "$project_id"
    fi
  done < <(list_accessible_projects)
}

print_project_list() {
  local projects="$1" total="$2" max=10 count=0 project remaining

  while IFS= read -r project; do
    [ -n "$project" ] || continue
    count=$((count + 1))
    if [ "$count" -le "$max" ]; then
      printf '  - %s\n' "$project"
    fi
  done <<< "$projects"

  if [ "$total" -gt "$max" ]; then
    remaining=$((total - max))
    printf '  - ... %s more\n' "$remaining"
  fi
}

compute_api_enabled() {
  gcloud services list --enabled --project="$1" \
    --filter='config.name=compute.googleapis.com' \
    --format='value(config.name)' 2>/dev/null | grep -q '^compute.googleapis.com$'
}

gcloud_found=0
active_project=""
usable_project=0
project_exists_state="unknown"
billing_enabled_state="unknown"
compute_api_state="unknown"
billing_account_count="unknown"
project_count="unknown"
billing_enabled_project_count="unknown"
billing_enabled_project_hint="none"
first_billing_project=""
billing_enabled_projects=""
recommendation=""

if command_found gcloud; then
  gcloud_found=1
  active_project="$(gcloud config get-value project 2>/dev/null || true)"
  if project_is_usable "$active_project"; then
    usable_project=1
  fi

  billing_raw="$(list_open_billing_accounts)"
  if [ -n "$billing_raw" ]; then
    billing_account_count="$(printf '%s\n' "$billing_raw" | wc -l | tr -d ' ')"
  else
    billing_account_count="0"
  fi

  accessible_projects="$(list_accessible_projects)"
  if [ -n "$accessible_projects" ]; then
    project_count="$(printf '%s\n' "$accessible_projects" | wc -l | tr -d ' ')"
  else
    project_count="0"
  fi

  billing_enabled_projects="$(list_billing_enabled_projects)"
  if [ -n "$billing_enabled_projects" ]; then
    billing_enabled_project_count="$(printf '%s\n' "$billing_enabled_projects" | wc -l | tr -d ' ')"
    first_billing_project="$(printf '%s\n' "$billing_enabled_projects" | sed -n '1p')"
    case "$billing_enabled_project_count" in
      1) billing_enabled_project_hint="$first_billing_project" ;;
      *) billing_enabled_project_hint="$first_billing_project (+$((billing_enabled_project_count - 1)) more)" ;;
    esac
  else
    billing_enabled_project_count="0"
  fi

  if [ "$usable_project" -eq 1 ]; then
    if project_exists "$active_project"; then
      project_exists_state="true"
      if project_billing_enabled "$active_project"; then
        billing_enabled_state="true"
      else
        billing_enabled_state="false"
      fi
      if compute_api_enabled "$active_project"; then
        compute_api_state="true"
      else
        compute_api_state="false"
      fi
    else
      project_exists_state="false"
    fi
  fi
fi

if [ "$gcloud_found" -ne 1 ]; then
  recommendation="Run this from Google Cloud Shell or install/authenticate gcloud first."
elif [ "$usable_project" -ne 1 ]; then
  if [ "$billing_enabled_project_count" = "1" ]; then
    recommendation="Select billing-enabled project '$first_billing_project' with: gcloud config set project '$first_billing_project'; then run bash scripts/bootstrap-gcp.sh."
  elif has_count "$billing_enabled_project_count"; then
    recommendation="Available billing-enabled projects ($billing_enabled_project_hint). Select one with: gcloud config set project PROJECT_ID; then run bash scripts/bootstrap-gcp.sh."
  elif has_count "$billing_account_count"; then
    recommendation="No billing-enabled project was found. Run bash scripts/bootstrap-gcp.sh to create or select a project and link one of your billing accounts."
  else
    recommendation="No billing-enabled project or open billing account was found. Set up Cloud Billing, then run bash scripts/bootstrap-gcp.sh."
  fi
elif [ "$project_exists_state" = "false" ]; then
  recommendation="Create project '$active_project' or choose an accessible project."
elif [ "$billing_enabled_state" = "false" ]; then
  if has_count "$billing_enabled_project_count"; then
    recommendation="Active project '$active_project' has billing disabled. Switch to one listed below, or run bash scripts/bootstrap-gcp.sh to link billing."
  elif has_count "$billing_account_count"; then
    recommendation="Link project '$active_project' to one of your billing accounts; bootstrap-gcp.sh can do this."
  else
    recommendation="Set up Cloud Billing before using project '$active_project'."
  fi
elif [ "$compute_api_state" = "false" ]; then
  recommendation="Enable compute.googleapis.com; bootstrap-gcp.sh can do this before VM creation."
else
  recommendation="GCloud looks ready for VM provisioning."
fi

if [ "$report" -eq 1 ]; then
  print_field "gcloud_found" "$(bool "$gcloud_found")"
  print_field "active_project" "$active_project"
  print_field "usable_project" "$(bool "$usable_project")"
  print_field "project_exists" "$project_exists_state"
  print_field "billing_enabled" "$billing_enabled_state"
  print_field "compute_api_enabled" "$compute_api_state"
  print_field "billing_account_count" "$billing_account_count"
  print_field "accessible_project_count" "$project_count"
  print_field "billing_enabled_project_count" "$billing_enabled_project_count"
  print_field "billing_enabled_project_hint" "$billing_enabled_project_hint"
  print_field "billing_enabled_projects" "$(lines_to_csv "$billing_enabled_projects")"
  print_field "recommendation" "$recommendation"
  exit 0
fi

cat <<EOF
GCloud preflight
----------------
gcloud installed:        $(bool "$gcloud_found")
active project:          ${active_project:-none}
usable project:          $(bool "$usable_project")
project exists:          $project_exists_state
billing enabled:         $billing_enabled_state
Compute Engine API:      $compute_api_state
accessible projects:     $project_count
billing-ready projects:  $billing_enabled_project_count ($billing_enabled_project_hint)
open billing accounts:   $billing_account_count
EOF

if has_count "$billing_enabled_project_count"; then
  cat <<EOF

Billing-ready project IDs:
$(print_project_list "$billing_enabled_projects" "$billing_enabled_project_count")
EOF
fi

cat <<EOF
Next: $recommendation
EOF
