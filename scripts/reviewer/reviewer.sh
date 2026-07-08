#!/usr/bin/env bash
# Most top-level assignments are configuration globals consumed by sourced
# reviewer libraries.
# shellcheck disable=SC2034
set -euo pipefail

REPO="${REVIEWER_REPO:-}"
EXTRA_SKIP_USER="${REVIEWER_USER:-}"
ONLY_PR="${REVIEWER_ONLY_PR:-}"
DRY_RUN="${REVIEWER_DRY_RUN:-}"
DRY_RUN_OUT="${REVIEWER_DRY_RUN_OUT:-}"
DRY_RUN_BYPASS_CI="${REVIEWER_DRY_RUN_BYPASS_CI:-}"
RENDER_PROMPT_ONLY="${REVIEWER_RENDER_PROMPT_ONLY:-}"
PROMPT_OUT="${REVIEWER_PROMPT_OUT:-}"
IGNORE_AGY_BACKOFF="${REVIEWER_IGNORE_AGY_BACKOFF:-}"
AGY_TIMEOUT="${REVIEWER_AGY_TIMEOUT:-600}"
AGY_MODEL="${REVIEWER_AGY_MODEL:-auto}"
AGY_QUOTA_DEFAULT_BACKOFF="${REVIEWER_AGY_QUOTA_DEFAULT_BACKOFF:-3600}"
AGY_QUOTA_BACKOFF_PADDING="${REVIEWER_AGY_QUOTA_BACKOFF_PADDING:-300}"
MAX_PROMPT_BYTES="${REVIEWER_MAX_PROMPT_BYTES:-240000}"
MAX_ARTIFACT_BYTES="${REVIEWER_MAX_ARTIFACT_BYTES:-1000000}"
DIFF_MAX_BYTES="${REVIEWER_DIFF_MAX_BYTES:-120000}"
DIFF_FILE_MAX_BYTES="${REVIEWER_DIFF_FILE_MAX_BYTES:-40000}"
DESCRIPTION_MAX_BYTES="${REVIEWER_DESCRIPTION_MAX_BYTES:-12000}"
SUGGESTION_MAX_LINES="${REVIEWER_SUGGESTION_MAX_LINES:-12}"
CI_WORKFLOW_FILE_LIMIT="${REVIEWER_CI_WORKFLOW_FILE_LIMIT:-8}"
CI_WORKFLOW_FILE_MAX_BYTES="${REVIEWER_CI_WORKFLOW_FILE_MAX_BYTES:-12000}"
CI_PACKAGE_SCRIPT_FILE_LIMIT="${REVIEWER_CI_PACKAGE_SCRIPT_FILE_LIMIT:-12}"
PREVIOUS_REVIEW_MAX_BYTES="${REVIEWER_PREVIOUS_REVIEW_MAX_BYTES:-500}"
PRIOR_THREAD_SUMMARY_LIMIT="${REVIEWER_PRIOR_THREAD_SUMMARY_LIMIT:-12}"
PRIOR_THREAD_BODY_MAX_BYTES="${REVIEWER_PRIOR_THREAD_BODY_MAX_BYTES:-500}"
COMMIT_SUBJECTS_MAX="${REVIEWER_COMMIT_SUBJECTS_MAX:-10}"
INCLUDE_AUTHOR="${REVIEWER_INCLUDE_AUTHOR:-0}"
INCLUDE_DESCRIPTION="${REVIEWER_INCLUDE_DESCRIPTION:-0}"
INCLUDE_COMMIT_SUBJECTS="${REVIEWER_INCLUDE_COMMIT_SUBJECTS:-1}"
RESEARCH_CONSENT="${REVIEWER_RESEARCH_CONSENT:-0}"
RESEARCH_ALLOW_PRIVATE="${REVIEWER_RESEARCH_ALLOW_PRIVATE:-0}"
REFUSE_ON_HOME_CONTEXT="${REVIEWER_REFUSE_ON_HOME_CONTEXT:-0}"
MAX_PRS="${REVIEWER_MAX_PRS:-1}"
MAX_ATTEMPTS="${REVIEWER_MAX_ATTEMPTS:-$MAX_PRS}"
AUTO_RESOLVE_BOT_THREADS="${REVIEWER_AUTO_RESOLVE_BOT_THREADS:-0}"
CHECK_RUN_SIGNAL="${REVIEWER_CHECK_RUN_SIGNAL:-1}"
FAILURE_MAX_ATTEMPTS="${REVIEWER_FAILURE_MAX_ATTEMPTS:-3}"
INVALID_VERDICT_MAX_ATTEMPTS="${REVIEWER_INVALID_VERDICT_MAX_ATTEMPTS:-3}"
STATE_DIR="${REVIEWER_STATE:-$HOME/.goobreview}"
RUNTIME_OWNER="${USER:-$(id -u 2>/dev/null || printf user)}"
# Snapshot extraction needs deterministic on-disk space, so default to /tmp
# rather than XDG_RUNTIME_DIR (commonly a tmpfs capped near 10% of RAM, ~96 MB
# on a 1 GB e2-micro -- too small to unpack a PR-head snapshot). The dir is
# created 0700 below, keeping it private despite /tmp being world-traversable.
RUNTIME_STATE_DIR="${REVIEWER_RUNTIME_STATE:-/tmp/goobreview-runtime-$RUNTIME_OWNER}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PROMPT_FILE="${REVIEWER_PROMPT:-$SCRIPT_DIR/review-prompt.md}"
REPO_DIR="${REVIEWER_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CONFIG_DIR="${REVIEWER_CONFIG_DIR:-$REPO_DIR/config}"
LOG_FILE="$STATE_DIR/log.txt"
LOCK_FILE="$STATE_DIR/lock"
AGY_BACKOFF_FILE="$STATE_DIR/agy_backoff_until"

# shellcheck disable=SC1091
. "$LIB_DIR/ci.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/config.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/agy.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/github-api.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/github.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/output.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/prompt.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/worktree.sh"

ensure_owner_private_dir "runtime state" "$STATE_DIR"
ensure_owner_private_dir "transient runtime state" "$RUNTIME_STATE_DIR"
"$SCRIPT_DIR/rotate-log.sh" "$LOG_FILE" 2>/dev/null || true

DEFAULT_REQUIRED_CHECKS_FILE="$CONFIG_DIR/required-checks.json"
EXAMPLE_REQUIRED_CHECKS_FILE="$CONFIG_DIR/required-checks.example.json"
ALLOW_EXAMPLE_CONFIG=0
if [ -n "$DRY_RUN" ] || [ -n "$RENDER_PROMPT_ONLY" ]; then
  ALLOW_EXAMPLE_CONFIG=1
fi
REQUIRED_CHECKS_FILE="$(resolve_reviewer_config_file "required checks" REVIEWER_REQUIRED_CHECKS_FILE "$DEFAULT_REQUIRED_CHECKS_FILE" "$EXAMPLE_REQUIRED_CHECKS_FILE" "$ALLOW_EXAMPLE_CONFIG")"
POSTED_PERSONALITY=""
PERSONALITY_FILE=""
resolve_reviewer_personality_config
ALLOW_REQUIRED_CHECKS_OVERRIDE="${REVIEWER_ALLOW_REQUIRED_CHECKS_OVERRIDE:-0}"
# Provenance for the review footer and research/dry-run artifacts. sync-worktree
# pins the checkout to a SHA each tick, so this identifies the engine exactly.
ENGINE_SHA="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"

if [ "${REVIEWER_LOCK_HELD:-0}" = "1" ]; then
  flock -n 9 || fatal "REVIEWER_LOCK_HELD=1 but reviewer lock fd 9 is not held"
else
  exec 9>"$LOCK_FILE"
  flock -n 9 || exit 0
fi

validate_reviewer_config
load_effective_required_checks_json >/dev/null

write_dry_run_artifact() {
  local num="$1"
  local head_sha="$2"
  local event="$3"
  local prompt_file="$4"
  local review_body="$5"
  local inline_comments_json="${6:-[]}"
  local auto_resolve_threads="${7:-0}"
  local agy_err_file="${8:-}"
  local worktree_dir="${9:-}"
  local ci_state="${10:-}"
  local transcript_source="${11:-agy_failed}"
  local output_file
  local required_checks_sha256 inline_comment_count
  local artifact_tmp
  local runtime_dir agy_path agy_version prompt_bytes prompt_sha response_bytes response_sha stderr_bytes stderr_sha snapshot_files snapshot_symlinks agents_md_tmp agents_md_bytes agents_md_sha home_agy_context
  local generated_at generated_at_epoch review_latency_seconds

  output_file=$(resolve_dry_run_out "$num")
  [ -n "$output_file" ] || return 0

  mkdir -p "$(dirname "$output_file")"
  artifact_tmp=$(mktemp "$STATE_DIR/dry-artifact.XXXXXX")
  inline_comment_count=$(printf '%s' "$inline_comments_json" | jq -r 'length') || fatal "invalid resolved inline-comments JSON"
  runtime_dir="${RUNTIME_STATE_DIR:-$STATE_DIR/runtime}/agy-runtime"
  agy_path=$(command -v agy 2>/dev/null || printf 'not found')
  agy_version="not probed (avoids a second agy invocation)"
  prompt_bytes=$(wc -c <"$prompt_file" | tr -d ' ')
  prompt_sha=$(sha256sum "$prompt_file" | awk '{print $1}')
  response_bytes=$(printf '%s' "$review_body" | wc -c | tr -d ' ')
  response_sha=$(printf '%s' "$review_body" | sha256sum | awk '{print $1}')
  if [ -n "$agy_err_file" ] && [ -f "$agy_err_file" ]; then
    stderr_bytes=$(wc -c <"$agy_err_file" | tr -d ' ')
    stderr_sha=$(sha256sum "$agy_err_file" | awk '{print $1}')
  else
    stderr_bytes=0
    stderr_sha=
  fi
  agents_md_tmp=$(mktemp "$STATE_DIR/dry-agents-md.XXXXXX")
  write_agents_md "$PERSONALITY_FILE" "$agents_md_tmp" "$ci_state" "$head_sha" "$worktree_dir" || fatal "failed to render dry-run AGENTS.md artifact"
  agents_md_bytes=$(wc -c <"$agents_md_tmp" | tr -d ' ')
  agents_md_sha=$(sha256sum "$agents_md_tmp" | awk '{print $1}')
  if [ -n "$worktree_dir" ] && [ -d "$worktree_dir" ]; then
    snapshot_files=$(find "$worktree_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
    snapshot_symlinks=$(find "$worktree_dir" -type l 2>/dev/null | wc -l | tr -d ' ')
  else
    snapshot_files=0
    snapshot_symlinks=0
  fi
  home_agy_context=$(home_agy_context_files | paste -sd ',' -)
  [ -n "$home_agy_context" ] || home_agy_context="none"
  generated_at="$(date -Is)"
  generated_at_epoch="$(date +%s)"
  review_latency_seconds=""
  if [ -n "$head_committed_at" ]; then
    review_latency_seconds=$(jq -rn --arg d "$head_committed_at" --argjson now "$generated_at_epoch" '$now - ($d | fromdateiso8601)')
  fi
  {
    printf 'GoobReview dry run\n'
    printf 'Repository: %s\n' "$REPO"
    printf 'PR: #%s\n' "$num"
    printf 'Head SHA: %s\n' "$head_sha"
    printf 'Posted personality: %s\n' "$POSTED_PERSONALITY"
    printf 'Personality file: %s\n' "$PERSONALITY_FILE"
    printf 'Parsed review event: %s\n' "$event"
    printf 'Resolved inline comments: %s\n' "$inline_comment_count"
    printf 'Selected bot threads to auto-resolve: %s\n' "$auto_resolve_threads"
    printf 'Generated at: %s\n' "$generated_at"
    printf '\n===== AGY EXECUTION CONTEXT START =====\n'
    printf 'Observable from GoobReview: prompt payload, agy stdout/stderr, process envelope, runtime cwd, and PR-head snapshot path/counts.\n'
    printf 'Hidden Antigravity CLI system prompt/tool definitions: not observable by GoobReview; injected by agy outside this artifact.\n'
    print_recorded_agy_invocation "$runtime_dir/last-invocation.cmd"
    printf 'Requested model (--model): %s\n' "$AGY_MODEL"
    printf 'Resolved model label: %s\n' "${resolved_model_label:-unavailable}"
    printf 'Engine commit: %s\n' "$ENGINE_SHA"
    printf 'Agy wall-clock seconds: %s\n' "${agy_elapsed_s:-unavailable}"
    printf 'Head pushed at: %s\n' "${head_committed_at:-unavailable}"
    printf 'Review latency seconds: %s\n' "${review_latency_seconds:-unavailable}"
    printf 'Antigravity CLI path: %s\n' "$agy_path"
    printf 'Antigravity CLI version probe: %s\n' "$agy_version"
    printf 'Runtime cwd: %s\n' "$runtime_dir"
    printf 'Home-directory agy context files (auto-loaded; security issue #106): %s\n' "$home_agy_context"
    printf 'PR-head snapshot path: %s\n' "${worktree_dir:-unavailable}"
    printf 'PR-head snapshot regular files: %s\n' "$snapshot_files"
    printf 'PR-head snapshot symlinks: %s\n' "$snapshot_symlinks"
    printf 'Prompt bytes: %s\n' "$prompt_bytes"
    printf 'Prompt SHA256: %s\n' "$prompt_sha"
    printf 'Response bytes: %s\n' "$response_bytes"
    printf 'Response SHA256: %s\n' "$response_sha"
    printf 'Agy stderr bytes: %s\n' "$stderr_bytes"
    if [ -n "$stderr_sha" ]; then
      printf 'Agy stderr SHA256: %s\n' "$stderr_sha"
    fi
    printf 'AGENTS.MD bytes: %s\n' "$agents_md_bytes"
    printf 'AGENTS.MD SHA256: %s\n' "$agents_md_sha"
    printf 'GitHub token environment removed before agy: yes\n'
    printf 'GitHub App key environment removed before agy: yes\n'
    printf '===== AGY EXECUTION CONTEXT END =====\n'
    printf '\n===== AGY AGENTS.MD START =====\n'
    append_bounded_file "$agents_md_tmp" "$MAX_ARTIFACT_BYTES" "dry-run agents-md artifact"
    printf '\n===== AGY AGENTS.MD END =====\n'
    printf '\n===== AGY PROMPT PAYLOAD START =====\n'
    append_bounded_file "$prompt_file" "$MAX_ARTIFACT_BYTES" "dry-run prompt artifact"
    printf '\n===== AGY PROMPT PAYLOAD END =====\n'
    printf '\n===== AGY STDERR START =====\n'
    if [ -n "$agy_err_file" ] && [ -f "$agy_err_file" ]; then
      append_bounded_file "$agy_err_file" "$MAX_ARTIFACT_BYTES" "dry-run agy stderr artifact"
    else
      printf '[goobreview: no agy stderr captured]\n'
    fi
    printf '===== AGY STDERR END =====\n'
    printf '\n===== AGY RESPONSE START =====\n'
    printf '%s\n' "$review_body" | append_bounded_stdin "$MAX_ARTIFACT_BYTES" "dry-run response artifact"
    printf '===== AGY RESPONSE END =====\n'
    printf '\n===== RESOLVED INLINE COMMENTS START =====\n'
    printf '%s\n' "$inline_comments_json" | jq . | append_bounded_stdin "$MAX_ARTIFACT_BYTES" "dry-run inline-comments artifact"
    printf '===== RESOLVED INLINE COMMENTS END =====\n'
  } >"$artifact_tmp"
  install_bounded_scanned_artifact "$artifact_tmp" "$output_file" "$MAX_ARTIFACT_BYTES" "dry-run artifact" || fatal "dry-run artifact failed secret-safety scan"
  rm -f "$agents_md_tmp"
  required_checks_sha256=$(sha256sum "$REQUIRED_CHECKS_FILE" | awk '{print $1}')
  jq -n \
    --arg repo "$REPO" \
    --arg pr "$num" \
    --arg head_sha "$head_sha" \
    --arg event "$event" \
    --arg generated_at "$generated_at" \
    --arg dry_run_out "$output_file" \
    --arg posted_personality "$POSTED_PERSONALITY" \
    --arg personality_file "$PERSONALITY_FILE" \
    --arg engine_sha "$ENGINE_SHA" \
    --arg transcript_source "$transcript_source" \
    --arg agy_seconds "${agy_elapsed_s:-}" \
    --arg head_committed_at "${head_committed_at:-}" \
    --arg review_latency_seconds "$review_latency_seconds" \
    --arg required_checks_file "$REQUIRED_CHECKS_FILE" \
    --arg required_checks_sha256 "$required_checks_sha256" \
    --arg dry_run_bypass_ci "${DRY_RUN_BYPASS_CI:-}" \
    --arg agents_md_bytes "$agents_md_bytes" \
    --arg agents_md_sha256 "$agents_md_sha" \
    --arg prompt_bytes "$prompt_bytes" \
    --arg prompt_sha256 "$prompt_sha" \
    --arg response_bytes "$response_bytes" \
    --arg response_sha256 "$response_sha" \
    --arg agy_stderr_bytes "$stderr_bytes" \
    --arg agy_stderr_sha256 "$stderr_sha" \
    --argjson required_checks "$EFFECTIVE_REQUIRED_CHECKS_JSON" \
    '{
      repo: $repo,
      pr: ($pr | tonumber),
      head_sha: $head_sha,
      event: $event,
      generated_at: $generated_at,
      dry_run_out: $dry_run_out,
      posted_personality: $posted_personality,
      personality_file: $personality_file,
      engine_sha: $engine_sha,
      transcript_source: $transcript_source,
      agy_seconds: (if $agy_seconds == "" then null else ($agy_seconds | tonumber) end),
      head_pushed_at: (if $head_committed_at == "" then null else $head_committed_at end),
      review_latency_seconds: (if $review_latency_seconds == "" then null else ($review_latency_seconds | tonumber) end),
      required_checks_file: $required_checks_file,
      required_checks_sha256: $required_checks_sha256,
      dry_run_bypass_ci: $dry_run_bypass_ci,
      agents_md_bytes: ($agents_md_bytes | tonumber),
      agents_md_sha256: $agents_md_sha256,
      prompt_bytes: ($prompt_bytes | tonumber),
      prompt_sha256: $prompt_sha256,
      response_bytes: ($response_bytes | tonumber),
      response_sha256: $response_sha256,
      agy_stderr_bytes: ($agy_stderr_bytes | tonumber),
      agy_stderr_sha256: $agy_stderr_sha256,
      required_checks: $required_checks
    }' >"${output_file}.launch.json.tmp"
  secure_install_file "${output_file}.launch.json.tmp" "${output_file}.launch.json" || fatal "failed to write dry-run launch metadata with mode 0600"
  rm -f "${output_file}.launch.json.tmp"
  log "Dry run artifact written to $output_file"
}

write_research_review_artifact() {
  local output_file="$1"
  local num="$2"
  local head_sha="$3"
  local arm="$4"
  local personality_file="$5"
  local role="$6"
  local event="$7"
  local prompt_file="$8"
  local review_body="$9"
  local ci_state="${10:-}"
  local worktree_dir="${11:-}"
  local artifact_tmp agents_md_tmp agents_md_bytes agents_md_sha

  mkdir -p "$(dirname "$output_file")"
  chmod 700 "$(dirname "$output_file")" 2>/dev/null || true
  artifact_tmp=$(mktemp "$STATE_DIR/research-artifact.XXXXXX")
  agents_md_tmp=$(mktemp "$STATE_DIR/research-agents-md.XXXXXX")
  write_agents_md "$personality_file" "$agents_md_tmp" "$ci_state" "$head_sha" "$worktree_dir" || {
    rm -f "$artifact_tmp" "$agents_md_tmp"
    return 1
  }
  agents_md_bytes=$(wc -c <"$agents_md_tmp" | tr -d ' ')
  agents_md_sha=$(sha256sum "$agents_md_tmp" | awk '{print $1}')
  {
    printf 'GoobReview research artifact\n'
    printf 'Repository: %s\n' "$REPO"
    printf 'PR: #%s\n' "$num"
    printf 'Head SHA: %s\n' "$head_sha"
    printf 'Research arm: %s\n' "$arm"
    printf 'Artifact role: %s\n' "$role"
    printf 'Posted personality: %s\n' "$POSTED_PERSONALITY"
    printf 'Personality file: %s\n' "$personality_file"
    printf 'Parsed review event: %s\n' "$event"
    printf 'AGENTS.MD bytes: %s\n' "$agents_md_bytes"
    printf 'AGENTS.MD SHA256: %s\n' "$agents_md_sha"
    printf 'Generated at: %s\n' "$(date -Is)"
    printf '\n===== AGY AGENTS.MD START =====\n'
    append_bounded_file "$agents_md_tmp" "$MAX_ARTIFACT_BYTES" "research agents-md artifact"
    printf '\n===== AGY AGENTS.MD END =====\n'
    printf '\n===== AGY PROMPT PAYLOAD START =====\n'
    append_bounded_file "$prompt_file" "$MAX_ARTIFACT_BYTES" "research prompt artifact"
    printf '\n===== AGY PROMPT PAYLOAD END =====\n'
    printf '\n===== AGY RESPONSE START =====\n'
    printf '%s\n' "$review_body" | append_bounded_stdin "$MAX_ARTIFACT_BYTES" "research response artifact"
    printf '===== AGY RESPONSE END =====\n'
  } >"$artifact_tmp"

  install_bounded_scanned_artifact "$artifact_tmp" "$output_file" "$MAX_ARTIFACT_BYTES" "research artifact" || {
    rm -f "$agents_md_tmp"
    return 1
  }
  rm -f "$agents_md_tmp"
}

research_personality_file_for_arm() {
  case "$1" in
    none) printf '%s\n' "$CONFIG_DIR/personalities/control.md" ;;
    linus) printf '%s\n' "$CONFIG_DIR/personalities/linus.md" ;;
    angry) printf '%s\n' "$CONFIG_DIR/personalities/angry.md" ;;
    *) return 1 ;;
  esac
}

resolve_research_capture_state() {
  RESEARCH_CAPTURE_ENABLED=0
  RESEARCH_REPO_VISIBILITY="unknown"

  [ "$RESEARCH_CONSENT" = "1" ] || return 0
  if [ -n "$DRY_RUN" ] || [ -n "$RENDER_PROMPT_ONLY" ]; then
    log "Research consent is enabled, but paired research capture only runs for live reviews"
    return 0
  fi
  case "$POSTED_PERSONALITY" in
    none|angry) ;;
    *)
      log "Research consent is enabled, but paired research capture requires REVIEWER_POSTED_PERSONALITY=none or angry"
      return 0
      ;;
  esac

  if ! repo_json=$(github_api_get "repos/$REPO" 2>>"$LOG_FILE"); then
    log "Research consent is enabled, but repo visibility could not be verified; paired research capture disabled"
    return 0
  fi
  repo_private=$(printf '%s\n' "$repo_json" | jq -r 'if has("private") then .private else true end')
  case "$repo_private" in
    false)
      RESEARCH_REPO_VISIBILITY="public"
      RESEARCH_CAPTURE_ENABLED=1
      ;;
    *)
      RESEARCH_REPO_VISIBILITY="private"
      if [ "$RESEARCH_ALLOW_PRIVATE" = "1" ]; then
        RESEARCH_CAPTURE_ENABLED=1
      else
        log "Research consent is enabled, but paired research capture is disabled for private repositories (set REVIEWER_RESEARCH_ALLOW_PRIVATE=1 to opt in)"
      fi
      ;;
  esac
}

capture_research_pair() {
  local num="$1"
  local head_sha="$2"
  local ci_state="$3"
  local review_worktree="$4"
  local pr_metadata_json="$5"
  local bot_reviews_json="$6"
  local prior_bot_threads_json="$7"
  local posted_prompt_file="$8"
  local posted_review="$9"
  local posted_event="${10}"
  local posted_transcript_source="${11:-agy_failed}"
  local posted_resolved_model_label="${12:-}"
  local run_id run_dir posted_arm counterfactual_arm posted_dir counterfactual_dir
  local posted_file counterfactual_file manifest_tmp counterfactual_err counterfactual_prompt_file
  local counterfactual_personality_file counterfactual_review counterfactual_event counterfactual_transcript_source
  local counterfactual_resolved_model_label=""
  local generated_at generated_at_epoch review_latency_seconds required_checks_sha256 posted_personality_file

  [ "$RESEARCH_CAPTURE_ENABLED" = "1" ] || return 0

  posted_arm="$POSTED_PERSONALITY"
  case "$posted_arm" in
    none) counterfactual_arm="angry" ;;
    angry) counterfactual_arm="none" ;;
    *) return 0 ;;
  esac

  run_id="$(date -u +%Y%m%dT%H%M%SZ)-pr-${num}-${head_sha}"
  run_dir="$STATE_DIR/research-runs/$run_id/pr-$num"
  posted_dir="$run_dir/$posted_arm"
  counterfactual_dir="$run_dir/$counterfactual_arm"
  posted_file="$posted_dir/artifact.txt"
  counterfactual_file="$counterfactual_dir/artifact.txt"
  generated_at="$(date -Is)"
  generated_at_epoch="$(date +%s)"
  review_latency_seconds=""
  if [ -n "$head_committed_at" ]; then
    review_latency_seconds=$(jq -rn --arg d "$head_committed_at" --argjson now "$generated_at_epoch" '$now - ($d | fromdateiso8601)')
  fi
  required_checks_sha256=$(sha256sum "$REQUIRED_CHECKS_FILE" | awk '{print $1}')
  posted_personality_file="$PERSONALITY_FILE"
  counterfactual_personality_file="$(research_personality_file_for_arm "$counterfactual_arm")" || return 0

  if ! with_prompt_personality "$posted_arm" write_research_review_artifact "$posted_file" "$num" "$head_sha" "$posted_arm" "$posted_personality_file" "posted" "$posted_event" "$posted_prompt_file" "$posted_review" "$ci_state" "$review_worktree"; then
    log "PR #$num@$head_sha: failed to write posted research artifact"
    return 0
  fi

  counterfactual_err=$(mktemp "$STATE_DIR/research-agy.$num.err.XXXXXX")
  counterfactual_prompt_file=$(mktemp "$STATE_DIR/research-prompt.$num.XXXXXX")
  if ! with_prompt_personality "$counterfactual_arm" build_review_prompt "$num" "$counterfactual_prompt_file" "$ci_state" "$head_sha" "$review_worktree" "$pr_metadata_json" "$bot_reviews_json" "$prior_bot_threads_json"; then
    log "PR #$num@$head_sha: failed to build counterfactual research prompt for $counterfactual_arm"
    rm -f "$counterfactual_err" "$counterfactual_prompt_file"
    return 0
  fi
  local counterfactual_started_at counterfactual_agy_s
  counterfactual_started_at=$(date +%s)
  if counterfactual_review=$(run_agy_review "$counterfactual_prompt_file" "$counterfactual_err" "$review_worktree" "$counterfactual_personality_file" "$ci_state" "$head_sha" "$counterfactual_arm"); then
    counterfactual_transcript_source=$(agy_transcript_source)
    counterfactual_resolved_model_label=$(agy_resolved_model_label)
    cat "$counterfactual_err" >>"$LOG_FILE"
    if [ -z "${counterfactual_review// }" ]; then
      counterfactual_event="EMPTY_RESPONSE"
    elif ! counterfactual_event=$(printf '%s' "$counterfactual_review" | review_verdict_event); then
      counterfactual_event="INVALID"
    fi
  else
    counterfactual_transcript_source=$(agy_transcript_source)
    counterfactual_resolved_model_label=$(agy_resolved_model_label)
    cat "$counterfactual_err" >>"$LOG_FILE"
    counterfactual_event="AGY_FAILED"
    counterfactual_review=$(cat "$counterfactual_err")
  fi
  counterfactual_agy_s=$(( $(date +%s) - counterfactual_started_at ))

  if ! with_prompt_personality "$counterfactual_arm" write_research_review_artifact "$counterfactual_file" "$num" "$head_sha" "$counterfactual_arm" "$counterfactual_personality_file" "counterfactual" "$counterfactual_event" "$counterfactual_prompt_file" "$counterfactual_review" "$ci_state" "$review_worktree"; then
    log "PR #$num@$head_sha: failed to write counterfactual research artifact"
    rm -f "$counterfactual_err" "$counterfactual_prompt_file"
    return 0
  fi
  rm -f "$counterfactual_err" "$counterfactual_prompt_file"

  manifest_tmp=$(mktemp "$STATE_DIR/research-manifest.XXXXXX")
  local research_eligible="public-consented"
  [ "$RESEARCH_REPO_VISIBILITY" = "private" ] && research_eligible="private-consented"
  jq -n \
    --arg repo "$REPO" \
    --arg pr "$num" \
    --arg head_sha "$head_sha" \
    --arg generated_at "$generated_at" \
    --arg head_committed_at "${head_committed_at:-}" \
    --arg review_latency_seconds "$review_latency_seconds" \
    --arg posted_personality "$POSTED_PERSONALITY" \
    --arg posted_arm "$posted_arm" \
    --arg counterfactual_arm "$counterfactual_arm" \
    --arg posted_event "$posted_event" \
    --arg counterfactual_event "$counterfactual_event" \
    --arg posted_artifact "$posted_file" \
    --arg counterfactual_artifact "$counterfactual_file" \
    --arg posted_personality_file "$posted_personality_file" \
    --arg counterfactual_personality_file "$counterfactual_personality_file" \
    --arg requested_model "$AGY_MODEL" \
    --arg posted_resolved_model_label "$posted_resolved_model_label" \
    --arg counterfactual_resolved_model_label "$counterfactual_resolved_model_label" \
    --arg engine_sha "$ENGINE_SHA" \
    --arg posted_transcript_source "$posted_transcript_source" \
    --arg counterfactual_transcript_source "$counterfactual_transcript_source" \
    --arg posted_agy_seconds "${agy_elapsed_s:-}" \
    --arg counterfactual_agy_seconds "$counterfactual_agy_s" \
    --arg ci_state "$ci_state" \
    --arg required_checks_file "$REQUIRED_CHECKS_FILE" \
    --arg required_checks_sha256 "$required_checks_sha256" \
    --arg repo_visibility "$RESEARCH_REPO_VISIBILITY" \
    --arg research_eligible "$research_eligible" \
    --argjson required_checks "$EFFECTIVE_REQUIRED_CHECKS_JSON" \
    '{
      repo: $repo,
      pr: ($pr | tonumber),
      head_sha: $head_sha,
      generated_at: $generated_at,
      posted_personality: $posted_personality,
      posted_arm: $posted_arm,
      counterfactual_arm: $counterfactual_arm,
      posted_event: $posted_event,
      counterfactual_event: $counterfactual_event,
      posted_artifact: $posted_artifact,
      counterfactual_artifact: $counterfactual_artifact,
      personality_files: {
        posted: $posted_personality_file,
        counterfactual: $counterfactual_personality_file
      },
      requested_model: $requested_model,
      resolved_model_label: {
        posted: (if $posted_resolved_model_label == "" then null else $posted_resolved_model_label end),
        counterfactual: (if $counterfactual_resolved_model_label == "" then null else $counterfactual_resolved_model_label end)
      },
      engine_sha: $engine_sha,
      posted_transcript_source: $posted_transcript_source,
      counterfactual_transcript_source: $counterfactual_transcript_source,
      posted_agy_seconds: (if $posted_agy_seconds == "" then null else ($posted_agy_seconds | tonumber) end),
      counterfactual_agy_seconds: ($counterfactual_agy_seconds | tonumber),
      head_pushed_at: (if $head_committed_at == "" then null else $head_committed_at end),
      review_latency_seconds: (if $review_latency_seconds == "" then null else ($review_latency_seconds | tonumber) end),
      ci_state: $ci_state,
      required_checks_file: $required_checks_file,
      required_checks_sha256: $required_checks_sha256,
      required_checks: $required_checks,
      repo_visibility: $repo_visibility,
      research_eligible: $research_eligible
    }' >"$manifest_tmp"
  secure_install_file "$manifest_tmp" "$run_dir/manifest.json" || log "PR #$num@$head_sha: failed to write research manifest"
  rm -f "$manifest_tmp"
  log "PR #$num@$head_sha: wrote paired research artifacts to $run_dir"
}

if [ -z "$RENDER_PROMPT_ONLY" ] && [ -z "$IGNORE_AGY_BACKOFF" ]; then
  if remaining=$(agy_backoff_remaining); then
    log "Antigravity quota backoff active for ${remaining}s"
    exit 0
  fi
fi

# agy will run this tick; flag any home-directory context files it would
# auto-load as trusted instructions outside the daemon's prompt (issue #106).
# With REVIEWER_REFUSE_ON_HOME_CONTEXT=1, fail closed for the whole tick rather
# than review with that content in agy's context.
if [ -z "$RENDER_PROMPT_ONLY" ]; then
  warn_home_agy_context_files
  if should_refuse_for_home_context; then
    log "Refusing this tick: home-directory agy context files present and REVIEWER_REFUSE_ON_HOME_CONTEXT=1 (security issue #106); remove them or unset the flag"
    exit 0
  fi
fi

GH_TOKEN=$("$SCRIPT_DIR/get-installation-token.sh" token 2>>"$LOG_FILE") || fatal "failed to mint installation token"
export GH_TOKEN
if [ -z "${REVIEWER_APP_SLUG:-}" ]; then
  REVIEWER_APP_SLUG=$("$SCRIPT_DIR/get-installation-token.sh" slug 2>>"$LOG_FILE") || fatal "failed to fetch app slug"
fi
BOT_LOGIN="${REVIEWER_APP_SLUG}[bot]"
BOT_AUTHOR="app/${REVIEWER_APP_SLUG}"
resolve_research_capture_state

if [ -n "$ONLY_PR" ] && { [ -n "$DRY_RUN" ] || [ -n "$RENDER_PROMPT_ONLY" ]; }; then
  if ! PRS=$(github_api_get "repos/$REPO/pulls/$ONLY_PR" 2>>"$LOG_FILE" |
    pull_request_queue_rows); then
    log "Failed to fetch requested PR #$ONLY_PR, will retry next tick"
    exit 0
  fi
else
  if ! PRS=$(github_api_paginate_array "repos/$REPO/pulls?state=open" 2>>"$LOG_FILE" |
    pull_request_queue_rows); then
    log "Failed to list open PRs, will retry next tick"
    exit 0
  fi
fi

review_actions=0
review_attempts=0

record_review_failure_and_log() {
  local num="$1"
  local head_sha="$2"
  local message="$3"
  local attempts

  conclude_review_check_run_signal neutral "Review attempt failed" \
    "$message. The daemon will retry on a later tick."
  if [ -z "$DRY_RUN" ] && [ -z "$RENDER_PROMPT_ONLY" ]; then
    attempts=$(review_attempts_record review-failure "$num" "$head_sha")
    if [ "$FAILURE_MAX_ATTEMPTS" -eq 0 ]; then
      log "$message, will retry next tick (failure cap disabled)"
    elif [ "$attempts" -ge "$FAILURE_MAX_ATTEMPTS" ]; then
      log "$message; reached failure cap ($attempts/$FAILURE_MAX_ATTEMPTS), skipping until the PR head changes"
    else
      log "$message, will retry next tick ($attempts/$FAILURE_MAX_ATTEMPTS)"
    fi
  else
    log "$message, will retry next tick"
  fi
}

# Shared tail for model output that cannot be posted (an empty response or a
# missing/invalid final review event): record the capped invalid-output
# attempt on a live tick and log one line whose suffix reflects the cap state.
record_invalid_output_and_log() {
  local num="$1"
  local head_sha="$2"
  local message="$3"
  local invalid_artifact="$4"
  local invalid_attempts

  if [ -z "$DRY_RUN" ]; then
    invalid_attempts=$(review_attempts_record invalid-verdict "$num" "$head_sha")
    if [ "$INVALID_VERDICT_MAX_ATTEMPTS" -eq 0 ]; then
      log "$message; wrote $invalid_artifact; will retry next tick (invalid-output cap disabled)"
    elif [ "$invalid_attempts" -ge "$INVALID_VERDICT_MAX_ATTEMPTS" ]; then
      log "$message; wrote $invalid_artifact; reached invalid-output cap ($invalid_attempts/$INVALID_VERDICT_MAX_ATTEMPTS)"
    else
      log "$message; wrote $invalid_artifact; will retry next tick ($invalid_attempts/$INVALID_VERDICT_MAX_ATTEMPTS)"
    fi
  else
    log "$message; wrote $invalid_artifact; will retry next tick"
  fi
}

# Post an "eyes" reaction to signal the daemon has started working this PR, so a
# PR author can tell "not reached yet" from "in progress". Reactions are silent
# (no watcher notifications) and idempotent per user+emoji, so re-posting on a
# new tick is a natural no-op. Best-effort: a failed POST is logged and never
# blocks a review. Callers must only invoke this on a live tick -- never in
# dry-run or prompt-only mode, which must never touch GitHub.
post_review_started_reaction() {
  local num="$1"

  if github_api_post_json "repos/$REPO/issues/$num/reactions" '{"content":"eyes"}' >/dev/null 2>>"$LOG_FILE"; then
    log "Signaled review start with eyes reaction on PR #$num"
  else
    log "Failed to add review-started reaction on PR #$num (continuing)"
  fi
}

# Post a "confused" reaction to signal the daemon hit an Antigravity rate
# limit while working this PR -- distinct from "eyes" (in progress), this
# means "stuck." Reactions are idempotent per user+emoji, so re-posting on
# every backoff-triggering retry is a silent no-op rather than a pile of
# duplicates. Best-effort: a failed POST is logged and never blocks the
# retry. Callers must only invoke this on a live tick.
post_agy_backoff_reaction() {
  local num="$1"

  if github_api_post_json "repos/$REPO/issues/$num/reactions" '{"content":"confused"}' >/dev/null 2>>"$LOG_FILE"; then
    log "Signaled Antigravity rate limit with confused reaction on PR #$num"
  else
    log "Failed to add rate-limit reaction on PR #$num (continuing)"
  fi
}

# Open the daemon's own "goobreview" check run on the PR head as the daemon
# commits to working the PR this tick -- the idiomatic per-commit "a bot is
# working on this" surface, visible in the merge box and Checks tab alongside
# CI. Requires the App's checks:write permission; best-effort like reactions:
# a failed create (e.g. an installation that has not approved the permission)
# is logged and never blocks the review. Callers must only invoke this on a
# live tick.
begin_review_check_run_signal() {
  local num="$1"
  local head_sha="$2"

  REVIEW_CHECK_RUN_ID=""
  [ "$CHECK_RUN_SIGNAL" = "1" ] || return 0
  if REVIEW_CHECK_RUN_ID=$(github_create_review_check_run "$head_sha" 2>>"$LOG_FILE"); then
    log "Opened review check run $REVIEW_CHECK_RUN_ID on PR #$num@$head_sha"
  else
    REVIEW_CHECK_RUN_ID=""
    log "Failed to open review check run on PR #$num@$head_sha (continuing; needs the App's checks:write permission)"
  fi
}

# Conclude the check run opened by begin_review_check_run_signal. A no-op when
# none is open, so failure paths that run before the daemon commits to a PR
# (or on dry-run/prompt-only ticks, which never open one) never touch GitHub.
# Clears the id so a check run is concluded at most once.
conclude_review_check_run_signal() {
  local conclusion="$1"
  local title="$2"
  local summary="$3"

  [ -n "${REVIEW_CHECK_RUN_ID:-}" ] || return 0
  if github_conclude_review_check_run "$REVIEW_CHECK_RUN_ID" "$conclusion" "$title" "$summary" 2>>"$LOG_FILE"; then
    log "Concluded review check run $REVIEW_CHECK_RUN_ID as $conclusion"
  else
    log "Failed to conclude review check run $REVIEW_CHECK_RUN_ID (continuing)"
  fi
  REVIEW_CHECK_RUN_ID=""
}

# One PR through the full pipeline: eligibility and cap gates, the CI gate,
# snapshot and prompt assembly, the agy invocation, verdict parsing, and
# posting with side effects. Returns 0 to move on to the next PR and 10 to
# stop the tick (REVIEWER_MAX_PRS or REVIEWER_MAX_ATTEMPTS reached).
review_one_pr() {
  local num="$1"
  local author="$2"
  local head_sha="$3"
  local draft="$4"
  local pr_json_b64="$5"
  local pr_metadata_json skip_reason bot_reviews_json requested_review existing
  local failure_attempts invalid_attempts invalid_artifact ci_state ci_summary ci_failure_body
  local prompt_tmp review_worktree review_threads_json unresolved_bot_threads_json prompt_thread_handle_map_json
  local agy_err_tmp agy_started_at agy_review_status review verdict_line event review_body
  local current_pr_json current_head_sha inline_comments_json inline_comment_count scope_downgraded scoped_event
  local filtered_body thinking_trace_file trace_block formatted_body body
  local resolved_thread_handles still_open_thread_replies auto_resolve_threads auto_resolved_threads still_open_replied
  local review_check_conclusion
  # Read by write_dry_run_artifact and capture_research_pair through bash's
  # dynamic scoping, so they must always be initialized here.
  local head_committed_at="" agy_elapsed_s="" transcript_source="" resolved_model_label=""
  REVIEW_CHECK_RUN_ID=""
  pr_metadata_json=""
  if [ -n "${pr_json_b64:-}" ]; then
    pr_metadata_json=$(printf '%s' "$pr_json_b64" | base64 -d) || pr_metadata_json=""
  fi
  if skip_reason=$(reviewer_pr_skip_reason "$num" "$author" "$head_sha" "${draft:-false}" "$BOT_LOGIN" "$EXTRA_SKIP_USER" "$ONLY_PR" "$BOT_AUTHOR"); then
    log "$skip_reason"
    return 0
  fi

  if [ "$review_actions" -ge "$MAX_PRS" ]; then
    log "Reached REVIEWER_MAX_PRS=$MAX_PRS, stopping this tick"
    return 10
  fi

  if ! bot_reviews_json=$(github_api_paginate_array "repos/$REPO/pulls/$num/reviews" 2>>"$LOG_FILE" |
    jq -s --arg bot "$BOT_LOGIN" --arg bot_author "$BOT_AUTHOR" \
      '[.[] | select(.user.login == $bot or .user.login == $bot_author)]'); then
    log "PR #$num@$head_sha: failed to read existing reviews, will retry next tick"
    return 0
  fi

  if [ -z "$RENDER_PROMPT_ONLY" ] && [ -z "$DRY_RUN" ]; then
    requested_review=0
    if pr_has_requested_reviewer "$pr_metadata_json" "$BOT_LOGIN" "$BOT_AUTHOR"; then
      requested_review=1
    fi
    existing=$(printf '%s\n' "$bot_reviews_json" |
      jq --arg head "$head_sha" '[.[] | select(.commit_id == $head)] | length')
    case "$existing" in
      ''|*[!0-9]*)
        log "PR #$num@$head_sha: existing review query returned unexpected count '$existing', will retry next tick"
        return 0
        ;;
    esac
    if [ "$existing" -gt 0 ]; then
      if [ "$requested_review" -eq 1 ]; then
        log "PR #$num@$head_sha already reviewed by $BOT_LOGIN, but review was re-requested; reviewing again"
      else
        log "PR #$num@$head_sha already reviewed by $BOT_LOGIN, skipping"
        return 0
      fi
    fi
  fi

  if [ "$review_attempts" -ge "$MAX_ATTEMPTS" ]; then
    log "Reached REVIEWER_MAX_ATTEMPTS=$MAX_ATTEMPTS after $review_attempts attempted review(s), stopping this tick"
    return 10
  fi

  # Both per-head caps must be checked here -- before the attempt budget is
  # spent and before any GitHub side effects (eyes reaction, check run).
  # A capped PR skipped after the increment would consume REVIEWER_MAX_ATTEMPTS
  # every tick and starve every PR sorted behind it until its head changed.
  if [ -z "$RENDER_PROMPT_ONLY" ] && [ -z "$DRY_RUN" ] && [ "$FAILURE_MAX_ATTEMPTS" -gt 0 ]; then
    failure_attempts=$(review_attempts_count review-failure "$num" "$head_sha")
    if [ "$failure_attempts" -ge "$FAILURE_MAX_ATTEMPTS" ]; then
      log "PR #$num@$head_sha: review failures reached REVIEWER_FAILURE_MAX_ATTEMPTS=$FAILURE_MAX_ATTEMPTS; skipping until the PR head changes"
      return 0
    fi
  fi
  if [ -z "$RENDER_PROMPT_ONLY" ] && [ -z "$DRY_RUN" ] && [ "$INVALID_VERDICT_MAX_ATTEMPTS" -gt 0 ]; then
    invalid_attempts=$(review_attempts_count invalid-verdict "$num" "$head_sha")
    if [ "$invalid_attempts" -ge "$INVALID_VERDICT_MAX_ATTEMPTS" ]; then
      invalid_artifact=$(invalid_verdict_artifact_path "$num" || true)
      log "PR #$num@$head_sha: invalid agy output reached REVIEWER_INVALID_VERDICT_MAX_ATTEMPTS=$INVALID_VERDICT_MAX_ATTEMPTS; skipping until the PR head changes (last artifact: ${invalid_artifact:-unavailable})"
      return 0
    fi
  fi
  review_attempts=$((review_attempts + 1))

  if ! ci_state=$(REQUIRED_CHECKS_JSON="$EFFECTIVE_REQUIRED_CHECKS_JSON" bash "$SCRIPT_DIR/check-ci.sh" "$REPO" "$head_sha" "$REQUIRED_CHECKS_FILE" 2>>"$LOG_FILE"); then
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to read CI check-runs"
    return 0
  fi

  case "$ci_state" in
    success)
      ;;
    pending|incomplete)
      if [ -n "$DRY_RUN" ] && [ "$DRY_RUN_BYPASS_CI" = "1" ]; then
        log "PR #$num@$head_sha: dry run bypassing CI state=$ci_state"
        ci_state="dry-run-bypassed-$ci_state"
      else
        if [ "$ci_state" = "incomplete" ]; then
          log "PR #$num@$head_sha: required checks are missing from complete GitHub check-run data (state=incomplete), will retry next tick"
        else
          log "PR #$num@$head_sha: CI not yet terminal (state=$ci_state), will retry next tick"
        fi
        return 0
      fi
      ;;
    failing)
      if [ -n "$DRY_RUN" ] && [ "$DRY_RUN_BYPASS_CI" = "1" ]; then
        log "PR #$num@$head_sha: dry run bypassing CI state=failing"
        ci_state="dry-run-bypassed-failing"
      else
        if [ -n "$RENDER_PROMPT_ONLY" ]; then
          log "PR #$num@$head_sha: CI is failing, so no agy prompt would be sent"
          review_actions=$((review_actions + 1))
          return 0
        fi
        log "PR #$num@$head_sha: CI is failing, posting REQUEST_CHANGES without agy"
        ci_summary=$(github_check_runs_summary "$head_sha" 2>>"$LOG_FILE" || true)
        ci_failure_body=$(cat <<EOF
CI is failing on this commit. Fix the failing job(s) and push a new commit - I will re-review on the new head SHA.

\`\`\`
${ci_summary:-No check summary available.}
\`\`\`

---
*Auto-generated by the reviewer daemon. CI was non-green at review time, so no agy call was made.*
EOF
)
        if [ -n "$DRY_RUN" ]; then
          log "Dry run: would post REQUEST_CHANGES (CI failure) on PR #$num@$head_sha"
          review_actions=$((review_actions + 1))
          return 0
        fi
        post_review_started_reaction "$num"
        begin_review_check_run_signal "$num" "$head_sha"
        if post_review "$num" "REQUEST_CHANGES" "$ci_failure_body" "$head_sha" '[]'; then
          review_attempts_clear review-failure "$num" "$head_sha"
          log "Posted REQUEST_CHANGES (CI failure) on PR #$num@$head_sha"
          conclude_review_check_run_signal failure "Review posted: REQUEST_CHANGES" \
            "Required CI checks were failing at review time, so changes were requested without invoking the reviewer model. A new head SHA gets a fresh review."
          review_actions=$((review_actions + 1))
        else
          record_review_failure_and_log "$num" "$head_sha" "Failed to post REQUEST_CHANGES (CI failure) on PR #$num@$head_sha"
        fi
        return 0
      fi
      ;;
    *)
      log "PR #$num@$head_sha: unexpected CI state '$ci_state', will retry next tick"
      return 0
      ;;
  esac

  log "Reviewing PR #$num@$head_sha"

  if [ -z "$RENDER_PROMPT_ONLY" ] && [ -z "$DRY_RUN" ]; then
    post_review_started_reaction "$num"
    begin_review_check_run_signal "$num" "$head_sha"
  fi

  head_committed_at=""
  if [ -z "$RENDER_PROMPT_ONLY" ]; then
    if head_commit_json=$(github_api_get "repos/$REPO/commits/$head_sha" 2>>"$LOG_FILE"); then
      head_committed_at=$(printf '%s\n' "$head_commit_json" | jq -r '.commit.committer.date // empty')
    fi
  fi

  prompt_tmp=$(mktemp "$STATE_DIR/prompt.$num.XXXXXX")

  if ! review_worktree=$(prepare_review_worktree "$head_sha"); then
    rm -f "$prompt_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to prepare PR-head worktree"
    return 0
  fi

  if ! review_threads_json=$(github_pr_review_threads_json "$num" 2>>"$LOG_FILE"); then
    rm -f "$prompt_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to read existing review threads"
    return 0
  fi
  if ! unresolved_bot_threads_json=$(github_unresolved_bot_review_threads_json "$review_threads_json" "$BOT_LOGIN" "$BOT_AUTHOR"); then
    rm -f "$prompt_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to filter existing bot review threads"
    return 0
  fi
  if ! prompt_thread_handle_map_json=$(printf '%s\n' "$unresolved_bot_threads_json" | github_review_thread_handle_map_json); then
    rm -f "$prompt_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to map bot review thread handles"
    return 0
  fi

  if ! build_review_prompt "$num" "$prompt_tmp" "$ci_state" "$head_sha" "$review_worktree" "$pr_metadata_json" "$bot_reviews_json" "$unresolved_bot_threads_json"; then
    rm -f "$prompt_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to build agy prompt"
    return 0
  fi

  if [ -n "$RENDER_PROMPT_ONLY" ]; then
    if [ -n "$PROMPT_OUT" ] && [ "$PROMPT_OUT" != "-" ]; then
      secure_install_file "$prompt_tmp" "$PROMPT_OUT" || fatal "failed to write prompt output with mode 0600: $PROMPT_OUT"
      log "Rendered prompt for PR #$num@$head_sha to $PROMPT_OUT"
    else
      cat "$prompt_tmp"
      log "Rendered prompt for PR #$num@$head_sha to stdout"
    fi
    rm -f "$prompt_tmp"
    review_actions=$((review_actions + 1))
    return 0
  fi

  agy_err_tmp=$(mktemp "$STATE_DIR/agy.$num.err.XXXXXX")
  agy_started_at=$(date +%s)
  agy_review_status=0
  review=$(run_agy_review "$prompt_tmp" "$agy_err_tmp" "$review_worktree" "$PERSONALITY_FILE" "$ci_state" "$head_sha") || agy_review_status=$?
  agy_elapsed_s=$(( $(date +%s) - agy_started_at ))
  transcript_source=$(agy_transcript_source)
  resolved_model_label=$(agy_resolved_model_label)
  if [ "$agy_review_status" -ne 0 ]; then
    cat "$agy_err_tmp" >> "$LOG_FILE"
    if [ -n "$DRY_RUN" ]; then
      write_dry_run_artifact "$num" "$head_sha" "AGY_FAILED" "$prompt_tmp" "$(cat "$agy_err_tmp")" '[]' 0 "$agy_err_tmp" "$review_worktree" "$ci_state" "$transcript_source"
    fi
    if set_agy_quota_backoff "$agy_err_tmp"; then
      # A quota-exhausted agy call is not a broken PR or a broken prompt --
      # it is expected to succeed once the backoff clears, so it must not
      # spend the same failure-attempt budget as a genuine agy error. Left
      # uncapped, a rate limit that outlasts a few backoff cycles would hit
      # REVIEWER_FAILURE_MAX_ATTEMPTS and the daemon would silently abandon
      # that head SHA forever -- no review posted, no further retries until
      # the author happens to push again, at which point the review would
      # cover both the missed push and the new one at once.
      [ -n "$DRY_RUN" ] || post_agy_backoff_reaction "$num"
      conclude_review_check_run_signal neutral "Rate limited" \
        "The Antigravity model quota is exhausted. The review is queued and retries automatically once the backoff clears."
      log "PR #$num@$head_sha: agy quota exhausted; not counted toward the failure cap, will retry once backoff clears"
    else
      record_review_failure_and_log "$num" "$head_sha" "agy failed for PR #$num@$head_sha"
    fi
    rm -f "$prompt_tmp" "$agy_err_tmp"
    return 0
  fi
  cat "$agy_err_tmp" >> "$LOG_FILE"

  if [ -z "${review// }" ]; then
    if set_agy_quota_backoff "$agy_err_tmp"; then
      # agy can hit quota exhaustion, retry internally, and still exit 0 with
      # an empty body -- this is the same transient condition the non-zero-exit
      # quota path handles below, so it must not spend the invalid-verdict
      # budget either (see the rationale on the exit-status branch above).
      write_dry_run_artifact "$num" "$head_sha" "AGY_QUOTA" "$prompt_tmp" "$review" '[]' 0 "$agy_err_tmp" "$review_worktree" "$ci_state" "$transcript_source"
      [ -n "$DRY_RUN" ] || post_agy_backoff_reaction "$num"
      conclude_review_check_run_signal neutral "Rate limited" \
        "The Antigravity model quota is exhausted. The review is queued and retries automatically once the backoff clears."
      log "PR #$num@$head_sha: agy quota exhausted (empty response); not counted toward the failure cap, will retry once backoff clears"
      rm -f "$prompt_tmp" "$agy_err_tmp"
      return 0
    fi
    invalid_artifact=$(write_invalid_verdict_artifact "$num" "$head_sha" "EMPTY_RESPONSE" "$review")
    write_dry_run_artifact "$num" "$head_sha" "EMPTY_RESPONSE" "$prompt_tmp" "$review" '[]' 0 "$agy_err_tmp" "$review_worktree" "$ci_state" "$transcript_source"
    rm -f "$prompt_tmp" "$agy_err_tmp"
    conclude_review_check_run_signal neutral "Empty reviewer output" \
      "The reviewer model returned an empty response. The daemon will retry on a later tick."
    record_invalid_output_and_log "$num" "$head_sha" "agy returned empty for PR #$num@$head_sha" "$invalid_artifact"
    return 0
  fi

  if ! event=$(printf '%s' "$review" | review_verdict_event); then
    invalid_artifact=$(write_invalid_verdict_artifact "$num" "$head_sha" "INVALID_VERDICT" "$review")
    write_dry_run_artifact "$num" "$head_sha" "INVALID" "$prompt_tmp" "$review" '[]' 0 "$agy_err_tmp" "$review_worktree" "$ci_state" "$transcript_source"
    rm -f "$prompt_tmp" "$agy_err_tmp"
    conclude_review_check_run_signal neutral "Invalid reviewer output" \
      "The reviewer model did not emit a valid final review event. The daemon will retry on a later tick."
    verdict_line=$(printf '%s' "$review" | review_last_nonempty_line)
    record_invalid_output_and_log "$num" "$head_sha" "PR #$num@$head_sha: agy did not emit a valid final GitHub review event (got: $verdict_line)" "$invalid_artifact"
    return 0
  fi
  if [ -z "$DRY_RUN" ]; then
    review_attempts_clear invalid-verdict "$num" "$head_sha"
  fi

  review_body=$(printf '%s' "$review" | review_body_before_verdict | review_demote_oversized_suggestions)

  if [ -z "$DRY_RUN" ]; then
    if ! current_pr_json=$(github_api_get "repos/$REPO/pulls/$num" 2>>"$LOG_FILE"); then
      rm -f "$prompt_tmp" "$agy_err_tmp"
      record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to re-read PR head before posting review"
      return 0
    fi
    current_head_sha=$(printf '%s\n' "$current_pr_json" | jq -r '.head.sha // empty')
    if [ "$current_head_sha" != "$head_sha" ]; then
      rm -f "$prompt_tmp" "$agy_err_tmp"
      log "PR #$num@$head_sha: head advanced to $current_head_sha before posting; discarding reviewed result"
      conclude_review_check_run_signal neutral "Superseded" \
        "The PR head advanced while the review was being drafted. The new head SHA gets a fresh review."
      return 0
    fi
    if ! review_threads_json=$(github_pr_review_threads_json "$num" 2>>"$LOG_FILE"); then
      rm -f "$prompt_tmp" "$agy_err_tmp"
      record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to re-read review threads before posting review"
      return 0
    fi
    if ! unresolved_bot_threads_json=$(github_unresolved_bot_review_threads_json "$review_threads_json" "$BOT_LOGIN" "$BOT_AUTHOR"); then
      rm -f "$prompt_tmp" "$agy_err_tmp"
      record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to filter latest bot review threads before posting review"
      return 0
    fi
  fi

  if ! inline_comments_json=$(review_inline_comments_json "$num" "$review_body" "$review_worktree" "$head_sha" "$REPO"); then
    rm -f "$prompt_tmp" "$agy_err_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to resolve inline review anchors"
    return 0
  fi
  scope_downgraded=0
  scoped_event=$(review_event_after_scope_guard "$event" "$inline_comments_json") || {
    rm -f "$prompt_tmp" "$agy_err_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to evaluate inline review scope"
    return 0
  }
  if [ "$event" = "REQUEST_CHANGES" ] && [ "$scoped_event" = "COMMENT" ]; then
    log "PR #$num@$head_sha: downgraded REQUEST_CHANGES to COMMENT because all anchored findings target pre-existing or context lines"
    scope_downgraded=1
  fi
  event="$scoped_event"

  filtered_body=$(printf '%s\n' "$review_body" |
    review_body_without_promoted_sections "$inline_comments_json" |
    review_strip_dangling_finding_intro |
    review_rewrite_snapshot_file_links "$head_sha" "$REPO" "$review_worktree")
  inline_comment_count=$(printf '%s\n' "$inline_comments_json" | jq 'length') || {
    rm -f "$prompt_tmp" "$agy_err_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to count resolved inline review comments"
    return 0
  }
  if [ -z "$(printf '%s' "$filtered_body" | tr -d '[:space:]')" ] && [ "$inline_comment_count" -gt 0 ]; then
    filtered_body=$(review_inline_summary_body "$event" "$inline_comment_count")
  fi
  if [ "$scope_downgraded" -eq 1 ]; then
    filtered_body=$(cat <<EOF
$filtered_body

[goobreview: posted as COMMENT because all anchored findings resolved to pre-existing or context lines, so they were not treated as blocking for this PR.]
EOF
)
  fi
  thinking_trace_file="${RUNTIME_STATE_DIR:-$STATE_DIR/runtime}/agy-runtime/thinking.trace"
  if trace_block=$(review_trace_details_block "$thinking_trace_file" "$head_sha" "$REPO" "$review_worktree"); then
    formatted_body=$(review_body_with_trace_prefix "$trace_block" "$filtered_body")
  else
    formatted_body=$(printf '%s\n' "$filtered_body" | review_trace_to_details "$head_sha" "$REPO" "$review_worktree")
  fi
  body=$(cat <<EOF
$formatted_body

---
$(review_footer_note "${resolved_model_label:-$AGY_MODEL}" "${agy_elapsed_s:-0}" "$ENGINE_SHA")
EOF
)

  resolved_thread_handles=$(mktemp "$STATE_DIR/resolved-thread-handles.$num.XXXXXX")
  still_open_thread_replies=$(mktemp "$STATE_DIR/still-open-replies.$num.XXXXXX")
  printf '%s\n' "$review_body" | review_resolved_thread_handles >"$resolved_thread_handles"
  printf '%s\n' "$review_body" | review_unresolved_thread_replies >"$still_open_thread_replies"
  auto_resolve_threads=0
  if [ "$AUTO_RESOLVE_BOT_THREADS" = "1" ]; then
    auto_resolve_threads=$(github_resolvable_review_thread_ids_for_handles "$prompt_thread_handle_map_json" "$resolved_thread_handles" "$unresolved_bot_threads_json" | awk 'END { print NR + 0 }') || auto_resolve_threads=0
  fi

  if [ -n "$DRY_RUN" ]; then
    write_dry_run_artifact "$num" "$head_sha" "$event" "$prompt_tmp" "$review" "$inline_comments_json" "$auto_resolve_threads" "$agy_err_tmp" "$review_worktree" "$ci_state" "$transcript_source"
    rm -f "$prompt_tmp" "$agy_err_tmp" "$resolved_thread_handles" "$still_open_thread_replies"
    log "Dry run: would post $event review on PR #$num@$head_sha"
    if [ "$auto_resolve_threads" -gt 0 ]; then
      log "Dry run: would auto-resolve $auto_resolve_threads explicitly selected bot review thread(s) on PR #$num@$head_sha"
    fi
    review_actions=$((review_actions + 1))
    return 0
  fi

  if post_review "$num" "$event" "$body" "$head_sha" "$inline_comments_json"; then
    review_attempts_clear review-failure "$num" "$head_sha"
    review_check_conclusion=$(review_check_run_conclusion_for_event "$event") || review_check_conclusion=neutral
    conclude_review_check_run_signal "$review_check_conclusion" "Review posted: $event" \
      "GoobReview posted a $event review on this head SHA."
    if [ "$AUTO_RESOLVE_BOT_THREADS" = "1" ]; then
      if auto_resolved_threads=$(github_resolve_review_thread_handles_json "$prompt_thread_handle_map_json" "$resolved_thread_handles" "$unresolved_bot_threads_json" "$head_sha" 2>>"$LOG_FILE"); then
        if [ "$auto_resolved_threads" -gt 0 ]; then
          log "Auto-resolved $auto_resolved_threads explicitly selected bot review thread(s) on PR #$num@$head_sha"
        fi
      else
        log "PR #$num@$head_sha: failed to auto-resolve one or more explicitly selected bot review threads"
      fi
      if still_open_replied=$(github_reply_still_open_thread_handles_json "$prompt_thread_handle_map_json" "$still_open_thread_replies" "$unresolved_bot_threads_json" 2>>"$LOG_FILE"); then
        if [ "$still_open_replied" -gt 0 ]; then
          log "Posted $still_open_replied still-open acknowledgment reply(s) on PR #$num@$head_sha"
        fi
      else
        log "PR #$num@$head_sha: failed to post one or more still-open thread replies"
      fi
    fi
    capture_research_pair "$num" "$head_sha" "$ci_state" "$review_worktree" "$pr_metadata_json" "$bot_reviews_json" "$unresolved_bot_threads_json" "$prompt_tmp" "$review" "$event" "$transcript_source" "$resolved_model_label"
    rm -f "$prompt_tmp" "$agy_err_tmp" "$resolved_thread_handles" "$still_open_thread_replies"
    log "Posted $event review on PR #$num@$head_sha"
    review_actions=$((review_actions + 1))
  else
    rm -f "$prompt_tmp" "$agy_err_tmp" "$resolved_thread_handles" "$still_open_thread_replies"
    record_review_failure_and_log "$num" "$head_sha" "Failed to post review on PR #$num@$head_sha"
  fi
}

while IFS=$'\t' read -r num author head_sha draft pr_json_b64; do
  [ -n "${num:-}" ] || continue
  review_one_pr_status=0
  review_one_pr "$num" "$author" "$head_sha" "${draft:-false}" "${pr_json_b64:-}" || review_one_pr_status=$?
  if [ "$review_one_pr_status" -eq 10 ]; then
    break
  fi
done <<< "$PRS"
