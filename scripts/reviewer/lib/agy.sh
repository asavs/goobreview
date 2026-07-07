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
  local err_file="$1" retry_ms delay_seconds until reset_line reset_m reset_s

  retry_ms=$(grep -Eo 'retryDelayMs: [0-9]+' "$err_file" | tail -n 1 | sed -E 's/[^0-9]//g' || true)
  reset_line=$(grep -Eo 'Resets in [0-9]+m[0-9]+s' "$err_file" | tail -n 1 || true)
  if [ -n "$retry_ms" ]; then
    delay_seconds=$(((retry_ms + 999) / 1000))
  elif [ -n "$reset_line" ]; then
    # Antigravity's RESOURCE_EXHAUSTED message reports a concrete reset window
    # ("Resets in 13m20s") rather than retryDelayMs; parsing it gives a much
    # tighter backoff than AGY_QUOTA_DEFAULT_BACKOFF's 1-hour fallback. A
    # single capture-group substitution avoids relying on positional field
    # order across a second, separately-run grep pipeline.
    reset_m=$(printf '%s' "$reset_line" | sed -E 's/Resets in ([0-9]+)m([0-9]+)s/\1/')
    reset_s=$(printf '%s' "$reset_line" | sed -E 's/Resets in ([0-9]+)m([0-9]+)s/\2/')
    delay_seconds=$((reset_m * 60 + reset_s))
  elif grep -qiE 'QUOTA_EXHAUSTED|Individual quota reached|exhausted your capacity|No capacity available|rate limit' "$err_file"; then
    delay_seconds="$AGY_QUOTA_DEFAULT_BACKOFF"
  elif grep -qi 'RESOURCE_EXHAUSTED' "$err_file" && grep -qiE 'quota|429|rate limit' "$err_file"; then
    # RESOURCE_EXHAUSTED alone is a generic gRPC status (also used for e.g.
    # oversized-request errors) -- treating it as quota on its own risks
    # silently converting an unrelated, persistent failure into an infinite
    # quiet retry loop. Require it to co-occur with quota-shaped language
    # before backing off.
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

# The concrete model that `--model auto` routed to is recorded only in agy's
# per-invocation CLI log, never in the transcript. Same marker trick as
# latest_agy_transcript_file: agy writes one timestamped cli-<ts>.log per
# invocation, so the newest one created after the pre-agy marker is this call's
# log. The daemon runs one flock'd agy at a time, so there is no interleaving.
latest_agy_cli_log() {
  local newer_than="${1:-}"
  local log_dir="${HOME:-}/.gemini/antigravity-cli/log"
  local find_args=("$log_dir" -name 'cli-*.log' -type f)

  [ -d "$log_dir" ] || return 1
  if [ -n "$newer_than" ] && [ -e "$newer_than" ]; then
    find_args+=(-newer "$newer_than")
  fi
  find "${find_args[@]}" -printf '%T@ %p\n' 2>/dev/null \
    | sort -n \
    | tail -n 1 \
    | cut -d' ' -f2-
}

# The display label agy propagates to the backend for the resolved model, e.g.
# "Gemini 3.5 Flash (Medium)". Best-effort: a missing log, a future agy log
# format, or an empty label all return non-zero so the caller falls back to the
# requested --model alias. This is a friendly label (model + reasoning tier),
# not a raw API model id -- no such id appears in the logs.
extract_agy_resolved_model_label() {
  local cli_log="$1" label
  [ -f "$cli_log" ] || return 1
  label=$(grep -oE 'Propagating selected model override to backend: label="[^"]*"' "$cli_log" 2>/dev/null \
    | tail -n 1 \
    | sed -E 's/.*label="([^"]*)".*/\1/')
  [ -n "$label" ] || return 1
  printf '%s' "$label"
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

# The transcript path fixes which session produced the final message; its
# brain session directory (three levels up) is the only place a referenced
# review artifact may live.
agy_session_dir_for_transcript() {
  local transcript_file="$1"
  local suffix="/.system_generated/logs/transcript_full.jsonl"

  case "$transcript_file" in
    *"$suffix") printf '%s\n' "${transcript_file%"$suffix"}" ;;
    *) return 1 ;;
  esac
}

# Path-shaped tokens from a pointer message, one per line, first-appearance
# order, deduped. Restricted to .md tokens: the review artifact observed live
# is markdown (pr_review_report.md), and a tight token shape keeps prose noise
# out of the validation loop. file:// URI prefixes are stripped.
agy_artifact_path_candidates() {
  grep -oE '(file://)?[A-Za-z0-9_.~/-]+\.md' |
    sed 's|^file://||' |
    awk '!seen[$0]++'
}

# Validate one model-referenced artifact path and, on success, copy its
# content to out_file. The path came from model output after the session read
# untrusted PR content, so every check is load-bearing: a prompt-injected
# "reference" to ~/.gemini/app_token.json or any other readable file must
# never become a posted review. The canonical path must land inside this
# session's brain directory, must not be a symlink, is capped at
# MAX_ARTIFACT_BYTES, is secret-scanned, and must end with a valid terminal
# review event line. Anything less is rejected and the caller falls through
# to the invalid-output path unchanged.
read_agy_review_artifact() {
  local candidate="$1" session_dir="$2" out_file="$3"
  local resolved_session resolved bytes reason

  # Quoted so the ~ stays a literal in the pattern and the prefix strip; an
  # unquoted ~/ would tilde-expand here, which is exactly what must not happen
  # to a model-supplied path. SC2088 misreads the intent.
  # shellcheck disable=SC2088
  case "$candidate" in
    "~") candidate="${HOME:-}" ;;
    "~/"*) candidate="${HOME:-}/${candidate#"~/"}" ;;
  esac
  case "$candidate" in
    /*) ;;
    *) candidate="$session_dir/$candidate" ;;
  esac

  [ -e "$candidate" ] || return 1
  if [ -L "$candidate" ]; then
    log "Rejecting symlinked review artifact reference: $candidate"
    return 1
  fi
  [ -f "$candidate" ] || return 1
  resolved_session=$(realpath -e -- "$session_dir" 2>/dev/null) || return 1
  resolved=$(realpath -e -- "$candidate" 2>/dev/null) || return 1
  case "$resolved" in
    "$resolved_session"/*) ;;
    *)
      log "Rejecting review artifact reference outside the session brain directory: $candidate"
      return 1
      ;;
  esac

  bytes=$(wc -c <"$resolved" | tr -d ' ')
  if [ "$bytes" -gt "${MAX_ARTIFACT_BYTES:-1000000}" ]; then
    log "Rejecting oversized review artifact ($bytes bytes): $resolved"
    return 1
  fi
  if ! reason=$(artifact_secret_scan "$resolved"); then
    log "Rejecting review artifact containing high-confidence secret material ($reason): $resolved"
    return 1
  fi
  review_verdict_event <"$resolved" >/dev/null || return 1
  cat "$resolved" >"$out_file"
}

# Selection-ladder step for issue #149: when the chosen planner turn carries
# no verdict, agy (1.0.14+ artifact-centric workflow) has usually written the
# full review to a file in its brain session directory and replied with a
# short pointer. Scan that final message for path references and return the
# first one that survives read_agy_review_artifact validation. Requires a
# parsed transcript: without one there is no session directory to anchor the
# containment check, so stdout-only sessions never reach this step.
select_agy_review_artifact() {
  local message_file="$1" transcript_file="$2" out_file="$3"
  local session_dir candidate

  session_dir=$(agy_session_dir_for_transcript "$transcript_file") || return 1
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if read_agy_review_artifact "$candidate" "$session_dir" "$out_file"; then
      log "Review sourced from session artifact referenced by the final message: $candidate"
      return 0
    fi
  done < <(agy_artifact_path_candidates <"$message_file")
  return 1
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
  local runtime_dir workspace_dir prompt raw_out agy_status transcript_file content_tmp thinking_file transcript_marker transcript_source_file invocation_record prompt_byte_count cli_log resolved_model_file resolved_model_label artifact_tmp
  local -a add_dir_args agy_argv

  # Cleared unconditionally, before the runtime dir necessarily exists, so a
  # refusal/failure below never leaves a stale source from a prior invocation
  # for the caller to misread.
  runtime_dir="${RUNTIME_STATE_DIR:-$STATE_DIR/runtime}/agy-runtime"
  transcript_source_file="$runtime_dir/transcript_source"
  # Cleared for the same reason as transcript_source above: a refusal below must
  # never leave a stale invocation record or resolved-model label from a prior
  # run for the dry-run artifact / footer to misreport as this run's.
  invocation_record="$runtime_dir/last-invocation.cmd"
  resolved_model_file="$runtime_dir/resolved_model_label"
  rm -f "$transcript_source_file" "$invocation_record" "$resolved_model_file"

  if [ -n "$worktree_dir" ] && [ -d "$worktree_dir" ] && find "$worktree_dir" -type l -print -quit | grep -q .; then
    log "Refusing to invoke agy with symlinks present in PR-head snapshot: $worktree_dir"
    printf 'PR-head snapshot contains symlinks; refusing agy invocation.\n' >"$err_file"
    return 1
  fi

  mkdir -p "$runtime_dir"
  # The per-invocation trusted workspace holds ONLY AGENTS.md: agy 1.0.16's
  # --print no longer treats cwd as the workspace, so the trusted channel is
  # delivered via --add-dir instead, and agy opportunistically ingests any file
  # visible in an added dir. A stale file surviving here hijacked a canary run
  # into reviewing the wrong PR, so recreate the dir clean every time -- this is
  # a correctness requirement, not tidiness. Scratch, deny-bin, and the thinking
  # trace stay in $runtime_dir, outside the workspace.
  workspace_dir="$runtime_dir/workspace"
  rm -rf "$workspace_dir"
  mkdir -p "$workspace_dir"
  thinking_file="$runtime_dir/thinking.trace"
  rm -f "$thinking_file"
  if ! with_prompt_personality "$prompt_personality" write_agents_md "$personality_file" "$workspace_dir/AGENTS.md" "$ci_state" "$head_sha" "$worktree_dir"; then
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

  # Attach the trusted workspace (AGENTS.md) always, and the PR-head snapshot
  # only when one exists, so both become reachable workspace members instead of
  # prose pointers agy cannot act on. cwd is set to the workspace below so it
  # matches an added dir, the exact shape the 1.0.16 canary validated.
  add_dir_args=(--add-dir "$workspace_dir")
  if [ -n "$worktree_dir" ] && [ -d "$worktree_dir" ]; then
    add_dir_args+=(--add-dir "$worktree_dir")
  fi

  # The full argv is built ONCE here and used twice below: recorded to the
  # invocation record, then executed verbatim in the subshell. That makes drift
  # between what the dry-run artifact reports and what actually runs
  # structurally impossible -- the previous hand-maintained "Command template"
  # silently omitted the --add-dir attachments added in 5dfa46f, which briefly
  # misled incident forensics. The prompt argument is appended only at execution
  # time; in the record it is elided to a byte-count placeholder (it is huge and
  # already captured verbatim elsewhere in the artifact -- the point of this
  # record is the flags). Recorded args go through %q so the line is unambiguous
  # even if a path contains spaces.
  agy_argv=(timeout --kill-after=30 "$AGY_TIMEOUT" agy --sandbox \
    --dangerously-skip-permissions --print-timeout "${AGY_TIMEOUT}s" \
    --model "$AGY_MODEL" "${add_dir_args[@]}" --print)
  prompt_byte_count=$(printf '%s' "$prompt" | wc -c | tr -d ' ')
  {
    printf '%q ' "${agy_argv[@]}"
    printf '<prompt: %s bytes>\n' "$prompt_byte_count"
  } >"$invocation_record"

  (
    cd "$workspace_dir" || exit
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
    "${agy_argv[@]}" "$prompt" </dev/null >"$raw_out" 2>"$err_file"
  )
  agy_status=$?

  cli_log=$(latest_agy_cli_log "$transcript_marker" || true)
  # agy can hit RESOURCE_EXHAUSTED, retry internally, and still exit 0 with an
  # empty planner turn -- the quota error only ever reaches its own
  # per-invocation cli-<ts>.log, never agy's own stdout/stderr. Surface just
  # the matching lines (not the whole multi-KB log) onto err_file so
  # set_agy_quota_backoff can see it regardless of agy's exit status, without
  # bloating the daemon log on ordinary runs where nothing matches.
  if [ -n "$cli_log" ] && [ -f "$cli_log" ]; then
    grep -iE 'RESOURCE_EXHAUSTED|QUOTA_EXHAUSTED|Individual quota reached|retryDelayMs|Resets in [0-9]+m[0-9]+s|exhausted your capacity|No capacity available|rate limit' \
      "$cli_log" >>"$err_file" 2>/dev/null || true
  fi

  if [ "$agy_status" -ne 0 ]; then
    cat "$raw_out"
    rm -f "$raw_out" "$content_tmp" "$transcript_marker"
    return "$agy_status"
  fi

  if [ -n "$cli_log" ] && resolved_model_label=$(extract_agy_resolved_model_label "$cli_log"); then
    printf '%s\n' "$resolved_model_label" >"$resolved_model_file"
  fi

  transcript_file=$(latest_agy_transcript_file "$transcript_marker" || true)
  artifact_tmp=$(mktemp "$runtime_dir/agy-artifact.XXXXXX")
  if [ -n "$transcript_file" ] && extract_last_agy_planner_response "$transcript_file" "$content_tmp" "$thinking_file" && [ -s "$content_tmp" ]; then
    if review_verdict_event <"$content_tmp" >/dev/null; then
      printf 'transcript\n' >"$transcript_source_file"
      cat "$content_tmp"
    elif select_agy_review_artifact "$content_tmp" "$transcript_file" "$artifact_tmp"; then
      printf 'artifact\n' >"$transcript_source_file"
      cat "$artifact_tmp"
    else
      # No verdict in any planner turn and no valid referenced artifact:
      # emit the last turn so the failure surfaces through the
      # invalid-output path exactly as before.
      printf 'transcript\n' >"$transcript_source_file"
      cat "$content_tmp"
    fi
  else
    rm -f "$thinking_file"
    printf 'stdout_fallback\n' >"$transcript_source_file"
    cat "$raw_out"
  fi
  rm -f "$raw_out" "$content_tmp" "$artifact_tmp" "$transcript_marker"
}

# Emit, for the dry-run artifact, the actual agy invocation recorded by the
# preceding run_agy_review (its --add-dir attachments and flags; the prompt is
# already elided to a byte count at record time). Falls back gracefully when the
# record is missing -- e.g. agy refused before invocation, so no argv ran.
print_recorded_agy_invocation() {
  local record_file="$1"
  if [ -s "$record_file" ]; then
    printf 'Invocation (recorded): '
    cat "$record_file"
  else
    printf 'Invocation (recorded): invocation record unavailable\n'
  fi
}

# Reads back what the immediately preceding run_agy_review call recorded:
# "transcript" (parsed agy's structured transcript), "artifact" (verdict-less
# final message referenced a validated review artifact in the session's brain
# directory), "stdout_fallback" (transcript missing/unparseable, used raw
# agy --print output), or "agy_failed" (the call never reached a source
# decision -- refused, or agy itself exited non-zero).
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

# The display label of the model the immediately preceding run_agy_review
# resolved `--model auto` to, or empty when it could not be recovered (agy
# failed, no CLI log, or an unrecognized log format). Callers substitute the
# requested --model alias when this is empty. Same overwrite contract as
# agy_transcript_source: read before the next run_agy_review reuses the dir.
agy_resolved_model_label() {
  local file
  file="${RUNTIME_STATE_DIR:-$STATE_DIR/runtime}/agy-runtime/resolved_model_label"
  if [ -s "$file" ]; then
    tr -d '\n' <"$file"
  fi
}
