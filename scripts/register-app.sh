#!/usr/bin/env bash
# Drive GitHub App registration for GoobReview: spin up a local helper server
# that hands the user a pre-filled GitHub App-creation link, receives the
# resulting .pem + App ID, ships them to the VM, and pre-populates
# reviewer.env with the App ID. Run from Cloud Shell (or anywhere with Node 20
# + gcloud authed to the project).
#
# Usage:  scripts/register-app.sh [--repo OWNER/REPO] [VM_NAME] [ZONE]
# Env:    GOOBREVIEW_GH_ORG=myorg  Register under an organization (defaults to personal account)
#         GOOBREVIEW_REGISTER_PORT=8080  Override server port (must match Web Preview)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_FILE="$REPO_ROOT/.goobreview-cloud-shell.env"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/ops.sh"
export OPS_LOG_PREFIX="register-app"

if [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  . "$STATE_FILE"
fi

target_repo="${GOOBREVIEW_TARGET_REPO:-}"
port="${GOOBREVIEW_REGISTER_PORT:-}"
positionals=()

usage() {
  cat <<EOF
Usage: bash scripts/register-app.sh [options] [VM_NAME] [ZONE]

Options:
  --repo OWNER/REPO   Poll for the GitHub App installation on this repo and
                      pre-fill REVIEWER_REPO + REVIEWER_APP_INSTALLATION_ID.
  --port PORT         Use a specific local Web Preview port.
  -h, --help          Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      if [ "$#" -lt 2 ]; then
        ops_die "--repo requires OWNER/REPO."
      fi
      target_repo="$2"
      shift 2
      continue
      ;;
    --port)
      if [ "$#" -lt 2 ]; then
        ops_die "--port requires a numeric port."
      fi
      port="$2"
      shift 2
      continue
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        positionals+=("$1")
        shift
      done
      break
      ;;
    --*)
      ops_die "Unknown option: $1"
      ;;
    *)
      positionals+=("$1")
      ;;
  esac
  shift
done

if [ "${#positionals[@]}" -gt 2 ]; then
  ops_die "Too many positional arguments. Expected optional VM_NAME and ZONE."
fi

VM_NAME="${positionals[0]:-${GOOBREVIEW_VM_NAME:-goobreview-1}}"
ZONE="${positionals[1]:-${GOOBREVIEW_ZONE:-us-central1-a}}"
VM_KEY_PATH="${REVIEWER_APP_PRIVATE_KEY_PATH:-/var/lib/goobreview/example/app-key.pem}"
VM_ENV_PATH="${REVIEWER_ENV_FILE:-/opt/goobreview/example/config/reviewer.env}"
VM_EXAMPLE_ENV_PATH="/opt/goobreview/example/config/reviewer.env.example"

ops_require_command node "In Cloud Shell, run 'sudo apt-get install -y nodejs' or use setup-vm.sh's install path."
ops_require_command gcloud "Run from Cloud Shell or install the gcloud CLI."
ops_require_command jq "In Cloud Shell, run 'sudo apt-get install -y jq'."
if [ -n "$port" ]; then
  ops_validate_uint GOOBREVIEW_REGISTER_PORT "$port"
else
  port="$(node -e "const net=require('node:net');const s=net.createServer();s.listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close();});s.on('error',err=>{console.error(err.message);process.exit(1);});")"
  ops_validate_uint GOOBREVIEW_REGISTER_PORT "$port"
fi
PORT="$port"
ops_require_nonempty "VM name" "$VM_NAME"
ops_require_nonempty "Zone" "$ZONE"
if [ -n "$target_repo" ]; then
  ops_validate_owner_repo "$target_repo" "--repo"
fi
ops_require_file "$REPO_ROOT/config/app-manifest.json" "This checkout looks incomplete."

# Fail fast if the VM doesn't exist — better to know now than after the user
# creates a real GitHub App and uploads its key.
if ! gcloud compute instances describe "$VM_NAME" --zone="$ZONE" >/dev/null 2>&1; then
  cat >&2 <<EOF
VM '$VM_NAME' not found in zone '$ZONE'.

Provision it first:
  bash scripts/bootstrap-gcp.sh

Or pass the correct VM name and zone:
  bash scripts/register-app.sh <VM_NAME> <ZONE>
EOF
  exit 1
fi

OUTPUT_DIR="$(mktemp -d -t goobreview-register.XXXXXX)"
chmod 700 "$OUTPUT_DIR"
trap 'rm -rf "$OUTPUT_DIR"' EXIT

cat <<EOF

============================================================
GoobReview: GitHub App registration

This will spin up a small local web server, then walk you
through creating the App on GitHub and uploading its private
key. The key is shipped straight to $VM_NAME.

Target VM:
  Name:  $VM_NAME
  Zone:  $ZONE
$(if [ -n "$target_repo" ]; then cat <<TARGET

Target repo:
  $target_repo
TARGET
fi)

Next steps once the server starts:

  1. Click the **Web Preview** button at the top-right of
     Cloud Shell (square icon with an arrow).
  2. Choose **Preview on port $PORT**. A new browser tab opens.
  3. Follow the two-step page that loads:
       a. Click through to the pre-filled GitHub form and
          create the App, then generate a private key.
       b. Upload the .pem and paste the App ID.
$(if [ -n "$target_repo" ]; then cat <<TARGET
       c. Install the App on $target_repo; the page will detect the installation ID.
TARGET
fi)

The server will exit on its own after registration completes$(if [ -n "$target_repo" ]; then printf ' and the repo installation is detected'; fi).
============================================================

EOF

export GOOBREVIEW_REGISTER_OUTPUT="$OUTPUT_DIR"
export GOOBREVIEW_MANIFEST="$REPO_ROOT/config/app-manifest.json"
export GOOBREVIEW_REGISTER_PORT="$PORT"
export GOOBREVIEW_TARGET_REPO="$target_repo"
# GOOBREVIEW_GH_ORG already exported by caller if set

node "$SCRIPT_DIR/lib/register-server.mjs"

if [ ! -f "$OUTPUT_DIR/app-key.pem" ] || [ ! -f "$OUTPUT_DIR/app.json" ]; then
  echo "Registration did not complete — no key found in $OUTPUT_DIR." >&2
  exit 1
fi

APP_ID="$(jq -r .id "$OUTPUT_DIR/app.json")"
APP_SLUG="$(jq -r .slug "$OUTPUT_DIR/app.json")"
APP_NAME="$(jq -r .name "$OUTPUT_DIR/app.json")"
APP_INSTALLATION_ID="$(jq -r '.installation_id // ""' "$OUTPUT_DIR/app.json")"
ops_validate_uint "GitHub App ID" "$APP_ID"
ops_require_nonempty "GitHub App slug" "$APP_SLUG"
ops_require_nonempty "GitHub App name" "$APP_NAME"
if [ -n "$APP_INSTALLATION_ID" ]; then
  ops_validate_uint "GitHub App installation ID" "$APP_INSTALLATION_ID"
fi

echo
echo "App created: $APP_NAME (id=$APP_ID, slug=$APP_SLUG)"
echo "Uploading private key to $VM_NAME ($ZONE)..."

gcloud compute scp "$OUTPUT_DIR/app-key.pem" \
  "${VM_NAME}:${VM_KEY_PATH}" \
  --zone="$ZONE"

# Pre-populate reviewer.env with the App ID so configure.sh's prompt defaults
# to the right value. When --repo was supplied, also write the repo and
# discovered installation ID. Idempotent: existing keys are replaced.
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
  if [ -n '$target_repo' ]; then
    if grep -qE '^REVIEWER_REPO=' '$VM_ENV_PATH'; then
      sed -i 's|^REVIEWER_REPO=.*|REVIEWER_REPO=$target_repo|' '$VM_ENV_PATH'
    else
      printf 'REVIEWER_REPO=%s\n' '$target_repo' >> '$VM_ENV_PATH'
    fi
  fi
  if [ -n '$APP_INSTALLATION_ID' ]; then
    if grep -qE '^REVIEWER_APP_INSTALLATION_ID=' '$VM_ENV_PATH'; then
      sed -i 's|^REVIEWER_APP_INSTALLATION_ID=.*|REVIEWER_APP_INSTALLATION_ID=$APP_INSTALLATION_ID|' '$VM_ENV_PATH'
    else
      printf 'REVIEWER_APP_INSTALLATION_ID=%s\n' '$APP_INSTALLATION_ID' >> '$VM_ENV_PATH'
    fi
  fi
fi
echo "[register-app] Key + App config written on \$(hostname)."
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
$(if [ -n "$target_repo" ]; then cat <<TARGET
  Repo:       $target_repo
TARGET
fi)
$(if [ -n "$APP_INSTALLATION_ID" ]; then cat <<TARGET
  Install ID: $APP_INSTALLATION_ID
TARGET
fi)

$(if [ -n "$APP_INSTALLATION_ID" ]; then
  printf 'The App installation was detected and reviewer.env was pre-filled.'
else
  cat <<TARGET
One step left: install the App on your target repo.

  $INSTALL_URL
TARGET
fi)

After installing, finish setup on the VM:

  gcloud compute ssh $VM_NAME --zone=$ZONE
  cd /opt/goobreview/example
  gemini                # Google OAuth — sign in, trust this folder, /quit
  scripts/configure.sh  # App config is pre-filled when --repo detected the install

Check setup state from either checkout:

  bash scripts/status.sh
============================================================
EOF
