#!/usr/bin/env bash
# Register a GitHub App for GoobReview via GitHub's Manifest Flow, then ship
# its private key to the VM and pre-populate reviewer.env with the App ID.
# Run from Cloud Shell (or anywhere with Node 20 + gcloud authed to the project).
#
# Usage:  scripts/register-app.sh [VM_NAME] [ZONE]
# Env:    GOOBREVIEW_GH_ORG=myorg  Register under an organization (defaults to personal account)
#         GOOBREVIEW_REGISTER_PORT=8080  Override server port (must match Web Preview)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VM_NAME="${1:-goobreview-1}"
ZONE="${2:-us-central1-a}"
PORT="${GOOBREVIEW_REGISTER_PORT:-8080}"
VM_KEY_PATH="${REVIEWER_APP_PRIVATE_KEY_PATH:-/var/lib/goobreview/example/app-key.pem}"
VM_ENV_PATH="${REVIEWER_ENV_FILE:-/opt/goobreview/example/config/reviewer.env}"
VM_EXAMPLE_ENV_PATH="/opt/goobreview/example/config/reviewer.env.example"

if ! command -v node >/dev/null 2>&1; then
  echo "node not found. In Cloud Shell, run 'sudo apt-get install -y nodejs' or use setup-vm.sh's install path." >&2
  exit 1
fi
if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud not found. Run from Cloud Shell or install the gcloud CLI." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found. In Cloud Shell, run 'sudo apt-get install -y jq'." >&2
  exit 1
fi

OUTPUT_DIR="$(mktemp -d -t goobreview-register.XXXXXX)"
chmod 700 "$OUTPUT_DIR"
trap 'rm -rf "$OUTPUT_DIR"' EXIT

cat <<EOF

============================================================
GoobReview: GitHub App registration

This will spin up a small local web server. You'll click two
buttons (one here, one on GitHub) and the App's private key
will be uploaded to $VM_NAME automatically.

Next steps once the server starts:

  1. Click the **Web Preview** button at the top-right of
     Cloud Shell (square icon with an arrow).
  2. Choose **Preview on port $PORT**. A new browser tab opens.
  3. Click "Create GoobReview App on GitHub →".
  4. Confirm on GitHub.

The server will exit on its own after registration completes.
============================================================

EOF

export GOOBREVIEW_REGISTER_OUTPUT="$OUTPUT_DIR"
export GOOBREVIEW_MANIFEST="$REPO_ROOT/config/app-manifest.json"
export GOOBREVIEW_REGISTER_PORT="$PORT"
# GOOBREVIEW_GH_ORG already exported by caller if set

node "$SCRIPT_DIR/lib/manifest-server.mjs"

if [ ! -f "$OUTPUT_DIR/app-key.pem" ] || [ ! -f "$OUTPUT_DIR/app.json" ]; then
  echo "Registration did not complete — no key found in $OUTPUT_DIR." >&2
  exit 1
fi

APP_ID="$(jq -r .id "$OUTPUT_DIR/app.json")"
APP_SLUG="$(jq -r .slug "$OUTPUT_DIR/app.json")"
APP_NAME="$(jq -r .name "$OUTPUT_DIR/app.json")"

echo
echo "App created: $APP_NAME (id=$APP_ID, slug=$APP_SLUG)"
echo "Uploading private key to $VM_NAME ($ZONE)..."

gcloud compute scp "$OUTPUT_DIR/app-key.pem" \
  "${VM_NAME}:${VM_KEY_PATH}" \
  --zone="$ZONE"

# Pre-populate reviewer.env with the App ID so configure.sh's prompt
# defaults to the right value. Idempotent: if reviewer.env doesn't exist
# yet we copy from the example; if REVIEWER_APP_ID is already set we replace.
gcloud compute ssh "$VM_NAME" --zone="$ZONE" --command="$(cat <<REMOTE
set -euo pipefail
chmod 600 '$VM_KEY_PATH'
if [ ! -f '$VM_ENV_PATH' ] && [ -f '$VM_EXAMPLE_ENV_PATH' ]; then
  cp '$VM_EXAMPLE_ENV_PATH' '$VM_ENV_PATH'
fi
if [ -f '$VM_ENV_PATH' ]; then
  if grep -qE '^REVIEWER_APP_ID=' '$VM_ENV_PATH'; then
    sed -i 's|^REVIEWER_APP_ID=.*|REVIEWER_APP_ID=$APP_ID|' '$VM_ENV_PATH'
  else
    printf 'REVIEWER_APP_ID=%s\n' '$APP_ID' >> '$VM_ENV_PATH'
  fi
fi
echo "[register-app] Key + App ID written on \$(hostname)."
REMOTE
)"

INSTALL_URL="https://github.com/apps/$APP_SLUG/installations/new"

cat <<EOF

============================================================
GitHub App registered and key uploaded.

  Name:       $APP_NAME
  App ID:     $APP_ID
  Slug:       $APP_SLUG
  Key on VM:  $VM_KEY_PATH

One step left: install the App on your target repo.

  $INSTALL_URL

After installing, finish setup on the VM:

  gcloud compute ssh $VM_NAME --zone=$ZONE
  cd /opt/goobreview/example
  gemini                # Google OAuth — sign in, trust this folder, /quit
  scripts/configure.sh  # App ID is pre-filled; auto-discovers installation ID
============================================================
EOF
