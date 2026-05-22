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
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/ops.sh"
export OPS_LOG_PREFIX="bootstrap-gcp"

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

current_project="$(gcloud config get-value project 2>/dev/null || true)"
project="$(ops_prompt 'GCP project ID' "$current_project")"
ops_require_nonempty "Project ID" "$project"

zone="$(ops_prompt 'Zone' "$DEFAULT_ZONE")"
vm_name="$(ops_prompt 'VM name' "$DEFAULT_VM_NAME")"
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
ops_confirm "Proceed?" || { echo "Aborted."; exit 1; }

gcloud config set project "$project" >/dev/null

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
       bash scripts/register-app.sh $vm_name $zone

     Click the Web Preview button (port 8080); the page walks you through
     creating the App via a pre-filled GitHub form and uploading its key.

     (See docs/github-app-setup.md for the full walkthrough.)

  2. SSH in, trust Gemini, and run configure.sh:
       gcloud compute ssh $vm_name --zone=$zone
       cd /opt/goobreview/example
       gemini                # Google OAuth; trust this folder, /quit
       scripts/configure.sh  # App ID is pre-filled; auto-discovers installation ID

Then continue with docs/quickstart.md from step 5 (dry run), then step 6 (scheduler).
============================================================
EOF
