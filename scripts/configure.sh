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

choose_review_trigger() {
  local required_checks_file="$CONFIG_DIR/required-checks.json"
  local default_idx=0 pick existing_count

  if [ -f "$required_checks_file" ]; then
    existing_count="$(jq 'length' "$required_checks_file" 2>/dev/null || printf '')"
    if [ "$existing_count" = "0" ]; then
      default_idx=1
    fi
  fi

  log "When should GoobReview call the reviewer for a PR head?"
  log "  0) [$( [ "$default_idx" -eq 0 ] && printf '*' || printf ' ' )] after CI passes - wait for listed GitHub checks before calling agy"
  log "  1) [$( [ "$default_idx" -eq 1 ] && printf '*' || printf ' ' )] each ready head - call agy on every non-draft PR head without waiting for CI"
  pick="$(ask 'Pick review timing by number' "$default_idx")"
  case "$pick" in
    1) REVIEW_TRIGGER="when-ready" ;;
    *) REVIEW_TRIGGER="after-ci" ;;
  esac
}

apply_review_trigger() {
  local trigger="$1" required_checks_file="$CONFIG_DIR/required-checks.json"

  case "$trigger" in
    when-ready)
      printf '[]\n' > "$required_checks_file"
      log "Configured review timing: every ready PR head (required-check gate disabled)."
      ;;
    after-ci)
      log "Configured review timing: after listed CI checks pass."
      maybe_edit "$required_checks_file"
      if jq -e 'type == "array" and all(.[]; type == "string" and length > 0)' "$required_checks_file" >/dev/null; then
        if [ "$(jq 'length' "$required_checks_file")" -eq 0 ]; then
          ops_warn "required-checks.json is empty, so live reviews will run on every ready PR head until check names are added."
        fi
      else
        ops_die "Invalid required-check config in $required_checks_file; expected a JSON array of nonempty strings."
      fi
      ;;
    *)
      ops_die "Unknown review trigger: $trigger"
      ;;
  esac
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
ops_require_command openssl "Run scripts/setup-vm.sh first."
ops_require_command jq "Run scripts/setup-vm.sh first."
ops_require_command agy "Run scripts/setup-vm.sh first, then authenticate Antigravity CLI."
bash "$SCRIPT_DIR/preflight/checkout.sh" --strict --allow-setup-ref-mismatch

allow_missing_agy=0
if [ ! -d "$HOME/.gemini/antigravity-cli" ]; then
  log "Warning: Antigravity CLI auth state not found for $(whoami)."
  log "Without auth, dry runs and the reviewer daemon will fail. To authenticate:"
  log "  agy                   # sign in to Google in the browser"
  if ! confirm "Continue configuring anyway?"; then
    exit 1
  fi
  allow_missing_agy=1
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

current_posted_personality="$(ops_env_get "$ENV_FILE" REVIEWER_POSTED_PERSONALITY)"
if [ -z "$current_posted_personality" ]; then
  current_personality="$(ops_env_get "$ENV_FILE" REVIEWER_PERSONALITY_FILE)"
  case "$current_personality" in
    *angry.md) current_posted_personality="angry" ;;
    *linus.md) current_posted_personality="linus" ;;
    *) current_posted_personality="none" ;;
  esac
fi
case "$current_posted_personality" in
  angry) default_idx=2 ;;
  linus) default_idx=1 ;;
  *) default_idx=0 ;;
esac
log "Which review style should be posted to GitHub?"
log "  0) [$( [ "$default_idx" -eq 0 ] && printf '*' || printf ' ' )] none  - general-purpose review focus, neutral voice"
log "  1) [$( [ "$default_idx" -eq 1 ] && printf '*' || printf ' ' )] linus - deprecated legacy blunt style; prefer angry"
log "  2) [$( [ "$default_idx" -eq 2 ] && printf '*' || printf ' ' )] angry - blunt anger-prefill arm (supersedes linus)"
pick="$(ask 'Pick posted review style by number' "$default_idx")"
case "$pick" in
  2) posted_personality="angry" ;;
  1) posted_personality="linus" ;;
  *) posted_personality="none" ;;
esac

current_research_consent="$(ops_env_get "$ENV_FILE" REVIEWER_RESEARCH_CONSENT)"
[ -n "$current_research_consent" ] || current_research_consent=0
research_consent="$current_research_consent"
if confirm "Allow paired control/angry research artifact retention for public repositories?"; then
  research_consent=1
else
  research_consent=0
fi

REVIEW_TRIGGER=""
choose_review_trigger

inner_args=(
  --env-file "$ENV_FILE"
  --repo "$repo"
  --app-id "$app_id"
  --key-path "$key_path"
  --posted-personality "$posted_personality"
  --research-consent "$research_consent"
)
if [ -n "$installation_id" ]; then
  inner_args+=(--installation-id "$installation_id")
fi
if [ "$allow_missing_agy" -eq 1 ]; then
  inner_args+=(--allow-missing-agy)
fi

bash "$INNER_SH" "${inner_args[@]}"

apply_review_trigger "$REVIEW_TRIGGER"

if confirm "Open reviewer.env in $EDITOR_CMD to review other settings?"; then
  "$EDITOR_CMD" "$ENV_FILE"
fi

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
  #   - edit config/personalities/control.md or angry.md for voice/focus (linus.md is legacy)
  #   - edit REVIEWER_INCLUDE_* in config/reviewer.env for blinding policy
  #   - re-run scripts/dry-run.sh until the artifact looks right

  # When the dry run looks good, enable the scheduler:
  scripts/enable-cron.sh       # cron, fires every minute
  # or follow docs/daemon-runbook.md#systemd-timer for a systemd timer.
EOF
