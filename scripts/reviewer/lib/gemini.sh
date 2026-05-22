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

  (
    cd "$worktree_dir" || exit
    timeout "$GEMINI_TIMEOUT" gemini -m "$GEMINI_MODEL" -p "" <"$prompt_file" 2>"$err_file"
  )
}
