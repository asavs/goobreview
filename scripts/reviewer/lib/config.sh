#!/usr/bin/env bash
# Shared config and validation helpers for reviewer scripts.

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG_FILE"; }

require() {
  command -v "$1" >/dev/null || {
    log "missing: $1"
    exit 1
  }
}

validate_uint_env() {
  local name="$1"
  local value="$2"

  case "$value" in
    ''|*[!0-9]*)
      log "invalid $name: $value"
      exit 1
      ;;
  esac
}

validate_bool_env() {
  local name="$1"
  local value="$2"

  case "$value" in
    0|1)
      ;;
    *)
      log "invalid $name: $value"
      exit 1
      ;;
  esac
}

validate_reviewer_config() {
  if [ -z "$REPO" ]; then
    log "missing REVIEWER_REPO; set it to owner/repo"
    exit 1
  fi

  if [ -z "$PERSONALITY_FILE" ]; then
    log "REVIEWER_PERSONALITY_FILE is required (set it in reviewer.env). See config/personalities/ for options."
    exit 1
  fi
  if [ ! -f "$PERSONALITY_FILE" ]; then
    log "REVIEWER_PERSONALITY_FILE points at '$PERSONALITY_FILE' which does not exist."
    exit 1
  fi

  validate_uint_env REVIEWER_MAX_PRS "$MAX_PRS"
  validate_uint_env REVIEWER_GEMINI_QUOTA_DEFAULT_BACKOFF "$GEMINI_QUOTA_DEFAULT_BACKOFF"
  validate_uint_env REVIEWER_GEMINI_QUOTA_BACKOFF_PADDING "$GEMINI_QUOTA_BACKOFF_PADDING"
  validate_bool_env REVIEWER_ALLOW_REQUIRED_CHECKS_OVERRIDE "$ALLOW_REQUIRED_CHECKS_OVERRIDE"
  validate_bool_env REVIEWER_APPLY_LABELS "$APPLY_LABELS"

  require gh
  require flock
  require jq
  require node
  require tar
  if [ -z "${RENDER_PROMPT_ONLY:-}" ]; then
    require gemini
    require timeout
  fi

  local var
  for var in REVIEWER_APP_ID REVIEWER_APP_INSTALLATION_ID REVIEWER_APP_PRIVATE_KEY_PATH; do
    if [ -z "${!var:-}" ]; then
      log "missing required env: $var (see docs/github-app-setup.md)"
      exit 1
    fi
  done
}

load_effective_required_checks_json() {
  EFFECTIVE_REQUIRED_CHECKS_JSON=""
  if [ -n "${REVIEWER_REQUIRED_CHECKS_JSON:-}" ]; then
    if [ "$ALLOW_REQUIRED_CHECKS_OVERRIDE" = "1" ]; then
      if ! EFFECTIVE_REQUIRED_CHECKS_JSON=$(REQUIRED_CHECKS_JSON="$REVIEWER_REQUIRED_CHECKS_JSON" reviewer_required_checks_json "$REQUIRED_CHECKS_FILE"); then
        log "invalid REVIEWER_REQUIRED_CHECKS_JSON; expected a JSON array of nonempty strings"
        exit 1
      fi
    else
      log "Ignoring REVIEWER_REQUIRED_CHECKS_JSON because REVIEWER_ALLOW_REQUIRED_CHECKS_OVERRIDE is not 1"
    fi
  fi

  if [ -z "$EFFECTIVE_REQUIRED_CHECKS_JSON" ]; then
    if ! EFFECTIVE_REQUIRED_CHECKS_JSON=$(REQUIRED_CHECKS_JSON='' reviewer_required_checks_json "$REQUIRED_CHECKS_FILE"); then
      log "invalid required checks config in $REQUIRED_CHECKS_FILE; expected a JSON array of nonempty strings"
      exit 1
    fi
  fi

  printf '%s\n' "$EFFECTIVE_REQUIRED_CHECKS_JSON"
}
