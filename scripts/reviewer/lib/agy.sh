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

# Fail-closed gate for issue #106. When REVIEWER_REFUSE_ON_HOME_CONTEXT=1 the
# daemon declines to review at all while home-dir context files are present,
# rather than running agy with operator/co-tenant content merged in as trusted
# instructions. Off by default (the warning is the baseline); intended for
# shared or multi-tenant VMs where the home dir is not solely operator-owned.
should_refuse_for_home_context() {
  [ "${REFUSE_ON_HOME_CONTEXT:-0}" = "1" ] || return 1
  [ -n "$(home_agy_context_files)" ] || return 1
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

latest_agy_transcript_file() {
  local newer_than="${1:-}"
  local brain_dir="${HOME:-}/.gemini/antigravity-cli/brain"
  local find_args=("$brain_dir" -path '*/.system_generated/logs/transcript_full.jsonl' -type f)

  [ -d "$brain_dir" ] || return 1
  if [ -n "$newer_than" ] && [ -e "$newer_than" ]; then
    find_args+=(-newer "$newer_than")
  fi
  find "${find_args[@]}" -printf '%T@ %p\n' 2>/dev/null \
    | sort -n \
    | tail -n 1 \
    | cut -d' ' -f2-
}

# Pick the reviewable planner turn from agy's transcript. Prefer the last
# turn whose final non-empty line is a valid review event: agy appends
# boilerplate turns after the actual review (workspace suggestions, wrap-up
# chatter), and taking the literal last turn discards the postable one. When
# no turn carries a verdict, fall back to the literal last turn so the
# failure still surfaces through the invalid-verdict path.
extract_last_agy_planner_response() {
  local transcript_file="$1" content_file="$2" thinking_file="$3"
  local turn_tmp

  turn_tmp=$(mktemp)
  if ! jq -ecs '
    def last_line:
      gsub("\r"; "")
      | split("\n")
      | map(select(test("[^[:space:]]")))
      | (.[-1] // "")
      | sub("^[[:space:]]+"; "")
      | sub("[[:space:]]+$"; "");
    [ .[]
      | select(type == "object")
      | select(.type == "PLANNER_RESPONSE")
      | select(has("thinking") and has("content"))
      | select((.thinking | type) == "string" and (.content | type) == "string")
    ] as $turns
    | ([ $turns[] | select(.content | last_line | IN("APPROVE", "REQUEST_CHANGES", "COMMENT")) ] | last)
      // ($turns | last)
    | select(. != null)
  ' "$transcript_file" >"$turn_tmp"; then
    rm -f "$turn_tmp"
    return 1
  fi
  jq -er '.content' "$turn_tmp" >"$content_file" || {
    rm -f "$turn_tmp"
    return 1
  }
  jq -er '.thinking' "$turn_tmp" >"$thinking_file" || {
    rm -f "$turn_tmp"
    return 1
  }
  rm -f "$turn_tmp"
}

# Build/test entry points shadowed in the PATH agy inherits. The model was
# observed copying the read-only snapshot into its own scratch space and
# re-running builds and test suites there (issue #144) -- burning the review
# timeout on infrastructure the sandbox lacks -- so the contract instruction
# gets a mechanical backstop. Interpreters (node, python) stay unshimmed:
# agy itself runs on node, and reading files needs no build tool.
AGY_DENIED_TOOL_NAMES="npm npx yarn pnpm bun vite vitest jest mocha playwright cypress tsc cargo rustc go make cmake mvn gradle pytest tox"

write_agy_tool_shims() {
  local shim_dir="$1"
  local shim name

  mkdir -p "$shim_dir" || return 1
  shim="$shim_dir/.deny-build-tool"
  cat >"$shim" <<'EOF'
#!/usr/bin/env bash
tool=$(basename "$0")
printf 'goobreview: %s is disabled during review. Do not build, install, or run tests -- the CI check-run conclusions in the review prompt are authoritative for pass/fail. Read source and test files instead.\n' "$tool"
printf 'goobreview: %s is disabled during review.\n' "$tool" >&2
exit 2
EOF
  chmod 755 "$shim" || return 1
  for name in $AGY_DENIED_TOOL_NAMES; do
    ln -sf ".deny-build-tool" "$shim_dir/$name" || return 1
  done
}

run_agy_review() {
  local prompt_file="$1" err_file="$2" worktree_dir="$3" personality_file="${4:-${PERSONALITY_FILE:-}}"
  local ci_state="${5:-}"
  local head_sha="${6:-}"
  local prompt_personality="${7:-${POSTED_PERSONALITY:-}}"
  local runtime_dir prompt raw_out agy_status transcript_file content_tmp thinking_file transcript_marker transcript_source_file

  # Cleared unconditionally, before the runtime dir necessarily exists, so a
  # refusal/failure below never leaves a stale source from a prior invocation
  # for the caller to misread.
  runtime_dir="${RUNTIME_STATE_DIR:-$STATE_DIR/runtime}/agy-runtime"
  transcript_source_file="$runtime_dir/transcript_source"
  rm -f "$transcript_source_file"

  if [ -n "$worktree_dir" ] && [ -d "$worktree_dir" ] && find "$worktree_dir" -type l -print -quit | grep -q .; then
    log "Refusing to invoke agy with symlinks present in PR-head snapshot: $worktree_dir"
    printf 'PR-head snapshot contains symlinks; refusing agy invocation.\n' >"$err_file"
    return 1
  fi

  mkdir -p "$runtime_dir"
  rm -f "$runtime_dir/AGENTS.md"
  thinking_file="$runtime_dir/thinking.trace"
  rm -f "$thinking_file"
  if ! with_prompt_personality "$prompt_personality" write_agents_md "$personality_file" "$runtime_dir/AGENTS.md" "$ci_state" "$head_sha" "$worktree_dir"; then
    printf 'Failed to write trusted runtime AGENTS.md; refusing agy invocation.\n' >"$err_file"
    return 1
  fi
  if ! write_agy_tool_shims "$runtime_dir/deny-bin"; then
    printf 'Failed to write build-tool refusal shims; refusing agy invocation.\n' >"$err_file"
    return 1
  fi
  prompt=$(cat "$prompt_file")
  raw_out=$(mktemp "$runtime_dir/agy-stdout.XXXXXX")
  content_tmp=$(mktemp "$runtime_dir/agy-content.XXXXXX")
  transcript_marker=$(mktemp "$runtime_dir/agy-start.XXXXXX")

  (
    cd "$runtime_dir" || exit
    # Keep the GitHub App identity out of the agent subprocess.  agy's native
    # sandbox confines tool execution; the snapshot is its sole project context.
    unset GH_TOKEN GITHUB_TOKEN REVIEWER_APP_ID REVIEWER_APP_INSTALLATION_ID REVIEWER_APP_PRIVATE_KEY_PATH
    # Close the daemon's flock fd (reviewer.sh fd 9) so no subprocess agy spawns
    # can inherit the lock: an orphaned agy tool-call child (e.g. npm ci) that
    # outlives agy would otherwise hold the lock and deadlock every subsequent
    # tick until killed by hand (issue #143). A no-op when fd 9 is not open.
    exec 9>&-
    # Every subprocess agy spawns resolves build/test entry points to the
    # refusal shims first (issue #144). agy itself is not shimmed.
    export PATH="$runtime_dir/deny-bin:$PATH"
    timeout --kill-after=30 "$AGY_TIMEOUT" agy --sandbox --dangerously-skip-permissions \
      --print-timeout "${AGY_TIMEOUT}s" --model "$AGY_MODEL" --print "$prompt" </dev/null >"$raw_out" 2>"$err_file"
  )
  agy_status=$?

  if [ "$agy_status" -ne 0 ]; then
    cat "$raw_out"
    rm -f "$raw_out" "$content_tmp" "$transcript_marker"
    return "$agy_status"
  fi

  transcript_file=$(latest_agy_transcript_file "$transcript_marker" || true)
  if [ -n "$transcript_file" ] && extract_last_agy_planner_response "$transcript_file" "$content_tmp" "$thinking_file" && [ -s "$content_tmp" ]; then
    printf 'transcript\n' >"$transcript_source_file"
    cat "$content_tmp"
  else
    rm -f "$thinking_file"
    printf 'stdout_fallback\n' >"$transcript_source_file"
    cat "$raw_out"
  fi
  rm -f "$raw_out" "$content_tmp" "$transcript_marker"
}

# Reads back what the immediately preceding run_agy_review call recorded:
# "transcript" (parsed agy's structured transcript), "stdout_fallback" (transcript
# missing/unparseable, used raw agy --print output), or "agy_failed" (the call
# never reached a source decision -- refused, or agy itself exited non-zero).
# Must be called before any subsequent run_agy_review call reuses the same
# runtime dir and overwrites the file.
agy_transcript_source() {
  local file
  file="${RUNTIME_STATE_DIR:-$STATE_DIR/runtime}/agy-runtime/transcript_source"
  if [ -s "$file" ]; then
    tr -d '\n' <"$file"
  else
    printf 'agy_failed'
  fi
}
