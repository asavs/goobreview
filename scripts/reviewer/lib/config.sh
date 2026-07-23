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

validate_positive_uint_env() {
  local name="$1"
  local value="$2"

  validate_uint_env "$name" "$value"
  if [ "$value" -eq 0 ]; then
    fatal "invalid $name: $value"
  fi
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

# Resolve where write_dry_run_artifact should write, echoing the path on stdout.
# An explicit REVIEWER_DRY_RUN_OUT (DRY_RUN_OUT) wins verbatim and is honored
# exactly as before. Otherwise, under REVIEWER_DRY_RUN=1, default to a
# timestamped path under the state dir so a dry run -- whose whole purpose is an
# inspectable artifact -- never silently produces nothing; the timestamp keeps
# repeated runs from clobbering, and an overwrite is logged on the off chance the
# path already exists. Outside dry-run mode with no explicit path, stay a no-op
# (empty output): the daemon also calls write_dry_run_artifact on empty/invalid
# reviewer output in production, and that path must remain silent.
resolve_dry_run_out() {
  local num="$1" out
  out="${DRY_RUN_OUT:-}"
  if [ -z "$out" ]; then
    [ -n "${DRY_RUN:-}" ] || return 0
    out="$STATE_DIR/dry-run-$num-$(date -u +%Y%m%dT%H%M%SZ).txt"
    if [ -e "$out" ]; then
      log "Dry run: overwriting existing artifact at $out"
    fi
    log "Dry run: writing artifact to $out"
  fi
  printf '%s' "$out"
}

resolve_reviewer_personality_config() {
  local configured_posted="${REVIEWER_POSTED_PERSONALITY:-}"
  local configured_file="${REVIEWER_PERSONALITY_FILE:-}"

  case "$configured_posted" in
    '')
      if [ -n "$configured_file" ]; then
        POSTED_PERSONALITY="custom"
        PERSONALITY_FILE="$configured_file"
      else
        POSTED_PERSONALITY="none"
        PERSONALITY_FILE="$CONFIG_DIR/personalities/control.md"
      fi
      ;;
    none)
      POSTED_PERSONALITY="none"
      PERSONALITY_FILE="$CONFIG_DIR/personalities/control.md"
      ;;
    linus)
      POSTED_PERSONALITY="linus"
      PERSONALITY_FILE="$CONFIG_DIR/personalities/linus.md"
      ;;
    angry)
      POSTED_PERSONALITY="angry"
      PERSONALITY_FILE="$CONFIG_DIR/personalities/angry.md"
      ;;
    *)
      fatal "invalid REVIEWER_POSTED_PERSONALITY: $configured_posted (expected none, linus, or angry)"
      ;;
  esac

  : "$POSTED_PERSONALITY"
  case "$PERSONALITY_FILE" in
    ''|/*) ;;
    *) PERSONALITY_FILE="$REPO_DIR/$PERSONALITY_FILE" ;;
  esac
}

ensure_owner_private_dir() {
  local label="$1"
  local path="$2"
  local mode

  if [ -z "$path" ]; then
    fatal "missing $label directory path"
  fi

  mkdir -p "$path" || fatal "failed to create $label directory: $path"
  if [ ! -d "$path" ]; then
    fatal "$label path is not a directory: $path"
  fi
  if [ ! -O "$path" ]; then
    fatal "$label directory must be owned by the reviewer user: $path"
  fi
  chmod 700 "$path" 2>/dev/null || fatal "failed to set $label directory permissions to 0700: $path"

  mode=$(stat -c '%a' "$path" 2>/dev/null || true)
  case "$mode" in
    ''|*[!0-7]*)
      fatal "could not read $label directory permissions for $path"
      ;;
  esac
  if [ $((8#$mode & 077)) -ne 0 ]; then
    fatal "$label directory permissions must not grant group/other access: $path has mode $mode; run chmod 700"
  fi
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

resolve_reviewer_config_file() {
  local label="$1"
  local env_name="$2"
  local default_file="$3"
  local example_file="$4"
  local allow_example="$5"
  local configured="${!env_name:-}"

  if [ -n "$configured" ]; then
    if [ -f "$configured" ]; then
      printf '%s\n' "$configured"
      return 0
    fi
    fatal "$env_name points at '$configured' but that file does not exist. Run scripts/configure.sh or point $env_name at a valid $label file."
  fi

  if [ -f "$default_file" ]; then
    printf '%s\n' "$default_file"
    return 0
  fi

  if [ "$allow_example" = "1" ] && [ -f "$example_file" ]; then
    printf '%s\n' "$example_file"
    return 0
  fi

  fatal "missing $label config: $default_file. Run scripts/configure.sh to create it from $example_file, or set $env_name to a valid file."
}

validate_reviewer_config() {
  require jq

  if [ -z "$REPO" ]; then
    fatal "missing REVIEWER_REPO; set it to owner/repo"
  fi

  if [ -z "$PERSONALITY_FILE" ]; then
    fatal "REVIEWER_POSTED_PERSONALITY is required (set it to none, linus, or angry in reviewer.env)."
  fi
  if [ ! -f "$PERSONALITY_FILE" ]; then
    fatal "Resolved reviewer personality file '$PERSONALITY_FILE' does not exist."
  fi
  validate_uint_env REVIEWER_MAX_PRS "$MAX_PRS"
  validate_uint_env REVIEWER_MAX_ATTEMPTS "$MAX_ATTEMPTS"
  validate_uint_env REVIEWER_AGY_QUOTA_DEFAULT_BACKOFF "$AGY_QUOTA_DEFAULT_BACKOFF"
  validate_uint_env REVIEWER_AGY_QUOTA_BACKOFF_PADDING "$AGY_QUOTA_BACKOFF_PADDING"
  validate_uint_env REVIEWER_AGY_QUOTA_MAX_BACKOFF "$AGY_QUOTA_MAX_BACKOFF"
  validate_positive_uint_env REVIEWER_MAX_PROMPT_BYTES "$MAX_PROMPT_BYTES"
  validate_positive_uint_env REVIEWER_MAX_ARGV_PROMPT_BYTES "$MAX_ARGV_PROMPT_BYTES"
  validate_positive_uint_env REVIEWER_MAX_ARTIFACT_BYTES "$MAX_ARTIFACT_BYTES"
  validate_positive_uint_env REVIEWER_DIFF_MAX_BYTES "$DIFF_MAX_BYTES"
  validate_positive_uint_env REVIEWER_DIFF_FILE_MAX_BYTES "$DIFF_FILE_MAX_BYTES"
  validate_positive_uint_env REVIEWER_DESCRIPTION_MAX_BYTES "$DESCRIPTION_MAX_BYTES"
  validate_positive_uint_env REVIEWER_PREVIOUS_REVIEW_MAX_BYTES "$PREVIOUS_REVIEW_MAX_BYTES"
  validate_positive_uint_env REVIEWER_PRIOR_THREAD_SUMMARY_LIMIT "$PRIOR_THREAD_SUMMARY_LIMIT"
  validate_positive_uint_env REVIEWER_PRIOR_THREAD_BODY_MAX_BYTES "$PRIOR_THREAD_BODY_MAX_BYTES"
  validate_positive_uint_env REVIEWER_COMMIT_SUBJECTS_MAX "$COMMIT_SUBJECTS_MAX"
  validate_bool_env REVIEWER_INCLUDE_AUTHOR "$INCLUDE_AUTHOR"
  validate_bool_env REVIEWER_INCLUDE_DESCRIPTION "$INCLUDE_DESCRIPTION"
  validate_bool_env REVIEWER_INCLUDE_COMMIT_SUBJECTS "$INCLUDE_COMMIT_SUBJECTS"
  validate_bool_env REVIEWER_RESEARCH_CONSENT "${RESEARCH_CONSENT:-0}"
  validate_bool_env REVIEWER_RESEARCH_ALLOW_PRIVATE "${RESEARCH_ALLOW_PRIVATE:-0}"
  validate_bool_env REVIEWER_ALLOW_REQUIRED_CHECKS_OVERRIDE "$ALLOW_REQUIRED_CHECKS_OVERRIDE"
  validate_bool_env REVIEWER_AUTO_RESOLVE_BOT_THREADS "$AUTO_RESOLVE_BOT_THREADS"

  require base64
  require curl
  require flock
  require openssl
  require tar
  if [ -z "${RENDER_PROMPT_ONLY:-}" ]; then
    require agy
    require timeout
    require realpath
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
