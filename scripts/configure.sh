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
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/ops.sh"
OPS_LOG_PREFIX="configure"

log() { ops_log "$*"; }
ask() { ops_prompt "$@"; }
confirm() { ops_confirm "$@"; }
copy_if_missing() { ops_copy_if_missing "$@"; }

maybe_edit() {
  local file="$1"
  if confirm "Open $(basename "$file") in $EDITOR_CMD now?"; then
    "$EDITOR_CMD" "$file"
  fi
}

env_get() { ops_env_get "$ENV_FILE" "$@"; }
env_set() { ops_env_set "$ENV_FILE" "$@"; }

# --- Preflight: Gemini auth -----------------------------------------------
# The reviewer shells out to `gemini` headlessly, which requires that the
# current user has authenticated and trusted the checkout folder at least once.
# Both auth and trust state live under ~/.gemini, so missing dir = unauthed.
ops_require_command node "Run scripts/setup-vm.sh first."
ops_require_command gemini "Run scripts/setup-vm.sh first, then authenticate Gemini."
ops_require_executable "$APP_TOKEN_SH" "This checkout looks incomplete."
ops_require_file "$CONFIG_DIR/reviewer.env.example" "This checkout looks incomplete."
if [ ! -d "$HOME/.gemini" ]; then
  log "Warning: ~/.gemini not found — Gemini CLI does not look authenticated for $(whoami)."
  log "Without auth, dry runs and the reviewer daemon will fail. To authenticate:"
  log "  gemini                # sign in to Google in the browser, trust this folder, then /quit"
  if ! confirm "Continue configuring anyway?"; then
    exit 1
  fi
fi

# --- Step 1: reviewer.env --------------------------------------------------
copy_if_missing "$ENV_FILE" "$CONFIG_DIR/reviewer.env.example" || exit 1

current_repo=$(env_get REVIEWER_REPO)
if [ -z "$current_repo" ] || [ "$current_repo" = "owner/repo" ]; then
  current_repo=$(ask 'Target GitHub repository (owner/repo)' "")
  if [ -z "$current_repo" ]; then
    log "REVIEWER_REPO is required; aborting."
    exit 1
  fi
  ops_validate_owner_repo "$current_repo" REVIEWER_REPO
  env_set REVIEWER_REPO "$current_repo"
else
  ops_validate_owner_repo "$current_repo" REVIEWER_REPO
fi

# Source for REVIEWER_STATE etc.
ops_source_env "$ENV_FILE"
ops_require_nonempty "REVIEWER_STATE" "${REVIEWER_STATE:-}" "Set it in $ENV_FILE."

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
ops_validate_uint REVIEWER_APP_ID "$new_app_id"
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
if [ ! -s "$key_path" ]; then
  log "Key file $key_path is empty; aborting."
  exit 1
fi
chmod 600 "$key_path"
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

# --- Step 3: personality ---------------------------------------------------
# Pick a gallery entry and write its path into REVIEWER_PERSONALITY_FILE.
# To add a new personality, drop a .md file in config/personalities/.
PERSONALITY_GALLERY="$CONFIG_DIR/personalities"
gallery=()
if [ -d "$PERSONALITY_GALLERY" ]; then
  while IFS= read -r f; do
    gallery+=("$f")
  done < <(find "$PERSONALITY_GALLERY" -maxdepth 1 -type f -name '*.md' | sort)
fi
if [ ${#gallery[@]} -eq 0 ]; then
  log "No personalities found in $PERSONALITY_GALLERY; cannot continue."
  exit 1
fi

current_personality=$(env_get REVIEWER_PERSONALITY_FILE)
default_idx=0
log "Available personalities:"
for i in "${!gallery[@]}"; do
  rel="${gallery[$i]#$REPO_ROOT/}"
  marker=" "
  if [ "$rel" = "$current_personality" ]; then
    marker="*"
    default_idx="$i"
  fi
  log "  $i) [$marker] $(basename "${gallery[$i]}" .md)"
done
pick=$(ask 'Pick a personality by number' "$default_idx")
if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 0 ] && [ "$pick" -lt "${#gallery[@]}" ]; then
  chosen="${gallery[$pick]#$REPO_ROOT/}"
  env_set REVIEWER_PERSONALITY_FILE "$chosen"
  log "Set REVIEWER_PERSONALITY_FILE=$chosen"
else
  log "Invalid choice; leaving REVIEWER_PERSONALITY_FILE as-is."
fi

# --- Step 4: other config files --------------------------------------------
for name in project-docs.txt head-context-paths.txt required-checks.json; do
  base="${name%.*}"
  ext="${name##*.}"
  example="$CONFIG_DIR/${base}.example.${ext}"
  if copy_if_missing "$CONFIG_DIR/$name" "$example"; then
    maybe_edit "$CONFIG_DIR/$name"
  fi
done

# --- Step 5: optional label creation ---------------------------------------
if confirm "Create the helper labels (agent-reviewed, agent-requested-changes, needs-human-decision) on $current_repo now?"; then
  ops_require_command gh "GitHub CLI is needed for label creation; setup-vm.sh installs it."
  if token=$("$APP_TOKEN_SH" 2>/dev/null); then
    GH_TOKEN="$token" "$SCRIPT_DIR/reviewer/ensure-labels.sh" || \
      log "ensure-labels.sh failed; you can re-run it later: GH_TOKEN=\$($APP_TOKEN_SH) scripts/reviewer/ensure-labels.sh"
  else
    log "Could not mint a token to create labels. Make sure the App is installed on $current_repo, then run:"
    log "  GH_TOKEN=\$($APP_TOKEN_SH) scripts/reviewer/ensure-labels.sh"
  fi
fi

log "Done. Next steps:"
cat <<EOF

  # Dry run (no review posted)
  scripts/dry-run.sh           # picks the oldest unseen PR
  scripts/dry-run.sh 123       # or pick a specific PR number

  # When the dry run looks good, enable the scheduler:
  scripts/enable-cron.sh       # cron, fires every minute
  # or follow docs/daemon-runbook.md#systemd-timer for a systemd timer.
EOF
