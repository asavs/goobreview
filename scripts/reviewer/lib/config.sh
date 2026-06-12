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

validate_prompt_payload_config() {
  local file="$1"
  local example="${EXAMPLE_PROMPT_PAYLOAD_FILE:-config/prompt-payload.example.json}"
  local err_file

  err_file=$(mktemp)
  if ! jq -e '
    def fail($msg): error($msg + " (see " + $example + ")");
    def obj($path):
      getpath($path) as $v
      | if ($v | type) == "object" then empty
        else fail(($path | map(tostring) | join(".")) + " must be an object")
        end;
    def optional_bool($path):
      getpath($path) as $v
      | if $v == null or ($v | type) == "boolean" then empty
        else fail(($path | map(tostring) | join(".")) + " must be a boolean")
        end;
    def optional_string_enum($path; $allowed):
      getpath($path) as $v
      | if $v == null or (($v | type) == "string" and ($allowed | index($v))) then empty
        else fail(($path | map(tostring) | join(".")) + " must be one of: " + ($allowed | join(", ")))
        end;
    def optional_uint($path; $min; $max):
      getpath($path) as $v
      | if $v == null or (($v | type) == "number" and ($v % 1 == 0) and $v >= $min and $v <= $max) then empty
        else fail(($path | map(tostring) | join(".")) + " must be an integer from " + ($min | tostring) + " to " + ($max | tostring))
        end;
    def safe_path($label):
      if (type != "string") then fail($label + " must be a string")
      elif . == "" then fail($label + " must not be empty")
      elif startswith("/") then fail($label + " must be relative")
      elif startswith("\\") then fail($label + " must be relative")
      elif test("^[A-Za-z]:") then fail($label + " must be relative")
      elif (split("/") | any(. == "..")) then fail($label + " must not contain parent traversal")
      elif contains("\u0000") then fail($label + " must not contain NUL")
      else empty
      end;
    def string_array($path):
      getpath($path) as $v
      | if ($v | type) == "array" and ($v | length) > 0 and all($v[]; type == "string" and . != "") then empty
        else fail(($path | map(tostring) | join(".")) + " must be an array of nonempty strings")
        end;

    . as $root
    | if type != "object" then fail("prompt payload root must be an object") else empty end,
      obj(["segments"]),
      (
        (.segments | keys_unsorted[]) as $name
        | if ["personality","pr_metadata","ci_status","changed_paths","relevant_guidance","source_snapshot_hint","all_check_summary","full_file_tree","selected_file_contents","diff","response_format"] | index($name)
          then empty
          else fail("segments." + $name + " is not a known prompt segment")
          end
      ),
      (
        .segments | to_entries[]
        | if (.value | type) == "object" then empty
          else fail("segments." + .key + " must be an object")
          end
        | if (.value.enabled | type) == "boolean" then empty
          else fail("segments." + .key + ".enabled must be a boolean")
          end
      ),
      (["include_title","include_author","include_url","include_base_branch","include_head_branch","include_head_sha","include_description"][] as $key | optional_bool(["segments","pr_metadata",$key])),
      optional_string_enum(["segments","ci_status","mode"]; ["one_line","all_check_summary"]),
      optional_string_enum(["segments","relevant_guidance","mode"]; ["paths_only","full_content"]),
      optional_uint(["segments","relevant_guidance","max_lines_per_file"]; 1; 5000),
      optional_uint(["segments","selected_file_contents","max_lines_per_file"]; 1; 5000),
      (
        (.segments.selected_file_contents.paths // []) as $paths
        | if ($paths | type) == "array" then empty else fail("segments.selected_file_contents.paths must be an array") end
        | $paths[]? | safe_path("segments.selected_file_contents.paths[]")
      ),
      (
        (.segments.relevant_guidance.rules // []) as $rules
        | if ($rules | type) == "array" then empty else fail("segments.relevant_guidance.rules must be an array") end
        | $rules[]? as $rule
        | if ($rule | type) == "object" then empty else fail("segments.relevant_guidance.rules[] must be an object") end
        | ($rule | keys_unsorted[]? as $key | if ["when_changed_path_matches","guidance_paths"] | index($key) then empty else fail("segments.relevant_guidance.rules[] has unknown key " + $key) end)
        | ($rule | string_array(["when_changed_path_matches"]))
        | ($rule | string_array(["guidance_paths"]))
        | ($rule.guidance_paths[]? | safe_path("segments.relevant_guidance.rules[].guidance_paths[]"))
      ),
      true
  ' --arg example "$example" "$file" >/dev/null 2>"$err_file"; then
    local err
    err=$(tr '\n' ' ' <"$err_file" | sed 's/^jq: error[^:]*: //; s/ at <top-level>.*$//')
    rm -f "$err_file"
    fatal "invalid prompt payload config in $file: ${err:-schema validation failed (see $example)}"
  fi
  rm -f "$err_file"
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
    fatal "REVIEWER_PERSONALITY_FILE is required (set it in reviewer.env). See config/personalities/ for options."
  fi
  if [ ! -f "$PERSONALITY_FILE" ]; then
    fatal "REVIEWER_PERSONALITY_FILE points at '$PERSONALITY_FILE' which does not exist."
  fi
  if [ -z "${PROMPT_PAYLOAD_FILE:-}" ] || [ ! -f "$PROMPT_PAYLOAD_FILE" ]; then
    fatal "missing prompt payload config: ${PROMPT_PAYLOAD_FILE:-unset}"
  fi
  validate_prompt_payload_config "$PROMPT_PAYLOAD_FILE"

  validate_uint_env REVIEWER_MAX_PRS "$MAX_PRS"
  validate_uint_env REVIEWER_MAX_ATTEMPTS "$MAX_ATTEMPTS"
  validate_uint_env REVIEWER_GEMINI_QUOTA_DEFAULT_BACKOFF "$GEMINI_QUOTA_DEFAULT_BACKOFF"
  validate_uint_env REVIEWER_GEMINI_QUOTA_BACKOFF_PADDING "$GEMINI_QUOTA_BACKOFF_PADDING"
  validate_positive_uint_env REVIEWER_MAX_PROMPT_BYTES "$MAX_PROMPT_BYTES"
  validate_positive_uint_env REVIEWER_MAX_ARTIFACT_BYTES "$MAX_ARTIFACT_BYTES"
  validate_positive_uint_env REVIEWER_DIFF_MAX_BYTES "$DIFF_MAX_BYTES"
  validate_positive_uint_env REVIEWER_FILE_TREE_MAX_BYTES "$FILE_TREE_MAX_BYTES"
  validate_positive_uint_env REVIEWER_SELECTED_FILE_MAX_BYTES "$SELECTED_FILE_MAX_BYTES"
  validate_positive_uint_env REVIEWER_GUIDANCE_FILE_MAX_BYTES "$GUIDANCE_FILE_MAX_BYTES"
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
