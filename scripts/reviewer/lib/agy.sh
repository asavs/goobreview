#!/usr/bin/env bash
# Antigravity CLI invocation and quota backoff helpers.

format_epoch_utc() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

agy_backoff_remaining() {
  local until now

  [ -f "$AGY_BACKOFF_FILE" ] || return 1
  until=$(cat "$AGY_BACKOFF_FILE" 2>/dev/null || true)
  case "$until" in
    ''|*[!0-9]*) rm -f "$AGY_BACKOFF_FILE"; return 1 ;;
  esac

  now=$(date +%s)
  if [ "$until" -gt "$now" ]; then
    printf '%s' "$((until - now))"
    return 0
  fi
  rm -f "$AGY_BACKOFF_FILE"
  return 1
}

set_agy_quota_backoff() {
  local err_file="$1" retry_ms delay_seconds until

  retry_ms=$(grep -Eo 'retryDelayMs: [0-9]+' "$err_file" | tail -n 1 | sed -E 's/[^0-9]//g' || true)
  if [ -n "$retry_ms" ]; then
    delay_seconds=$(((retry_ms + 999) / 1000))
  elif grep -qiE 'QUOTA_EXHAUSTED|exhausted your capacity|No capacity available|rate limit' "$err_file"; then
    delay_seconds="$AGY_QUOTA_DEFAULT_BACKOFF"
  else
    return 1
  fi

  until=$(($(date +%s) + delay_seconds + AGY_QUOTA_BACKOFF_PADDING))
  printf '%s\n' "$until" > "$AGY_BACKOFF_FILE"
  log "Antigravity quota exhausted; backing off until $(format_epoch_utc "$until")"
}

run_agy_review() {
  local prompt_file="$1" err_file="$2" worktree_dir="$3" personality_file="${4:-${PERSONALITY_FILE:-}}"
  local ci_state="${5:-}"
  local head_sha="${6:-}"
  local runtime_dir prompt

  if [ -n "$worktree_dir" ] && [ -d "$worktree_dir" ] && find "$worktree_dir" -type l -print -quit | grep -q .; then
    log "Refusing to invoke agy with symlinks present in PR-head snapshot: $worktree_dir"
    printf 'PR-head snapshot contains symlinks; refusing agy invocation.\n' >"$err_file"
    return 1
  fi

  runtime_dir="${RUNTIME_STATE_DIR:-$STATE_DIR/runtime}/agy-runtime"
  mkdir -p "$runtime_dir"
  rm -f "$runtime_dir/AGENTS.md"
  if ! write_agents_md "$personality_file" "$runtime_dir/AGENTS.md" "$ci_state" "$head_sha"; then
    printf 'Failed to write trusted runtime AGENTS.md; refusing agy invocation.\n' >"$err_file"
    return 1
  fi
  prompt=$(cat "$prompt_file")

  (
    cd "$runtime_dir" || exit
    # Keep the GitHub App identity out of the agent subprocess.  agy's native
    # sandbox confines tool execution; the snapshot is its sole project context.
    unset GH_TOKEN GITHUB_TOKEN REVIEWER_APP_ID REVIEWER_APP_INSTALLATION_ID REVIEWER_APP_PRIVATE_KEY_PATH
    timeout "$AGY_TIMEOUT" agy --sandbox --dangerously-skip-permissions \
      --print-timeout "${AGY_TIMEOUT}s" --model "$AGY_MODEL" --print "$prompt" </dev/null 2>"$err_file"
  )
}
