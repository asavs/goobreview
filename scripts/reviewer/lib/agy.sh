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

# agy loads context files from the operator's home directory regardless of
# working directory, merging them into every review as trusted instructions
# outside the daemon-supplied AGENTS.md and the PR-head snapshot. That is a
# standing prompt-injection surface (security issue #106): anyone who can write
# the reviewer account's home directory steers verdicts without touching a PR.
# List any such files so callers can warn; removing them restores the snapshot
# as agy's sole project context.
#
# The paths below are the auto-load surface confirmed by live VM testing
# (agy 1.0.10): the global ~/.gemini/ config dir loads both GEMINI.md and
# AGENTS.md, and the home root loads GEMINI.md. Notably ~/AGENTS.md (home root)
# is NOT loaded, so it is deliberately excluded -- warning on a non-vector would
# be a false positive. Re-test and extend if agy's loading behavior changes.
home_agy_context_files() {
  local home="${HOME:-}" candidate
  [ -n "$home" ] || return 0
  for candidate in \
    "$home/.gemini/GEMINI.md" \
    "$home/GEMINI.md" \
    "$home/.gemini/AGENTS.md"; do
    if [ -e "$candidate" ]; then
      printf '%s\n' "$candidate"
    fi
  done
  return 0
}

warn_home_agy_context_files() {
  local files file
  files=$(home_agy_context_files)
  [ -n "$files" ] || return 0
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    log "WARNING: home-directory agy context file will be auto-loaded as trusted instructions for every review: $file (security issue #106; agy context is no longer limited to the daemon AGENTS.md and PR-head snapshot -- remove it unless intentional)"
  done <<EOF
$files
EOF
  return 0
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
  if ! write_agents_md "$personality_file" "$runtime_dir/AGENTS.md" "$ci_state" "$head_sha" "$worktree_dir"; then
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
