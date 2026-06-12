#!/usr/bin/env bash
# Interactive on-VM setup wrapper for GoobReview.
#
# This script prompts humans for setup choices, then delegates all deterministic
# writes/validation to scripts/configure-inner.sh. Agents can call the inner
# script directly with flags.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
ENV_FILE="${REVIEWER_ENV_FILE:-$CONFIG_DIR/reviewer.env}"
EDITOR_CMD="${EDITOR:-nano}"
INNER_SH="$SCRIPT_DIR/configure-inner.sh"
APP_TOKEN_SH="$SCRIPT_DIR/reviewer/get-installation-token.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/ops.sh"
export OPS_LOG_PREFIX="configure"

log() { ops_log "$*"; }
ask() { ops_prompt "$@"; }
confirm() { ops_confirm "$@"; }

maybe_edit() {
  local file="$1"
  if confirm "Open $(basename "$file") in $EDITOR_CMD now?"; then
    "$EDITOR_CMD" "$file"
  fi
}

discover_repo_from_app() {
  local discovered repo_from_app installation_from_app

  export REVIEWER_APP_ID="$app_id"
  export REVIEWER_APP_PRIVATE_KEY_PATH="$key_path"
  if [ -n "$installation_id" ]; then
    export REVIEWER_APP_INSTALLATION_ID="$installation_id"
  else
    unset REVIEWER_APP_INSTALLATION_ID
  fi

  if discovered="$("$APP_TOKEN_SH" discover-target 2>&1)"; then
    repo_from_app="$(printf '%s' "$discovered" | jq -r '.repo // empty')"
    installation_from_app="$(printf '%s' "$discovered" | jq -r '.installation_id // empty')"
    if [ -n "$repo_from_app" ]; then
      repo="$repo_from_app"
      if [ -z "$installation_id" ] && [ -n "$installation_from_app" ]; then
        installation_id="$installation_from_app"
      fi
      log "Detected target repo from GitHub App installation: $repo"
      if [ -n "$installation_from_app" ]; then
        log "Detected installation ID: $installation_from_app"
      fi
      return 0
    fi
  else
    log "Could not auto-detect target repo from the GitHub App installation: $discovered"
  fi

  return 1
}

personality_summary() {
  local file="$1" name
  name="$(basename "$file" .md)"
  case "$name" in
    control)
      printf 'general-purpose review focus, neutral voice'
      ;;
    linus)
      printf 'same review focus, blunt/profane when warranted'
      ;;
    *)
      awk '
        NF && $0 !~ /^#/ {
          line=$0
          sub(/^[[:space:]-]+/, "", line)
          if (length(line) > 90) line=substr(line, 1, 87) "..."
          print line
          found=1
          exit
        }
        END {
          if (!found) print "custom personality"
        }
      ' "$file"
      ;;
  esac
}

ops_require_file "$INNER_SH" "This checkout looks incomplete."
ops_require_executable "$APP_TOKEN_SH" "This checkout looks incomplete."
ops_require_file "$CONFIG_DIR/reviewer.env.example" "This checkout looks incomplete."
ops_require_command node "Run scripts/setup-vm.sh first."
ops_require_command jq "Run scripts/setup-vm.sh first."
ops_require_command gemini "Run scripts/setup-vm.sh first, then authenticate Gemini."
bash "$SCRIPT_DIR/preflight/checkout.sh" --strict --allow-setup-ref-mismatch

allow_missing_gemini=0
if [ ! -d "$HOME/.gemini" ]; then
  log "Warning: ~/.gemini not found - Gemini CLI does not look authenticated for $(whoami)."
  log "Without auth, dry runs and the reviewer daemon will fail. To authenticate:"
  log "  gemini                # sign in to Google in the browser, trust this folder, then /quit"
  if ! confirm "Continue configuring anyway?"; then
    exit 1
  fi
  allow_missing_gemini=1
fi

ops_copy_if_missing "$ENV_FILE" "$CONFIG_DIR/reviewer.env.example" || exit 1

ops_source_env "$ENV_FILE"
ops_require_nonempty "REVIEWER_STATE" "${REVIEWER_STATE:-}" "Set it in $ENV_FILE."

cat <<EOF

GoobReview authenticates as a GitHub App so its reviews come from a
bot identity (<app-slug>[bot]) that can APPROVE / REQUEST_CHANGES on
PRs. If you haven't registered an App yet, see docs/github-app-setup.md
and come back when you have:
  - The App ID (numeric)
  - The downloaded private key (.pem)
  - The App installed on your target repository

EOF

current_app_id="$(ops_env_get "$ENV_FILE" REVIEWER_APP_ID)"
app_id="$(ask 'App ID (numeric)' "$current_app_id")"
ops_require_nonempty "REVIEWER_APP_ID" "$app_id"
ops_validate_uint REVIEWER_APP_ID "$app_id"

current_key_path="$(ops_env_get "$ENV_FILE" REVIEWER_APP_PRIVATE_KEY_PATH)"
[ -n "$current_key_path" ] || current_key_path="$REVIEWER_STATE/app-key.pem"
key_path="$(ask "Private key path (or 'paste' to paste contents now)" "$current_key_path")"
if [ "$key_path" = "paste" ]; then
  key_path="$REVIEWER_STATE/app-key.pem"
  mkdir -p "$REVIEWER_STATE"
  log "Paste the PEM contents, then press Ctrl-D:"
  cat > "$key_path"
  chmod 600 "$key_path"
  log "Wrote $key_path (0600)."
fi

current_installation_id="$(ops_env_get "$ENV_FILE" REVIEWER_APP_INSTALLATION_ID)"
installation_id="$current_installation_id"
if [ -n "$current_installation_id" ]; then
  installation_id="$(ask 'Installation ID (blank to auto-discover)' "$current_installation_id")"
fi

current_repo="$(ops_env_get "$ENV_FILE" REVIEWER_REPO)"
if [ "$current_repo" = "owner/repo" ]; then
  current_repo=""
fi
repo="$current_repo"
if [ -z "$repo" ]; then
  discover_repo_from_app || true
fi
if [ -z "$repo" ]; then
  repo="$(ask 'Target GitHub repository (owner/repo)' "$current_repo")"
fi
ops_require_nonempty "REVIEWER_REPO" "$repo"
ops_validate_owner_repo "$repo" REVIEWER_REPO

PERSONALITY_GALLERY="$CONFIG_DIR/personalities"
gallery=()
if [ -d "$PERSONALITY_GALLERY" ]; then
  while IFS= read -r f; do
    gallery+=("$f")
  done < <(find "$PERSONALITY_GALLERY" -maxdepth 1 -type f -name '*.md' | sort)
fi
if [ "${#gallery[@]}" -eq 0 ]; then
  log "No personalities found in $PERSONALITY_GALLERY; cannot continue."
  exit 1
fi

current_personality="$(ops_env_get "$ENV_FILE" REVIEWER_PERSONALITY_FILE)"
default_idx=0
chosen="${current_personality:-config/personalities/control.md}"
log "Available personalities:"
for i in "${!gallery[@]}"; do
  rel="${gallery[$i]#$REPO_ROOT/}"
  marker=" "
  if [ "$rel" = "$current_personality" ]; then
    marker="*"
    default_idx="$i"
  fi
  log "  $i) [$marker] $(basename "${gallery[$i]}" .md) - $(personality_summary "${gallery[$i]}")"
done
pick="$(ask 'Pick a personality by number' "$default_idx")"
if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 0 ] && [ "$pick" -lt "${#gallery[@]}" ]; then
  chosen="${gallery[$pick]#$REPO_ROOT/}"
else
  log "Invalid choice; using existing/default personality: $chosen"
fi

cat <<EOF

Prompt payload profiles:
  1) lean     - compact metadata, CI one-liner, changed paths, guidance paths, diff
  2) minimal  - personality, diff, response format only
  3) full     - lean plus the verbose all-check summary
  4) custom   - copy prompt-payload.json and edit every segment manually

EOF
profile_pick="$(ask 'Pick a prompt payload profile' '1')"
case "$profile_pick" in
  1|lean) payload_profile="lean" ;;
  2|minimal) payload_profile="minimal" ;;
  3|full) payload_profile="full" ;;
  4|custom) payload_profile="custom" ;;
  *)
    log "Invalid profile choice; using lean."
    payload_profile="lean"
    ;;
esac

create_labels=0
if confirm "Create the helper labels (agent-reviewed, agent-requested-changes, needs-human-decision) on $repo now?"; then
  create_labels=1
fi

inner_args=(
  --env-file "$ENV_FILE"
  --repo "$repo"
  --app-id "$app_id"
  --key-path "$key_path"
  --personality "$chosen"
  --payload-profile "$payload_profile"
)
if [ -n "$installation_id" ]; then
  inner_args+=(--installation-id "$installation_id")
fi
if [ "$create_labels" -eq 1 ]; then
  inner_args+=(--create-labels)
fi
if [ "$allow_missing_gemini" -eq 1 ]; then
  inner_args+=(--allow-missing-gemini)
fi

bash "$INNER_SH" "${inner_args[@]}"

if confirm "Open reviewer.env in $EDITOR_CMD to review other settings?"; then
  "$EDITOR_CMD" "$ENV_FILE"
fi

maybe_edit "$CONFIG_DIR/required-checks.json"
maybe_edit "$CONFIG_DIR/prompt-payload.json"

log "Done. Next steps:"
cat <<EOF

  # Check setup state any time
  scripts/status.sh

  # Dry run (no review posted)
  scripts/dry-run.sh           # picks the oldest unseen PR
  scripts/dry-run.sh 123       # writes \$REVIEWER_STATE/dry-pr-123.txt

  # Tune before launch
  scripts/tune.sh             # edit active files, then optionally dry-run
  scripts/tune.sh 123         # tune against a specific PR
  #   - edit $chosen for voice/focus, if you picked a personality above
  #   - edit config/prompt-payload.json for prompt segments
  #   - re-run scripts/dry-run.sh until the artifact looks right

  # When the dry run looks good, enable the scheduler:
  scripts/enable-cron.sh       # cron, fires every minute
  # or follow docs/daemon-runbook.md#systemd-timer for a systemd timer.
EOF
