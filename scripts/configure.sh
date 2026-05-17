#!/usr/bin/env bash
# Interactive on-VM setup for GoobReview's per-deployment config:
#   - the four gitignored files under config/
#   - GitHub App credentials (App ID, installation ID, private key)
#
# Run after setup-vm.sh has prepared the VM and after `gemini` has been
# authenticated interactively. The App itself must be registered and
# installed on the target repo first — see docs/github-app-setup.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
ENV_FILE="$CONFIG_DIR/reviewer.env"
EDITOR_CMD="${EDITOR:-nano}"
APP_TOKEN_SH="$SCRIPT_DIR/reviewer/get-installation-token.sh"

log() { printf '[configure] %s\n' "$*"; }

ask() {
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " reply
    printf '%s' "${reply:-$default}"
  else
    read -r -p "$prompt: " reply
    printf '%s' "$reply"
  fi
}

confirm() {
  local prompt="$1" reply
  read -r -p "$prompt [y/N] " reply
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

copy_if_missing() {
  local target="$1" example="$2"
  if [ -f "$target" ]; then
    log "$(basename "$target") already exists; leaving in place."
    return 0
  fi
  if [ ! -f "$example" ]; then
    log "Example $(basename "$example") missing; skipping $(basename "$target")."
    return 1
  fi
  cp "$example" "$target"
  log "Created $(basename "$target") from example."
  return 0
}

maybe_edit() {
  local file="$1"
  if confirm "Open $(basename "$file") in $EDITOR_CMD now?"; then
    "$EDITOR_CMD" "$file"
  fi
}

env_get() {
  local name="$1"
  awk -F= -v k="$name" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$ENV_FILE" 2>/dev/null || true
}

env_set() {
  local name="$1" value="$2" esc
  esc=$(printf '%s' "$value" | sed -e 's|[\\/&]|\\&|g')
  if grep -qE "^${name}=" "$ENV_FILE"; then
    sed -i.bak "s|^${name}=.*|${name}=${esc}|" "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
  else
    printf '%s=%s\n' "$name" "$value" >> "$ENV_FILE"
  fi
}

# --- Step 1: reviewer.env --------------------------------------------------
copy_if_missing "$ENV_FILE" "$CONFIG_DIR/reviewer.env.example" || exit 1

current_repo=$(env_get REVIEWER_REPO)
if [ -z "$current_repo" ] || [ "$current_repo" = "owner/repo" ]; then
  current_repo=$(ask 'Target GitHub repository (owner/repo)' "")
  if [ -z "$current_repo" ]; then
    log "REVIEWER_REPO is required; aborting."
    exit 1
  fi
  env_set REVIEWER_REPO "$current_repo"
fi

# Source for REVIEWER_STATE etc.
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# --- Step 2: GitHub App credentials ----------------------------------------
cat <<EOF

GoobReview authenticates as a GitHub App so its reviews come from a
bot identity (<app-slug>[bot]) that can APPROVE / REQUEST_CHANGES on
PRs. If you haven't registered an App yet, see docs/github-app-setup.md
and come back when you have:
  - The App ID (numeric)
  - The downloaded private key (.pem)
  - The App installed on $current_repo

EOF

current_app_id=$(env_get REVIEWER_APP_ID)
new_app_id=$(ask 'App ID (numeric)' "$current_app_id")
if [ -z "$new_app_id" ]; then
  log "App ID required; aborting."
  exit 1
fi
env_set REVIEWER_APP_ID "$new_app_id"
export REVIEWER_APP_ID="$new_app_id"

current_key_path=$(env_get REVIEWER_APP_PRIVATE_KEY_PATH)
[ -n "$current_key_path" ] || current_key_path="$REVIEWER_STATE/app-key.pem"
key_path=$(ask "Private key path (or 'paste' to paste contents now)" "$current_key_path")
if [ "$key_path" = "paste" ]; then
  key_path="$REVIEWER_STATE/app-key.pem"
  mkdir -p "$REVIEWER_STATE"
  log "Paste the PEM contents, then press Ctrl-D:"
  cat > "$key_path"
  chmod 600 "$key_path"
  log "Wrote $key_path (0600)."
fi
if [ ! -f "$key_path" ]; then
  log "Key file $key_path does not exist. scp it to the VM, then re-run."
  exit 1
fi
env_set REVIEWER_APP_PRIVATE_KEY_PATH "$key_path"
export REVIEWER_APP_PRIVATE_KEY_PATH="$key_path"

log "Looking up installation ID for $current_repo..."
if installation_id=$("$APP_TOKEN_SH" discover "$current_repo" 2>&1); then
  log "Found installation ID: $installation_id"
  env_set REVIEWER_APP_INSTALLATION_ID "$installation_id"
else
  log "Auto-discover failed: $installation_id"
  log "Make sure the App is installed on $current_repo, then either re-run this script"
  log "or set REVIEWER_APP_INSTALLATION_ID manually in $ENV_FILE."
  manual_id=$(ask 'Installation ID (or leave blank to fix later)' "")
  if [ -n "$manual_id" ]; then
    env_set REVIEWER_APP_INSTALLATION_ID "$manual_id"
  fi
fi

if confirm "Open reviewer.env in $EDITOR_CMD to review other settings?"; then
  "$EDITOR_CMD" "$ENV_FILE"
fi

# --- Step 3: other config files --------------------------------------------
# personality.md is listed first because it is the highest-value customization
# point: it defines the reviewer's role, focus areas, and severity policy.
for name in personality.md project-docs.txt head-context-paths.txt required-checks.json; do
  base="${name%.*}"
  ext="${name##*.}"
  example="$CONFIG_DIR/${base}.example.${ext}"
  if copy_if_missing "$CONFIG_DIR/$name" "$example"; then
    maybe_edit "$CONFIG_DIR/$name"
  fi
done

log "Done. Suggested next steps:"
cat <<EOF

  set -a; . config/reviewer.env; set +a

  # Optional: create the helper labels in the target repo
  scripts/reviewer/ensure-labels.sh

  # Dry run against one PR (does not post)
  REVIEWER_DRY_RUN=1 REVIEWER_MAX_PRS=1 scripts/reviewer/reviewer.sh
  tail -n 80 "\$REVIEWER_STATE/log.txt"

  # When the dry run looks good, enable the scheduler — see docs/quickstart.md step 8.
EOF
