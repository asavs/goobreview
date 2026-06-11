#!/usr/bin/env bash
# Shared config and validation helpers for reviewer scripts.

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG_FILE"; }

fatal() {
  log "$*"
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null || {
    fatal "missing: $1"
  }
}

validate_uint_env() {
  local name="$1"
  local value="$2"

  case "$value" in
    ''|*[!0-9]*)
      fatal "invalid $name: $value"
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
      fatal "invalid $name: $value"
      ;;
  esac
}

validate_private_key_file() {
  local path="$1"
  local mode

  if [ ! -f "$path" ]; then
    fatal "private key not found: $path"
  fi
  if [ ! -s "$path" ] || [ ! -r "$path" ]; then
    fatal "private key is empty or unreadable: $path"
  fi
  if [ ! -O "$path" ]; then
    fatal "private key must be owned by the reviewer user: $path"
  fi

  mode=$(stat -c '%a' "$path" 2>/dev/null || true)
  case "$mode" in
    ''|*[!0-7]*)
      fatal "could not read private key permissions for $path"
      ;;
  esac
  if [ $((8#$mode & 077)) -ne 0 ]; then
    fatal "private key permissions must not grant group/other access: $path has mode $mode; run chmod 600"
  fi
}

validate_reviewer_config() {
  require jq

  if [ -z "$REPO" ]; then
    fatal "missing REVIEWER_REPO; set it to owner/repo"
  fi

  if [ -z "$PERSONALITY_FILE" ]; then
    fatal "REVIEWER_PERSONALITY_FILE is required (set it in reviewer.env). See config/personalities/ for options."
  fi
  if [ ! -f "$PERSONALITY_FILE" ]; then
    fatal "REVIEWER_PERSONALITY_FILE points at '$PERSONALITY_FILE' which does not exist."
  fi
  if [ -z "${PROMPT_PAYLOAD_FILE:-}" ] || [ ! -f "$PROMPT_PAYLOAD_FILE" ]; then
    fatal "missing prompt payload config: ${PROMPT_PAYLOAD_FILE:-unset}"
  fi
  if ! jq -e '.segments | type == "object"' "$PROMPT_PAYLOAD_FILE" >/dev/null 2>&1; then
    fatal "invalid prompt payload config in $PROMPT_PAYLOAD_FILE"
  fi

  validate_uint_env REVIEWER_MAX_PRS "$MAX_PRS"
  validate_uint_env REVIEWER_GEMINI_QUOTA_DEFAULT_BACKOFF "$GEMINI_QUOTA_DEFAULT_BACKOFF"
  validate_uint_env REVIEWER_GEMINI_QUOTA_BACKOFF_PADDING "$GEMINI_QUOTA_BACKOFF_PADDING"
  validate_uint_env REVIEWER_INVALID_VERDICT_MAX_ATTEMPTS "$INVALID_VERDICT_MAX_ATTEMPTS"
  validate_bool_env REVIEWER_ALLOW_REQUIRED_CHECKS_OVERRIDE "$ALLOW_REQUIRED_CHECKS_OVERRIDE"
  validate_bool_env REVIEWER_APPLY_LABELS "$APPLY_LABELS"

  require curl
  require flock
  require node
  require tar
  if [ -z "${DRY_RUN:-}" ] && [ -z "${RENDER_PROMPT_ONLY:-}" ]; then
    require gh
  fi
  if [ -z "${RENDER_PROMPT_ONLY:-}" ]; then
    require gemini
    require timeout
  fi

  local var
  for var in REVIEWER_APP_ID REVIEWER_APP_INSTALLATION_ID REVIEWER_APP_PRIVATE_KEY_PATH; do
    if [ -z "${!var:-}" ]; then
      fatal "missing required env: $var (see docs/github-app-setup.md)"
    fi
  done
  validate_private_key_file "$REVIEWER_APP_PRIVATE_KEY_PATH"
}

load_effective_required_checks_json() {
  EFFECTIVE_REQUIRED_CHECKS_JSON=""
  if [ -n "${REVIEWER_REQUIRED_CHECKS_JSON:-}" ]; then
    if [ "$ALLOW_REQUIRED_CHECKS_OVERRIDE" = "1" ]; then
      if ! EFFECTIVE_REQUIRED_CHECKS_JSON=$(REQUIRED_CHECKS_JSON="$REVIEWER_REQUIRED_CHECKS_JSON" reviewer_required_checks_json "$REQUIRED_CHECKS_FILE"); then
        fatal "invalid REVIEWER_REQUIRED_CHECKS_JSON; expected a JSON array of nonempty strings"
      fi
    else
      log "Ignoring REVIEWER_REQUIRED_CHECKS_JSON because REVIEWER_ALLOW_REQUIRED_CHECKS_OVERRIDE is not 1"
    fi
  fi

  if [ -z "$EFFECTIVE_REQUIRED_CHECKS_JSON" ]; then
    if ! EFFECTIVE_REQUIRED_CHECKS_JSON=$(REQUIRED_CHECKS_JSON='' reviewer_required_checks_json "$REQUIRED_CHECKS_FILE"); then
      fatal "invalid required checks config in $REQUIRED_CHECKS_FILE; expected a JSON array of nonempty strings"
    fi
  fi

  printf '%s\n' "$EFFECTIVE_REQUIRED_CHECKS_JSON"
}
