#!/usr/bin/env bash
# Shared read-only Google Cloud probes for onboarding scripts.
# This file intentionally contains no mutating gcloud operations.

# Return success when the named command is available on PATH.
gcloud_command_found() {
  command -v "$1" >/dev/null 2>&1
}

# Print the active gcloud project, or gcloud's unset marker when configured.
gcloud_active_project() {
  gcloud config get-value project 2>/dev/null || true
}

# Print the active gcloud account, if one is selected.
gcloud_active_account() {
  gcloud auth list --filter='status:ACTIVE' --format='value(account)' 2>/dev/null | sed -n '1p' || true
}

# Return success when gcloud has an active account in the current Cloud SDK
# config. Project and billing discovery is misleading without this.
gcloud_auth_ready() {
  [ -n "$(gcloud_active_account)" ]
}

# Print the Cloud SDK config location relevant to gcloud auth state.
gcloud_config_location() {
  printf '%s' "${CLOUDSDK_CONFIG:-default}"
}

# Return success when a project value is usable for Compute Engine setup.
gcloud_project_is_usable() {
  local project="$1"
  case "$project" in
    ''|'(unset)'|cloudshell-*) return 1 ;;
    *) return 0 ;;
  esac
}

GCLOUD_ACCESSIBLE_PROJECTS_CACHE=""
GCLOUD_ACCESSIBLE_PROJECTS_CACHE_SET=0

# Print accessible project IDs, one per line. Cached for the current shell so
# billing probes and user-facing counts share the same project inventory.
gcloud_list_accessible_projects() {
  if [ "${GCLOUD_ACCESSIBLE_PROJECTS_CACHE_SET:-0}" -ne 1 ]; then
    GCLOUD_ACCESSIBLE_PROJECTS_CACHE="$(gcloud projects list --format='value(projectId)' 2>/dev/null || true)"
    GCLOUD_ACCESSIBLE_PROJECTS_CACHE_SET=1
  fi
  if [ -n "$GCLOUD_ACCESSIBLE_PROJECTS_CACHE" ]; then
    printf '%s\n' "$GCLOUD_ACCESSIBLE_PROJECTS_CACHE"
  fi
}

# Print directly visible open billing accounts as tab-separated name/displayName.
gcloud_list_direct_billing_accounts() {
  gcloud billing accounts list --filter='open=true' \
    --format='value(name,displayName)' 2>/dev/null || true
}

# Print billing accounts inferred from billing-enabled accessible projects as
# tab-separated account/display text. Account IDs are deduped before returning.
gcloud_list_project_linked_billing_accounts() {
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
  done < <(gcloud_list_accessible_projects)
}

# Print all usable billing accounts, preferring direct account rows and deduping
# by the account identifier so inferred rows do not double count direct rows.
gcloud_list_open_billing_accounts() {
  local direct linked

  direct=$(gcloud_list_direct_billing_accounts)
  linked=$(gcloud_list_project_linked_billing_accounts)
  printf '%s\n%s\n' "$direct" "$linked" | awk -F '\t' 'NF { key = $1; sub(/^billingAccounts\//, "", key); if (!seen[key]++) print }'
}

# Return success when the project exists and the current identity can describe it.
gcloud_project_exists() {
  gcloud projects describe "$1" --format='value(projectId)' >/dev/null 2>&1
}

# Return success when Cloud Billing is enabled for the project.
gcloud_project_billing_enabled() {
  local enabled
  enabled=$(gcloud billing projects describe "$1" --format='value(billingEnabled)' 2>/dev/null || true)
  case "$enabled" in
    True|true|TRUE) return 0 ;;
    *) return 1 ;;
  esac
}

# Print accessible project IDs that have Cloud Billing enabled.
gcloud_list_billing_enabled_projects() {
  local project_id

  while IFS= read -r project_id; do
    [ -n "$project_id" ] || continue
    if gcloud_project_billing_enabled "$project_id"; then
      printf '%s\n' "$project_id"
    fi
  done < <(gcloud_list_accessible_projects)
}

# Return success when Compute Engine API is enabled for the project.
gcloud_compute_api_enabled() {
  gcloud services list --enabled --project="$1" \
    --filter='config.name=compute.googleapis.com' \
    --format='value(config.name)' 2>/dev/null | grep -q '^compute.googleapis.com$'
}

# Return success when the project ID satisfies Google Cloud's basic syntax
# constraints. This does not check global availability or organization policy.
gcloud_project_id_valid() {
  local project_id="$1"
  [[ "$project_id" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
}
