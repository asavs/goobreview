#!/usr/bin/env bash
# Gemini invocation and quota backoff helpers.

format_epoch_utc() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

gemini_backoff_remaining() {
  local until now

  [ -f "$GEMINI_BACKOFF_FILE" ] || return 1
  until=$(cat "$GEMINI_BACKOFF_FILE" 2>/dev/null || true)
  case "$until" in
    ''|*[!0-9]*)
      rm -f "$GEMINI_BACKOFF_FILE"
      return 1
      ;;
  esac

  now=$(date +%s)
  if [ "$until" -gt "$now" ]; then
    printf '%s' "$((until - now))"
    return 0
  fi

  rm -f "$GEMINI_BACKOFF_FILE"
  return 1
}

set_gemini_quota_backoff() {
  local err_file="$1"
  local reset_after hours minutes seconds retry_ms delay_seconds until

  reset_after=$(grep -Eo 'quota will reset after [0-9]+h[0-9]+m[0-9]+s' "$err_file" | tail -n 1 || true)
  if [ -n "$reset_after" ]; then
    hours=$(printf '%s' "$reset_after" | sed -E 's/.*after ([0-9]+)h([0-9]+)m([0-9]+)s/\1/')
    minutes=$(printf '%s' "$reset_after" | sed -E 's/.*after ([0-9]+)h([0-9]+)m([0-9]+)s/\2/')
    seconds=$(printf '%s' "$reset_after" | sed -E 's/.*after ([0-9]+)h([0-9]+)m([0-9]+)s/\3/')
    delay_seconds=$((hours * 3600 + minutes * 60 + seconds))
  else
    retry_ms=$(grep -Eo 'retryDelayMs: [0-9]+' "$err_file" | tail -n 1 | sed -E 's/[^0-9]//g' || true)
    if [ -n "$retry_ms" ]; then
      delay_seconds=$(((retry_ms + 999) / 1000))
    elif grep -qiE 'QUOTA_EXHAUSTED|exhausted your capacity|No capacity available' "$err_file"; then
      delay_seconds="$GEMINI_QUOTA_DEFAULT_BACKOFF"
    else
      return 1
    fi
  fi

  until=$(($(date +%s) + delay_seconds + GEMINI_QUOTA_BACKOFF_PADDING))
  printf '%s\n' "$until" > "$GEMINI_BACKOFF_FILE"
  log "Gemini quota exhausted; backing off until $(format_epoch_utc "$until")"
}

run_gemini_review() {
  local prompt_file="$1"
  local err_file="$2"
  local worktree_dir="$3"
  local runtime_dir settings_file context_file_name

  runtime_dir="$STATE_DIR/gemini-runtime"
  settings_file="$STATE_DIR/gemini-settings.json"
  context_file_name=".goobreview-gemini-context-disabled.md"

  mkdir -p "$runtime_dir"
  jq -n \
    --arg context_file_name "$context_file_name" \
    --arg worktree_dir "$worktree_dir" \
    '{
      context: {
        fileName: $context_file_name,
        includeDirectories: [$worktree_dir],
        loadMemoryFromIncludeDirectories: false
      },
      tools: {
        core: [
          "glob",
          "list_directory",
          "read_file",
          "read_many_files",
          "search_file_content"
        ]
      },
      mcp: {
        allowed: []
      },
      advanced: {
        ignoreLocalEnv: true
      }
    }' >"$settings_file"

  (
    cd "$runtime_dir" || exit
    export GEMINI_CLI_SYSTEM_SETTINGS_PATH="$settings_file"
    export GEMINI_CLI_TRUST_WORKSPACE=true
    unset GH_TOKEN GITHUB_TOKEN REVIEWER_APP_ID REVIEWER_APP_INSTALLATION_ID REVIEWER_APP_PRIVATE_KEY_PATH
    timeout "$GEMINI_TIMEOUT" gemini -m "$GEMINI_MODEL" -p "" <"$prompt_file" 2>"$err_file"
  )
}
