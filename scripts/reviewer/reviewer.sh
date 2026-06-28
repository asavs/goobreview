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
REFUSE_ON_HOME_CONTEXT="${REVIEWER_REFUSE_ON_HOME_CONTEXT:-0}"
MAX_PRS="${REVIEWER_MAX_PRS:-1}"
MAX_ATTEMPTS="${REVIEWER_MAX_ATTEMPTS:-$MAX_PRS}"
AUTO_RESOLVE_BOT_THREADS="${REVIEWER_AUTO_RESOLVE_BOT_THREADS:-0}"
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
REVIEWER_RUNNER_NAME="${REVIEWER_RUNNER_NAME:-reviewer daemon}"

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
  local output_file="$DRY_RUN_OUT"
  local required_checks_sha256 inline_comment_count
  local artifact_tmp artifact_bytes marker marker_bytes body_bytes
  local runtime_dir agy_path agy_version prompt_bytes prompt_sha response_bytes response_sha stderr_bytes stderr_sha snapshot_files snapshot_symlinks agents_md_tmp agents_md_bytes agents_md_sha home_agy_context

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
    printf 'Generated at: %s\n' "$(date -Is)"
    printf '\n===== AGY EXECUTION CONTEXT START =====\n'
    printf 'Observable from GoobReview: prompt payload, agy stdout/stderr, process envelope, runtime cwd, and PR-head snapshot path/counts.\n'
    printf 'Hidden Antigravity CLI system prompt/tool definitions: not observable by GoobReview; injected by agy outside this artifact.\n'
    printf 'Command template: timeout %s agy --sandbox --dangerously-skip-permissions --print-timeout %ss --model %s --print <prompt-by-value>\n' "$AGY_TIMEOUT" "$AGY_TIMEOUT" "$AGY_MODEL"
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
  artifact_bytes=$(wc -c <"$artifact_tmp" | tr -d ' ')
  if [ "$artifact_bytes" -gt "$MAX_ARTIFACT_BYTES" ]; then
    marker=$(printf '\n\n[goobreview: dry-run artifact truncated after %s bytes]\n' "$MAX_ARTIFACT_BYTES")
    marker_bytes=$(printf '%s' "$marker" | wc -c | tr -d ' ')
    if [ "$marker_bytes" -gt "$MAX_ARTIFACT_BYTES" ]; then
      printf '%s' "$marker" | head -c "$MAX_ARTIFACT_BYTES" >"$artifact_tmp.truncated"
      install_secret_scanned_artifact "$artifact_tmp.truncated" "$output_file" || fatal "dry-run artifact failed secret-safety scan"
      rm -f "$artifact_tmp.truncated"
      rm -f "$artifact_tmp"
      artifact_tmp=""
    else
      body_bytes=$((MAX_ARTIFACT_BYTES - marker_bytes))
      head -c "$body_bytes" "$artifact_tmp" >"$artifact_tmp.truncated"
      printf '%s' "$marker" >>"$artifact_tmp.truncated"
      install_secret_scanned_artifact "$artifact_tmp.truncated" "$output_file" || fatal "dry-run artifact failed secret-safety scan"
      rm -f "$artifact_tmp.truncated"
    fi
  else
    install_secret_scanned_artifact "$artifact_tmp" "$output_file" || fatal "dry-run artifact failed secret-safety scan"
    rm -f "$artifact_tmp"
    artifact_tmp=""
  fi
  [ -z "$artifact_tmp" ] || rm -f "$artifact_tmp"
  rm -f "$agents_md_tmp"
  required_checks_sha256=$(sha256sum "$REQUIRED_CHECKS_FILE" | awk '{print $1}')
  jq -n \
    --arg repo "$REPO" \
    --arg pr "$num" \
    --arg head_sha "$head_sha" \
    --arg event "$event" \
    --arg generated_at "$(date -Is)" \
    --arg dry_run_out "$output_file" \
    --arg posted_personality "$POSTED_PERSONALITY" \
    --arg personality_file "$PERSONALITY_FILE" \
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
  local artifact_tmp artifact_bytes marker marker_bytes body_bytes agents_md_tmp agents_md_bytes agents_md_sha

  mkdir -p "$(dirname "$output_file")"
  chmod 700 "$(dirname "$output_file")" 2>/dev/null || true
  artifact_tmp=$(mktemp "$STATE_DIR/research-artifact.XXXXXX")
  agents_md_tmp=$(mktemp "$STATE_DIR/research-agents-md.XXXXXX")
  write_agents_md "$personality_file" "$agents_md_tmp" "$ci_state" "$head_sha" || {
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

  artifact_bytes=$(wc -c <"$artifact_tmp" | tr -d ' ')
  if [ "$artifact_bytes" -gt "$MAX_ARTIFACT_BYTES" ]; then
    marker=$(printf '\n\n[goobreview: research artifact truncated after %s bytes]\n' "$MAX_ARTIFACT_BYTES")
    marker_bytes=$(printf '%s' "$marker" | wc -c | tr -d ' ')
    if [ "$marker_bytes" -gt "$MAX_ARTIFACT_BYTES" ]; then
      printf '%s' "$marker" | head -c "$MAX_ARTIFACT_BYTES" >"$artifact_tmp.truncated"
    else
      body_bytes=$((MAX_ARTIFACT_BYTES - marker_bytes))
      head -c "$body_bytes" "$artifact_tmp" >"$artifact_tmp.truncated"
      printf '%s' "$marker" >>"$artifact_tmp.truncated"
    fi
    install_secret_scanned_artifact "$artifact_tmp.truncated" "$output_file" || {
      rm -f "$artifact_tmp" "$artifact_tmp.truncated" "$agents_md_tmp"
      return 1
    }
    rm -f "$artifact_tmp.truncated"
  else
    install_secret_scanned_artifact "$artifact_tmp" "$output_file" || {
      rm -f "$artifact_tmp" "$agents_md_tmp"
      return 1
    }
  fi
  rm -f "$artifact_tmp" "$agents_md_tmp"
}

research_personality_file_for_arm() {
  case "$1" in
    none) printf '%s\n' "$CONFIG_DIR/personalities/control.md" ;;
    linus) printf '%s\n' "$CONFIG_DIR/personalities/linus.md" ;;
    angry) printf '%s\n' "$CONFIG_DIR/personalities/angry.md" ;;
    *) return 1 ;;
  esac
}

write_research_review_artifact_for_arm() {
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
  local old_prompt_personality prompt_personality_was_set=0 status

  if [ "${PROMPT_PERSONALITY+x}" = "x" ]; then
    prompt_personality_was_set=1
    old_prompt_personality="$PROMPT_PERSONALITY"
  else
    old_prompt_personality=""
  fi
  PROMPT_PERSONALITY="$arm"
  status=0
  write_research_review_artifact "$output_file" "$num" "$head_sha" "$arm" "$personality_file" "$role" "$event" "$prompt_file" "$review_body" "$ci_state" || status=$?
  if [ "$prompt_personality_was_set" -eq 1 ]; then
    PROMPT_PERSONALITY="$old_prompt_personality"
  else
    unset PROMPT_PERSONALITY
  fi
  return "$status"
}

build_research_prompt_for_arm() {
  local arm="$1"
  local num="$2"
  local output_prompt_file="$3"
  local ci_state="$4"
  local head_sha="$5"
  local worktree_dir="$6"
  local pr_metadata_json="$7"
  local previous_bot_reviews_json="$8"
  local prior_bot_threads_json="$9"
  local old_prompt_personality prompt_personality_was_set=0 status

  if [ "${PROMPT_PERSONALITY+x}" = "x" ]; then
    prompt_personality_was_set=1
    old_prompt_personality="$PROMPT_PERSONALITY"
  else
    old_prompt_personality=""
  fi
  PROMPT_PERSONALITY="$arm"
  status=0
  build_review_prompt "$num" "$output_prompt_file" "$ci_state" "$head_sha" "$worktree_dir" "$pr_metadata_json" "$previous_bot_reviews_json" "$prior_bot_threads_json" || status=$?
  if [ "$prompt_personality_was_set" -eq 1 ]; then
    PROMPT_PERSONALITY="$old_prompt_personality"
  else
    unset PROMPT_PERSONALITY
  fi
  return "$status"
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
      log "Research consent is enabled, but paired research capture is disabled for private repositories in v1"
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
  local run_id run_dir posted_arm counterfactual_arm posted_dir counterfactual_dir
  local posted_file counterfactual_file manifest_tmp counterfactual_err counterfactual_prompt_file
  local counterfactual_personality_file counterfactual_review counterfactual_event
  local generated_at required_checks_sha256 posted_personality_file

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
  required_checks_sha256=$(sha256sum "$REQUIRED_CHECKS_FILE" | awk '{print $1}')
  posted_personality_file="$PERSONALITY_FILE"
  counterfactual_personality_file="$(research_personality_file_for_arm "$counterfactual_arm")" || return 0

  if ! write_research_review_artifact_for_arm "$posted_file" "$num" "$head_sha" "$posted_arm" "$posted_personality_file" "posted" "$posted_event" "$posted_prompt_file" "$posted_review" "$ci_state"; then
    log "PR #$num@$head_sha: failed to write posted research artifact"
    return 0
  fi

  counterfactual_err=$(mktemp "$STATE_DIR/research-agy.$num.err.XXXXXX")
  counterfactual_prompt_file=$(mktemp "$STATE_DIR/research-prompt.$num.XXXXXX")
  if ! build_research_prompt_for_arm "$counterfactual_arm" "$num" "$counterfactual_prompt_file" "$ci_state" "$head_sha" "$review_worktree" "$pr_metadata_json" "$bot_reviews_json" "$prior_bot_threads_json"; then
    log "PR #$num@$head_sha: failed to build counterfactual research prompt for $counterfactual_arm"
    rm -f "$counterfactual_err" "$counterfactual_prompt_file"
    return 0
  fi
  if counterfactual_review=$(run_agy_review "$counterfactual_prompt_file" "$counterfactual_err" "$review_worktree" "$counterfactual_personality_file" "$ci_state" "$head_sha" "$counterfactual_arm"); then
    cat "$counterfactual_err" >>"$LOG_FILE"
    if [ -z "${counterfactual_review// }" ]; then
      counterfactual_event="EMPTY_RESPONSE"
    elif ! counterfactual_event=$(printf '%s' "$counterfactual_review" | review_verdict_event); then
      counterfactual_event="INVALID"
    fi
  else
    cat "$counterfactual_err" >>"$LOG_FILE"
    counterfactual_event="AGY_FAILED"
    counterfactual_review=$(cat "$counterfactual_err")
  fi

  if ! write_research_review_artifact_for_arm "$counterfactual_file" "$num" "$head_sha" "$counterfactual_arm" "$counterfactual_personality_file" "counterfactual" "$counterfactual_event" "$counterfactual_prompt_file" "$counterfactual_review" "$ci_state"; then
    log "PR #$num@$head_sha: failed to write counterfactual research artifact"
    rm -f "$counterfactual_err" "$counterfactual_prompt_file"
    return 0
  fi
  rm -f "$counterfactual_err" "$counterfactual_prompt_file"

  manifest_tmp=$(mktemp "$STATE_DIR/research-manifest.XXXXXX")
  jq -n \
    --arg repo "$REPO" \
    --arg pr "$num" \
    --arg head_sha "$head_sha" \
    --arg generated_at "$generated_at" \
    --arg posted_personality "$POSTED_PERSONALITY" \
    --arg posted_arm "$posted_arm" \
    --arg counterfactual_arm "$counterfactual_arm" \
    --arg posted_event "$posted_event" \
    --arg counterfactual_event "$counterfactual_event" \
    --arg posted_artifact "$posted_file" \
    --arg counterfactual_artifact "$counterfactual_file" \
    --arg posted_personality_file "$posted_personality_file" \
    --arg counterfactual_personality_file "$counterfactual_personality_file" \
    --arg model "$AGY_MODEL" \
    --arg ci_state "$ci_state" \
    --arg required_checks_file "$REQUIRED_CHECKS_FILE" \
    --arg required_checks_sha256 "$required_checks_sha256" \
    --arg repo_visibility "$RESEARCH_REPO_VISIBILITY" \
    --arg research_eligible "public-consented" \
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
      model: $model,
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

  if [ -z "$DRY_RUN" ] && [ -z "$RENDER_PROMPT_ONLY" ]; then
    attempts=$(record_review_failure_attempt "$num" "$head_sha")
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

while IFS=$'\t' read -r num author head_sha draft pr_json_b64; do
  [ -n "${num:-}" ] || continue
  pr_metadata_json=""
  if [ -n "${pr_json_b64:-}" ]; then
    pr_metadata_json=$(printf '%s' "$pr_json_b64" | base64 -d) || pr_metadata_json=""
  fi
  if skip_reason=$(reviewer_pr_skip_reason "$num" "$author" "$head_sha" "${draft:-false}" "$BOT_LOGIN" "$EXTRA_SKIP_USER" "$ONLY_PR" "$BOT_AUTHOR"); then
    log "$skip_reason"
    continue
  fi

  if [ "$review_actions" -ge "$MAX_PRS" ]; then
    log "Reached REVIEWER_MAX_PRS=$MAX_PRS, stopping this tick"
    break
  fi

  if ! bot_reviews_json=$(github_api_paginate_array "repos/$REPO/pulls/$num/reviews" 2>>"$LOG_FILE" |
    jq -s --arg bot "$BOT_LOGIN" --arg bot_author "$BOT_AUTHOR" \
      '[.[] | select(.user.login == $bot or .user.login == $bot_author)]'); then
    log "PR #$num@$head_sha: failed to read existing reviews, will retry next tick"
    continue
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
        continue
        ;;
    esac
    if [ "$existing" -gt 0 ]; then
      if [ "$requested_review" -eq 1 ]; then
        log "PR #$num@$head_sha already reviewed by $BOT_LOGIN, but review was re-requested; reviewing again"
      else
        log "PR #$num@$head_sha already reviewed by $BOT_LOGIN, skipping"
        continue
      fi
    fi
  fi

  if [ "$review_attempts" -ge "$MAX_ATTEMPTS" ]; then
    log "Reached REVIEWER_MAX_ATTEMPTS=$MAX_ATTEMPTS after $review_attempts attempted review(s), stopping this tick"
    break
  fi

  if [ -z "$RENDER_PROMPT_ONLY" ] && [ -z "$DRY_RUN" ] && [ "$FAILURE_MAX_ATTEMPTS" -gt 0 ]; then
    failure_attempts=$(review_failure_attempt_count "$num" "$head_sha")
    if [ "$failure_attempts" -ge "$FAILURE_MAX_ATTEMPTS" ]; then
      log "PR #$num@$head_sha: review failures reached REVIEWER_FAILURE_MAX_ATTEMPTS=$FAILURE_MAX_ATTEMPTS; skipping until the PR head changes"
      continue
    fi
  fi
  review_attempts=$((review_attempts + 1))

  if ! ci_state=$(REQUIRED_CHECKS_JSON="$EFFECTIVE_REQUIRED_CHECKS_JSON" bash "$SCRIPT_DIR/check-ci.sh" "$REPO" "$head_sha" "$REQUIRED_CHECKS_FILE" 2>>"$LOG_FILE"); then
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to read CI check-runs"
    continue
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
        continue
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
          continue
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
          continue
        fi
        if post_review "$num" "REQUEST_CHANGES" "$ci_failure_body" "$head_sha" '[]'; then
          clear_review_failure_attempts "$num" "$head_sha"
          log "Posted REQUEST_CHANGES (CI failure) on PR #$num@$head_sha"
          review_actions=$((review_actions + 1))
        else
          record_review_failure_and_log "$num" "$head_sha" "Failed to post REQUEST_CHANGES (CI failure) on PR #$num@$head_sha"
        fi
        continue
      fi
      ;;
    *)
      log "PR #$num@$head_sha: unexpected CI state '$ci_state', will retry next tick"
      continue
      ;;
  esac

  log "Reviewing PR #$num@$head_sha"

  if [ -z "$RENDER_PROMPT_ONLY" ] && [ -z "$DRY_RUN" ] && [ "$INVALID_VERDICT_MAX_ATTEMPTS" -gt 0 ]; then
    invalid_attempts=$(invalid_verdict_attempt_count "$num" "$head_sha")
    if [ "$invalid_attempts" -ge "$INVALID_VERDICT_MAX_ATTEMPTS" ]; then
      invalid_artifact=$(invalid_verdict_artifact_path "$num" || true)
      log "PR #$num@$head_sha: invalid agy output reached REVIEWER_INVALID_VERDICT_MAX_ATTEMPTS=$INVALID_VERDICT_MAX_ATTEMPTS; skipping until the PR head changes (last artifact: ${invalid_artifact:-unavailable})"
      continue
    fi
  fi

  prompt_tmp=$(mktemp "$STATE_DIR/prompt.$num.XXXXXX")

  if ! review_worktree=$(prepare_review_worktree "$head_sha"); then
    rm -f "$prompt_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to prepare PR-head worktree"
    continue
  fi

  if ! review_threads_json=$(github_pr_review_threads_json "$num" 2>>"$LOG_FILE"); then
    rm -f "$prompt_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to read existing review threads"
    continue
  fi
  if ! unresolved_bot_threads_json=$(github_unresolved_bot_review_threads_json "$review_threads_json" "$BOT_LOGIN" "$BOT_AUTHOR"); then
    rm -f "$prompt_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to filter existing bot review threads"
    continue
  fi
  if ! prompt_thread_handle_map_json=$(printf '%s\n' "$unresolved_bot_threads_json" | github_review_thread_handle_map_json); then
    rm -f "$prompt_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to map bot review thread handles"
    continue
  fi

  if ! build_review_prompt "$num" "$prompt_tmp" "$ci_state" "$head_sha" "$review_worktree" "$pr_metadata_json" "$bot_reviews_json" "$unresolved_bot_threads_json"; then
    rm -f "$prompt_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to build agy prompt"
    continue
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
    continue
  fi

  agy_err_tmp=$(mktemp "$STATE_DIR/agy.$num.err.XXXXXX")
  if ! review=$(run_agy_review "$prompt_tmp" "$agy_err_tmp" "$review_worktree" "$PERSONALITY_FILE" "$ci_state" "$head_sha"); then
    cat "$agy_err_tmp" >> "$LOG_FILE"
    if [ -n "$DRY_RUN" ]; then
      write_dry_run_artifact "$num" "$head_sha" "AGY_FAILED" "$prompt_tmp" "$(cat "$agy_err_tmp")" '[]' 0 "$agy_err_tmp" "$review_worktree" "$ci_state"
    fi
    set_agy_quota_backoff "$agy_err_tmp" || true
    rm -f "$prompt_tmp" "$agy_err_tmp"
    record_review_failure_and_log "$num" "$head_sha" "agy failed for PR #$num@$head_sha"
    continue
  fi
  cat "$agy_err_tmp" >> "$LOG_FILE"

  if [ -z "${review// }" ]; then
    invalid_artifact=$(write_invalid_verdict_artifact "$num" "$head_sha" "EMPTY_RESPONSE" "$review")
    write_dry_run_artifact "$num" "$head_sha" "EMPTY_RESPONSE" "$prompt_tmp" "$review" '[]' 0 "$agy_err_tmp" "$review_worktree" "$ci_state"
    rm -f "$prompt_tmp" "$agy_err_tmp"
    if [ -z "$DRY_RUN" ]; then
      invalid_attempts=$(record_invalid_verdict_attempt "$num" "$head_sha")
      if [ "$INVALID_VERDICT_MAX_ATTEMPTS" -eq 0 ]; then
        log "agy returned empty for PR #$num@$head_sha; wrote $invalid_artifact; will retry next tick (invalid-output cap disabled)"
      elif [ "$invalid_attempts" -ge "$INVALID_VERDICT_MAX_ATTEMPTS" ]; then
        log "agy returned empty for PR #$num@$head_sha; wrote $invalid_artifact; reached invalid-output cap ($invalid_attempts/$INVALID_VERDICT_MAX_ATTEMPTS)"
      else
        log "agy returned empty for PR #$num@$head_sha; wrote $invalid_artifact; will retry next tick ($invalid_attempts/$INVALID_VERDICT_MAX_ATTEMPTS)"
      fi
    else
      log "agy returned empty for PR #$num@$head_sha; wrote $invalid_artifact; will retry next tick"
    fi
    continue
  fi

  if ! event=$(printf '%s' "$review" | review_verdict_event); then
    invalid_artifact=$(write_invalid_verdict_artifact "$num" "$head_sha" "INVALID_VERDICT" "$review")
    write_dry_run_artifact "$num" "$head_sha" "INVALID" "$prompt_tmp" "$review" '[]' 0 "$agy_err_tmp" "$review_worktree" "$ci_state"
    rm -f "$prompt_tmp" "$agy_err_tmp"
    verdict_line=$(printf '%s' "$review" | awk '
      {
        line = $0
        sub(/\r$/, "", line)
        trimmed = line
        sub(/^[[:space:]]+/, "", trimmed)
        sub(/[[:space:]]+$/, "", trimmed)
        if (trimmed != "") last = trimmed
      }
      END { print last }
    ')
    if [ -z "$DRY_RUN" ]; then
      invalid_attempts=$(record_invalid_verdict_attempt "$num" "$head_sha")
      if [ "$INVALID_VERDICT_MAX_ATTEMPTS" -eq 0 ]; then
        log "PR #$num@$head_sha: agy did not emit a valid final GitHub review event (got: $verdict_line); wrote $invalid_artifact; will retry next tick (invalid-output cap disabled)"
      elif [ "$invalid_attempts" -ge "$INVALID_VERDICT_MAX_ATTEMPTS" ]; then
        log "PR #$num@$head_sha: agy did not emit a valid final GitHub review event (got: $verdict_line); wrote $invalid_artifact; reached invalid-output cap ($invalid_attempts/$INVALID_VERDICT_MAX_ATTEMPTS)"
      else
        log "PR #$num@$head_sha: agy did not emit a valid final GitHub review event (got: $verdict_line); wrote $invalid_artifact; will retry next tick ($invalid_attempts/$INVALID_VERDICT_MAX_ATTEMPTS)"
      fi
    else
      log "PR #$num@$head_sha: agy did not emit a valid final GitHub review event (got: $verdict_line); wrote $invalid_artifact; will retry next tick"
    fi
    continue
  fi
  if [ -z "$DRY_RUN" ]; then
    clear_invalid_verdict_attempts "$num" "$head_sha"
  fi

  review_body=$(printf '%s' "$review" | review_body_before_verdict)

  if [ -z "$DRY_RUN" ]; then
    if ! current_pr_json=$(github_api_get "repos/$REPO/pulls/$num" 2>>"$LOG_FILE"); then
      rm -f "$prompt_tmp" "$agy_err_tmp"
      record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to re-read PR head before posting review"
      continue
    fi
    current_head_sha=$(printf '%s\n' "$current_pr_json" | jq -r '.head.sha // empty')
    if [ "$current_head_sha" != "$head_sha" ]; then
      rm -f "$prompt_tmp" "$agy_err_tmp"
      log "PR #$num@$head_sha: head advanced to $current_head_sha before posting; discarding reviewed result"
      continue
    fi
    if ! review_threads_json=$(github_pr_review_threads_json "$num" 2>>"$LOG_FILE"); then
      rm -f "$prompt_tmp" "$agy_err_tmp"
      record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to re-read review threads before posting review"
      continue
    fi
    if ! unresolved_bot_threads_json=$(github_unresolved_bot_review_threads_json "$review_threads_json" "$BOT_LOGIN" "$BOT_AUTHOR"); then
      rm -f "$prompt_tmp" "$agy_err_tmp"
      record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to filter latest bot review threads before posting review"
      continue
    fi
  fi

  if ! inline_comments_json=$(review_inline_comments_json "$num" "$review_body" "$review_worktree"); then
    rm -f "$prompt_tmp" "$agy_err_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to resolve inline review anchors"
    continue
  fi
  scope_downgraded=0
  scoped_event=$(review_event_after_scope_guard "$event" "$inline_comments_json") || {
    rm -f "$prompt_tmp" "$agy_err_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to evaluate inline review scope"
    continue
  }
  if [ "$event" = "REQUEST_CHANGES" ] && [ "$scoped_event" = "COMMENT" ]; then
    log "PR #$num@$head_sha: downgraded REQUEST_CHANGES to COMMENT because all anchored findings target pre-existing or context lines"
    scope_downgraded=1
  fi
  event="$scoped_event"

  filtered_body=$(printf '%s\n' "$review_body" | review_body_without_promoted_sections "$inline_comments_json")
  if [ "$scope_downgraded" -eq 1 ]; then
    filtered_body=$(cat <<EOF
$filtered_body

[goobreview: posted as COMMENT because all anchored findings resolved to pre-existing or context lines, so they were not treated as blocking for this PR.]
EOF
)
  fi
  body=$(cat <<EOF
$filtered_body

---
*Drafted by \`agy\` running on $REVIEWER_RUNNER_NAME, posted by @$BOT_LOGIN. Verdict and findings are agy's; no human read this diff before posting.*
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
    write_dry_run_artifact "$num" "$head_sha" "$event" "$prompt_tmp" "$review" "$inline_comments_json" "$auto_resolve_threads" "$agy_err_tmp" "$review_worktree" "$ci_state"
    rm -f "$prompt_tmp" "$agy_err_tmp" "$resolved_thread_handles" "$still_open_thread_replies"
    log "Dry run: would post $event review on PR #$num@$head_sha"
    if [ "$auto_resolve_threads" -gt 0 ]; then
      log "Dry run: would auto-resolve $auto_resolve_threads explicitly selected bot review thread(s) on PR #$num@$head_sha"
    fi
    review_actions=$((review_actions + 1))
    continue
  fi

  if post_review "$num" "$event" "$body" "$head_sha" "$inline_comments_json"; then
    clear_review_failure_attempts "$num" "$head_sha"
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
    capture_research_pair "$num" "$head_sha" "$ci_state" "$review_worktree" "$pr_metadata_json" "$bot_reviews_json" "$unresolved_bot_threads_json" "$prompt_tmp" "$review" "$event"
    rm -f "$prompt_tmp" "$agy_err_tmp" "$resolved_thread_handles" "$still_open_thread_replies"
    log "Posted $event review on PR #$num@$head_sha"
    review_actions=$((review_actions + 1))
  else
    rm -f "$prompt_tmp" "$agy_err_tmp" "$resolved_thread_handles" "$still_open_thread_replies"
    record_review_failure_and_log "$num" "$head_sha" "Failed to post review on PR #$num@$head_sha"
  fi
done <<< "$PRS"
