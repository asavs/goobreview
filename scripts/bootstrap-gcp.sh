#!/usr/bin/env bash
# Provisions a Compute Engine VM for GoobReview and installs dependencies.
# Designed to run inside Google Cloud Shell (gcloud is preinstalled and pre-authed).
# Prompts for project, zone, and VM name. Everything else uses sensible defaults.
set -euo pipefail

DEFAULT_ZONE="us-central1-a"
DEFAULT_VM_NAME="goobreview-1"
DEFAULT_MACHINE_TYPE="e2-micro"
DEFAULT_IMAGE_FAMILY="ubuntu-2404-lts-amd64"
DEFAULT_IMAGE_PROJECT="ubuntu-os-cloud"
DEFAULT_DISK_SIZE="20GB"
UPSTREAM_REPO="asavschaeffer/goobreview"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_FILE="$REPO_ROOT/.goobreview-cloud-shell.env"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/ops.sh"
export OPS_LOG_PREFIX="bootstrap-gcp"

PROJECT_ARG=""
ZONE_ARG=""
VM_NAME_ARG=""
BILLING_ACCOUNT_ARG=""
ASSUME_YES=0

usage() {
  cat <<EOF
Usage: bash scripts/bootstrap-gcp.sh [options]

Provision the GoobReview VM and install VM-side dependencies.

Options:
  --project PROJECT_ID       GCP project to use or create.
  --zone ZONE                Compute Engine zone. Default: $DEFAULT_ZONE.
  --vm-name NAME             VM name. Default: $DEFAULT_VM_NAME.
  --billing-account ACCOUNT  Billing account ID/name to use when linking billing.
  --yes                      Accept script confirmations for non-interactive setup.
  -h, --help                 Show this help.

Examples:
  bash scripts/bootstrap-gcp.sh
  bash scripts/bootstrap-gcp.sh --project my-project --zone us-central1-a --vm-name goobreview-1 --yes
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      PROJECT_ARG="${2:-}"
      shift
      ;;
    --zone)
      ZONE_ARG="${2:-}"
      shift
      ;;
    --vm-name)
      VM_NAME_ARG="${2:-}"
      shift
      ;;
    --billing-account)
      BILLING_ACCOUNT_ARG="${2:-}"
      shift
      ;;
    --yes|-y)
      ASSUME_YES=1
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

bootstrap_confirm() {
  local question="$1"
  if [ "$ASSUME_YES" -eq 1 ]; then
    printf '[bootstrap-gcp] %s yes (--yes)\n' "$question" >&2
    return 0
  fi
  ops_confirm "$question"
}

detected_origin="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
detected_owner_repo="$(ops_to_owner_repo "$detected_origin")"
if [ -z "$detected_owner_repo" ]; then
  ops_warn "Could not detect a GitHub origin remote; using $UPSTREAM_REPO."
  detected_owner_repo="$UPSTREAM_REPO"
fi

# Where to clone on the VM, and where to fetch setup-vm.sh from. Env vars
# win; otherwise we derive from this checkout's origin so forks JustWork.
REPO_URL="${GOOBREVIEW_REPO_URL:-https://github.com/${detected_owner_repo}.git}"
SETUP_VM_URL="${GOOBREVIEW_SETUP_VM_URL:-https://raw.githubusercontent.com/${detected_owner_repo}/main/scripts/setup-vm.sh}"

ops_require_command gcloud "Run this in Google Cloud Shell, or install gcloud first."

print_billing_setup_help() {
  cat >&2 <<MSG
[bootstrap-gcp] No active billing accounts found on this Google account.

A billing account is required to enable Compute Engine, even though the
default VM (e2-micro in us-central1) is intended to stay within GCP's
always-free tier when you keep the defaults.

Create or attach a Cloud Billing account in the browser:
  https://console.cloud.google.com/billing

Cloud Shell has Gemini preinstalled. If you want a guided walkthrough, run:
  gemini
and ask:
  Help me create a Cloud Billing account for a small Compute Engine VM,
  then come back to this Cloud Shell command.

After billing is active, re-run:
  bash scripts/bootstrap-gcp.sh
MSG
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
  done < <(gcloud projects list --format='value(projectId)' 2>/dev/null || true)
}

list_open_billing_accounts() {
  local direct linked combined

  direct=$(list_direct_billing_accounts)
  linked=$(list_project_linked_billing_accounts)
  combined=$(printf '%s\n%s\n' "$direct" "$linked" | awk -F '\t' 'NF && !seen[$1]++')

  printf '%s' "$combined"
}

select_billing_account() {
  local billing_raw="$1"
  local count name display choice
  local -a accounts=() displays=()

  if [ -z "$billing_raw" ]; then
    print_billing_setup_help
    return 1
  fi

  if [ -n "$BILLING_ACCOUNT_ARG" ]; then
    while IFS=$'\t' read -r name display; do
      if [ "$BILLING_ACCOUNT_ARG" = "$name" ] || [ "$BILLING_ACCOUNT_ARG" = "${name#billingAccounts/}" ]; then
        printf '[bootstrap-gcp] Using billing account: %s (%s)\n' "${display:-$name}" "$name" >&2
        printf '%s' "$name"
        return 0
      fi
    done <<< "$billing_raw"
    ops_die "Billing account '$BILLING_ACCOUNT_ARG' was not found or is not open."
  fi

  count=$(printf '%s\n' "$billing_raw" | wc -l)
  if [ "$count" -eq 1 ]; then
    IFS=$'\t' read -r name display <<< "$billing_raw"
    printf '[bootstrap-gcp] Using billing account: %s (%s)\n' "${display:-$name}" "$name" >&2
    printf '%s' "$name"
    return 0
  fi

  printf 'Multiple active billing accounts:\n' >&2
  local i=1
  while IFS=$'\t' read -r name display; do
    printf '  [%d] %s (%s)\n' "$i" "${display:-$name}" "$name" >&2
    accounts+=("$name")
    displays+=("${display:-$name}")
    i=$((i + 1))
  done <<< "$billing_raw"

  if [ "$ASSUME_YES" -eq 1 ]; then
    ops_die "Multiple billing accounts found. Re-run with --billing-account ACCOUNT."
  fi

  choice=$(ops_prompt 'Pick number' '1')
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
    printf '[bootstrap-gcp] Invalid choice.\n' >&2
    return 1
  fi

  printf '[bootstrap-gcp] Using billing account: %s (%s)\n' \
    "${displays[$((choice - 1))]}" "${accounts[$((choice - 1))]}" >&2
  printf '%s' "${accounts[$((choice - 1))]}"
}

validate_project_id() {
  local project_id="$1"
  if ! [[ "$project_id" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
    cat >&2 <<MSG
[bootstrap-gcp] Project ID must be 6-30 chars, start with a lowercase
letter, contain only lowercase letters/digits/hyphens, and not end with
a hyphen. Got: $project_id
MSG
    return 1
  fi
}

create_project_with_billing() {
  local project_id="$1"
  local billing_raw billing_account

  validate_project_id "$project_id" || return 1

  printf '[bootstrap-gcp] Finding usable billing accounts...\n' >&2
  billing_raw=$(list_open_billing_accounts)
  billing_account=$(select_billing_account "$billing_raw") || return 1

  printf '[bootstrap-gcp] Creating project %s...\n' "$project_id" >&2
  if ! gcloud projects create "$project_id" --set-as-default >&2; then
    printf '[bootstrap-gcp] Project creation failed. The ID may be taken, or your org may restrict project creation.\n' >&2
    return 1
  fi

  printf '[bootstrap-gcp] Linking billing account...\n' >&2
  if ! gcloud billing projects link "$project_id" --billing-account="$billing_account" >&2; then
    cat >&2 <<MSG
[bootstrap-gcp] Failed to link billing to project '$project_id'.

The project was created but is not usable until billing is attached.
Try manually:
  gcloud billing projects link '$project_id' --billing-account='$billing_account'
or attach in the console: https://console.cloud.google.com/billing/linkedaccount?project=$project_id
MSG
    return 1
  fi

  printf '[bootstrap-gcp] Project %s ready.\n' "$project_id" >&2
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

link_project_billing_interactive() {
  local project_id="$1"
  local billing_raw billing_account

  if ! bootstrap_confirm "Link project '$project_id' to a Cloud Billing account now?"; then
    return 1
  fi

  printf '[bootstrap-gcp] Finding usable billing accounts...\n' >&2
  billing_raw=$(list_open_billing_accounts)
  billing_account=$(select_billing_account "$billing_raw") || return 1

  printf '[bootstrap-gcp] Linking billing account...\n' >&2
  gcloud billing projects link "$project_id" --billing-account="$billing_account" >&2
}

ensure_project_ready() {
  local project_id="$1"

  if ! project_exists "$project_id"; then
    cat >&2 <<EOF
[bootstrap-gcp] Project '$project_id' does not exist or you cannot access it.
EOF
    if bootstrap_confirm "Create project '$project_id' + link billing now?"; then
      create_project_with_billing "$project_id" || return 1
      return 0
    else
      return 1
    fi
  fi

  if project_billing_enabled "$project_id"; then
    return 0
  fi

  cat >&2 <<EOF
[bootstrap-gcp] Project '$project_id' is not linked to an active Cloud Billing account.
EOF
  link_project_billing_interactive "$project_id" || return 1
}

# Offer to create a new GCP project + link billing inline. Returns the new
# project ID on stdout; everything else goes to stderr. Returns nonzero if
# the user opts out, has no billing account, or any gcloud call fails, in
# which case the caller falls back to printing manual instructions.
create_project_interactive() {
  local project_id default_id

  if ! bootstrap_confirm 'Create a new GCP project + link a billing account now?'; then
    return 1
  fi

  default_id="goobreview-${RANDOM}${RANDOM}"
  if [ -n "$PROJECT_ARG" ]; then
    project_id="$PROJECT_ARG"
  else
    project_id=$(ops_prompt 'New project ID (6-30 lowercase chars/digits/hyphens, globally unique)' "$default_id")
  fi
  if [ -z "$project_id" ]; then
    printf '[bootstrap-gcp] Project ID is required.\n' >&2
    return 1
  fi

  create_project_with_billing "$project_id" || return 1
  printf '%s' "$project_id"
}

current_project="${PROJECT_ARG:-$(gcloud config get-value project 2>/dev/null || true)}"
case "$current_project" in
  ''|'(unset)'|cloudshell-*)
    cat >&2 <<EOF
[bootstrap-gcp] No usable GCP project is active.

Cloud Shell's session-default project ($current_project) can't run
Compute Engine. You need a normal GCP project with a billing account.

The default VM (e2-micro in us-central1) is on GCP's always-free tier,
so you won't be charged for the default setup.

EOF
    if [ -n "$PROJECT_ARG" ] && [ "$ASSUME_YES" -eq 1 ]; then
      if create_project_with_billing "$PROJECT_ARG"; then
        new_project="$PROJECT_ARG"
      else
        new_project=""
      fi
    elif new_project=$(create_project_interactive); then
      :
    fi
    if [ -n "${new_project:-}" ]; then
      current_project="$new_project"
      printf '\n[bootstrap-gcp] Continuing with project %s.\n\n' "$current_project" >&2
    else
      cat >&2 <<EOF

To finish setup manually:

  - If you already have a project:
      gcloud config set project YOUR_PROJECT_ID

  - If you need to create one:
      https://console.cloud.google.com/projectcreate
      https://console.cloud.google.com/billing

    You can also type 'gemini' in Cloud Shell and ask it to walk you
    through the Google Cloud billing/project console step.

Then re-run: bash scripts/bootstrap-gcp.sh
EOF
      exit 1
    fi
    ;;
esac

if [ -n "$PROJECT_ARG" ]; then
  project="$PROJECT_ARG"
else
  project="$(ops_prompt 'GCP project ID' "$current_project")"
fi
ops_require_nonempty "Project ID" "$project"

if ! ensure_project_ready "$project"; then
  cat >&2 <<EOF

[bootstrap-gcp] Cannot continue until '$project' exists and billing is enabled.
Fix the project/billing state, then re-run:
  bash scripts/bootstrap-gcp.sh
EOF
  exit 1
fi

if [ -n "$ZONE_ARG" ]; then
  zone="$ZONE_ARG"
else
  zone="$(ops_prompt 'Zone' "$DEFAULT_ZONE")"
fi
if [ -n "$VM_NAME_ARG" ]; then
  vm_name="$VM_NAME_ARG"
else
  vm_name="$(ops_prompt 'VM name' "$DEFAULT_VM_NAME")"
fi
ops_require_nonempty "Zone" "$zone"
ops_require_nonempty "VM name" "$vm_name"

cat <<EOF

About to create:
  Project:       $project
  Zone:          $zone
  VM name:       $vm_name
  Machine type:  $DEFAULT_MACHINE_TYPE
  Image:         $DEFAULT_IMAGE_FAMILY ($DEFAULT_IMAGE_PROJECT)
  Disk size:     $DEFAULT_DISK_SIZE
  Source repo:   $REPO_URL

EOF
bootstrap_confirm "Proceed?" || { echo "Aborted."; exit 1; }

gcloud config set project "$project" >/dev/null

cat > "$STATE_FILE" <<EOF
# Written by scripts/bootstrap-gcp.sh for the next Cloud Shell setup step.
# Safe to delete; scripts/register-app.sh also accepts VM name and zone args.
GOOBREVIEW_GCP_PROJECT=$(ops_shell_quote "$project")
GOOBREVIEW_VM_NAME=$(ops_shell_quote "$vm_name")
GOOBREVIEW_ZONE=$(ops_shell_quote "$zone")
GOOBREVIEW_REPO_URL=$(ops_shell_quote "$REPO_URL")
EOF
chmod 600 "$STATE_FILE" 2>/dev/null || true

# Fresh GCP projects don't have the Compute Engine API enabled. Without this,
# the next gcloud compute call will prompt interactively to enable it and
# hang silently when run non-interactively. Idempotent — already-enabled is a no-op.
if ! gcloud services list --enabled --filter='config.name=compute.googleapis.com' \
     --format='value(config.name)' 2>/dev/null | grep -q compute.googleapis.com; then
  echo "Enabling Compute Engine API (takes ~30s)..."
  gcloud services enable compute.googleapis.com
fi

if gcloud compute instances describe "$vm_name" --zone="$zone" >/dev/null 2>&1; then
  echo "VM '$vm_name' already exists in $zone. Skipping create."
else
  echo "Creating VM..."
  gcloud compute instances create "$vm_name" \
    --zone="$zone" \
    --machine-type="$DEFAULT_MACHINE_TYPE" \
    --boot-disk-size="$DEFAULT_DISK_SIZE" \
    --image-family="$DEFAULT_IMAGE_FAMILY" \
    --image-project="$DEFAULT_IMAGE_PROJECT"
fi

echo "Waiting for SSH..."
ssh_ready=0
for _ in $(seq 1 36); do
  if gcloud compute ssh "$vm_name" --zone="$zone" --command='true' --quiet 2>/dev/null; then
    ssh_ready=1
    break
  fi
  sleep 5
done
if [ "$ssh_ready" -ne 1 ]; then
  echo "VM is up but SSH didn't become reachable within ~3 minutes. Try manually:" >&2
  echo "  gcloud compute ssh $vm_name --zone=$zone" >&2
  exit 1
fi

echo "Running setup-vm.sh on the VM (cloning $REPO_URL)..."
gcloud compute ssh "$vm_name" --zone="$zone" \
  --command="curl -fsSL '$SETUP_VM_URL' | GOOBREVIEW_REPO_URL='$REPO_URL' bash"

cat <<EOF

============================================================
VM is provisioned and dependencies are installed.

To finish:

  1. Register the GitHub App and ship its key to the VM (still in Cloud Shell):
       bash scripts/register-app.sh

     Click the Web Preview button (port 8080); the page walks you through
     creating the App via a pre-filled GitHub form and uploading its key.

     This checkout saved your VM details in .goobreview-cloud-shell.env.
     If you run from another checkout, use:
       bash scripts/register-app.sh $vm_name $zone

     (See docs/github-app-setup.md for the full walkthrough.)

     You can check setup state any time with:
       bash scripts/status.sh

  2. SSH in, trust Gemini, and run configure.sh:
       gcloud compute ssh $vm_name --zone=$zone
       cd /opt/goobreview/example
       gemini                # Google OAuth; trust this folder, /quit
       scripts/configure.sh  # App ID is pre-filled; auto-discovers installation ID

Then continue with docs/quickstart.md from step 5 (dry run), then step 6 (scheduler).
============================================================
EOF
