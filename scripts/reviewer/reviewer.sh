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
IGNORE_GEMINI_BACKOFF="${REVIEWER_IGNORE_GEMINI_BACKOFF:-}"
GEMINI_TIMEOUT="${REVIEWER_GEMINI_TIMEOUT:-600}"
GEMINI_MODEL="${REVIEWER_GEMINI_MODEL:-auto}"
GEMINI_QUOTA_DEFAULT_BACKOFF="${REVIEWER_GEMINI_QUOTA_DEFAULT_BACKOFF:-3600}"
GEMINI_QUOTA_BACKOFF_PADDING="${REVIEWER_GEMINI_QUOTA_BACKOFF_PADDING:-300}"
MAX_PROMPT_BYTES="${REVIEWER_MAX_PROMPT_BYTES:-240000}"
MAX_ARTIFACT_BYTES="${REVIEWER_MAX_ARTIFACT_BYTES:-1000000}"
DIFF_MAX_BYTES="${REVIEWER_DIFF_MAX_BYTES:-120000}"
DIFF_FILE_MAX_BYTES="${REVIEWER_DIFF_FILE_MAX_BYTES:-40000}"
MAX_PRS="${REVIEWER_MAX_PRS:-1}"
MAX_ATTEMPTS="${REVIEWER_MAX_ATTEMPTS:-$MAX_PRS}"
APPLY_LABELS="${REVIEWER_APPLY_LABELS:-1}"
FAILURE_MAX_ATTEMPTS="${REVIEWER_FAILURE_MAX_ATTEMPTS:-3}"
INVALID_VERDICT_MAX_ATTEMPTS="${REVIEWER_INVALID_VERDICT_MAX_ATTEMPTS:-3}"
STATE_DIR="${REVIEWER_STATE:-$HOME/.goobreview}"
RUNTIME_OWNER="${USER:-$(id -u 2>/dev/null || printf user)}"
RUNTIME_STATE_DIR="${REVIEWER_RUNTIME_STATE:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/goobreview-runtime-$RUNTIME_OWNER}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PROMPT_FILE="${REVIEWER_PROMPT:-$SCRIPT_DIR/review-prompt.md}"
REPO_DIR="${REVIEWER_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CONFIG_DIR="${REVIEWER_CONFIG_DIR:-$REPO_DIR/config}"
LOG_FILE="$STATE_DIR/log.txt"
LOCK_FILE="$STATE_DIR/lock"
GEMINI_BACKOFF_FILE="$STATE_DIR/gemini_backoff_until"

# shellcheck disable=SC1091
. "$LIB_DIR/ci.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/config.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/gemini.sh"
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
DEFAULT_PROMPT_PAYLOAD_FILE="$CONFIG_DIR/prompt-payload.json"
EXAMPLE_PROMPT_PAYLOAD_FILE="$CONFIG_DIR/prompt-payload.example.json"
ALLOW_EXAMPLE_CONFIG=0
if [ -n "$DRY_RUN" ] || [ -n "$RENDER_PROMPT_ONLY" ]; then
  ALLOW_EXAMPLE_CONFIG=1
fi
REQUIRED_CHECKS_FILE="$(resolve_reviewer_config_file "required checks" REVIEWER_REQUIRED_CHECKS_FILE "$DEFAULT_REQUIRED_CHECKS_FILE" "$EXAMPLE_REQUIRED_CHECKS_FILE" "$ALLOW_EXAMPLE_CONFIG")"
PROMPT_PAYLOAD_FILE="$(resolve_reviewer_config_file "prompt payload" REVIEWER_PROMPT_PAYLOAD_FILE "$DEFAULT_PROMPT_PAYLOAD_FILE" "$EXAMPLE_PROMPT_PAYLOAD_FILE" "$ALLOW_EXAMPLE_CONFIG")"
PERSONALITY_FILE="${REVIEWER_PERSONALITY_FILE:-}"
case "$PERSONALITY_FILE" in
  ''|/*) ;;
  *) PERSONALITY_FILE="$REPO_DIR/$PERSONALITY_FILE" ;;
esac
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
if [ -z "$DRY_RUN" ] && [ -z "$RENDER_PROMPT_ONLY" ]; then
  if [ "${REVIEWER_ALLOW_LIVE_WITHOUT_LAUNCH_CHECK:-0}" = "1" ]; then
    log "Skipping live launch validation because REVIEWER_ALLOW_LIVE_WITHOUT_LAUNCH_CHECK=1"
  elif ! bash "$REPO_DIR/scripts/launch-check.sh" >>"$LOG_FILE" 2>&1; then
    fatal "live launch validation failed. Run REVIEWER_DRY_RUN_BYPASS_CI=0 scripts/dry-run.sh, inspect the artifact, then run scripts/launch-check.sh."
  fi
fi

write_dry_run_artifact() {
  local num="$1"
  local head_sha="$2"
  local event="$3"
  local prompt_file="$4"
  local review_body="$5"
  local output_file="$DRY_RUN_OUT"
  local required_checks_sha256 prompt_payload_sha256
  local artifact_tmp artifact_bytes marker marker_bytes body_bytes

  [ -n "$output_file" ] || return 0

  mkdir -p "$(dirname "$output_file")"
  artifact_tmp=$(mktemp "$STATE_DIR/dry-artifact.XXXXXX")
  {
    printf 'GoobReview dry run\n'
    printf 'Repository: %s\n' "$REPO"
    printf 'PR: #%s\n' "$num"
    printf 'Head SHA: %s\n' "$head_sha"
    printf 'Parsed review event: %s\n' "$event"
    printf 'Generated at: %s\n' "$(date -Is)"
    printf '\n===== GEMINI PROMPT PAYLOAD START =====\n'
    append_bounded_file "$prompt_file" "$MAX_ARTIFACT_BYTES" "dry-run prompt artifact"
    printf '\n===== GEMINI PROMPT PAYLOAD END =====\n'
    printf '\n===== GEMINI RESPONSE START =====\n'
    printf '%s\n' "$review_body" | append_bounded_stdin "$MAX_ARTIFACT_BYTES" "dry-run response artifact"
    printf '===== GEMINI RESPONSE END =====\n'
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
  required_checks_sha256=$(sha256sum "$REQUIRED_CHECKS_FILE" | awk '{print $1}')
  prompt_payload_sha256=$(sha256sum "$PROMPT_PAYLOAD_FILE" | awk '{print $1}')
  jq -n \
    --arg repo "$REPO" \
    --arg pr "$num" \
    --arg head_sha "$head_sha" \
    --arg event "$event" \
    --arg generated_at "$(date -Is)" \
    --arg dry_run_out "$output_file" \
    --arg required_checks_file "$REQUIRED_CHECKS_FILE" \
    --arg required_checks_sha256 "$required_checks_sha256" \
    --arg prompt_payload_file "$PROMPT_PAYLOAD_FILE" \
    --arg prompt_payload_sha256 "$prompt_payload_sha256" \
    --arg dry_run_bypass_ci "${DRY_RUN_BYPASS_CI:-}" \
    --argjson required_checks "$EFFECTIVE_REQUIRED_CHECKS_JSON" \
    '{
      repo: $repo,
      pr: ($pr | tonumber),
      head_sha: $head_sha,
      event: $event,
      generated_at: $generated_at,
      dry_run_out: $dry_run_out,
      required_checks_file: $required_checks_file,
      required_checks_sha256: $required_checks_sha256,
      prompt_payload_file: $prompt_payload_file,
      prompt_payload_sha256: $prompt_payload_sha256,
      dry_run_bypass_ci: $dry_run_bypass_ci,
      required_checks: $required_checks
    }' >"${output_file}.launch.json.tmp"
  secure_install_file "${output_file}.launch.json.tmp" "${output_file}.launch.json" || fatal "failed to write dry-run launch metadata with mode 0600"
  rm -f "${output_file}.launch.json.tmp"
  log "Dry run artifact written to $output_file"
}

if [ -z "$RENDER_PROMPT_ONLY" ] && [ -z "$IGNORE_GEMINI_BACKOFF" ]; then
  if remaining=$(gemini_backoff_remaining); then
    log "Gemini quota backoff active for ${remaining}s"
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
  PREVIOUS_BOT_REVIEWS_JSON="$bot_reviews_json"

  if [ -z "$RENDER_PROMPT_ONLY" ] && [ -z "$DRY_RUN" ]; then
    existing=$(printf '%s\n' "$bot_reviews_json" |
      jq --arg head "$head_sha" '[.[] | select(.commit_id == $head)] | length')
    case "$existing" in
      ''|*[!0-9]*)
        log "PR #$num@$head_sha: existing review query returned unexpected count '$existing', will retry next tick"
        continue
        ;;
    esac
    if [ "$existing" -gt 0 ]; then
      log "PR #$num@$head_sha already reviewed by $BOT_LOGIN, skipping"
      continue
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
          log "PR #$num@$head_sha: CI is failing, so no Gemini prompt would be sent"
          review_actions=$((review_actions + 1))
          continue
        fi
        log "PR #$num@$head_sha: CI is failing, posting REQUEST_CHANGES without Gemini"
        ci_summary=$(github_check_runs_summary "$head_sha" 2>>"$LOG_FILE" || true)
        ci_failure_body=$(cat <<EOF
CI is failing on this commit. Fix the failing job(s) and push a new commit - I will re-review on the new head SHA.

\`\`\`
${ci_summary:-No check summary available.}
\`\`\`

---
*Auto-generated by the reviewer daemon. CI was non-green at review time, so no Gemini call was made.*
EOF
)
        if [ -n "$DRY_RUN" ]; then
          log "Dry run: would post REQUEST_CHANGES (CI failure) on PR #$num@$head_sha"
          review_actions=$((review_actions + 1))
          continue
        fi
        if post_review "$num" "REQUEST_CHANGES" "$ci_failure_body"; then
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
      log "PR #$num@$head_sha: invalid Gemini output reached REVIEWER_INVALID_VERDICT_MAX_ATTEMPTS=$INVALID_VERDICT_MAX_ATTEMPTS; skipping until the PR head changes (last artifact: ${invalid_artifact:-unavailable})"
      continue
    fi
  fi

  prompt_tmp=$(mktemp "$STATE_DIR/prompt.$num.XXXXXX")

  if ! review_worktree=$(prepare_review_worktree "$head_sha"); then
    rm -f "$prompt_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to prepare PR-head worktree"
    continue
  fi

  if ! build_review_prompt "$num" "$prompt_tmp" "$ci_state" "$head_sha" "$review_worktree" "$pr_metadata_json"; then
    rm -f "$prompt_tmp"
    record_review_failure_and_log "$num" "$head_sha" "PR #$num@$head_sha: failed to build Gemini prompt"
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

  gemini_err_tmp=$(mktemp "$STATE_DIR/gemini.$num.err.XXXXXX")
  if ! review=$(run_gemini_review "$prompt_tmp" "$gemini_err_tmp" "$review_worktree"); then
    cat "$gemini_err_tmp" >> "$LOG_FILE"
    if [ -n "$DRY_RUN" ]; then
      write_dry_run_artifact "$num" "$head_sha" "GEMINI_FAILED" "$prompt_tmp" "$(cat "$gemini_err_tmp")"
    fi
    set_gemini_quota_backoff "$gemini_err_tmp" || true
    rm -f "$prompt_tmp" "$gemini_err_tmp"
    record_review_failure_and_log "$num" "$head_sha" "gemini failed for PR #$num@$head_sha"
    continue
  fi
  cat "$gemini_err_tmp" >> "$LOG_FILE"

  if [ -z "${review// }" ]; then
    invalid_artifact=$(write_invalid_verdict_artifact "$num" "$head_sha" "EMPTY_RESPONSE" "$review")
    write_dry_run_artifact "$num" "$head_sha" "EMPTY_RESPONSE" "$prompt_tmp" "$review"
    rm -f "$prompt_tmp" "$gemini_err_tmp"
    if [ -z "$DRY_RUN" ]; then
      invalid_attempts=$(record_invalid_verdict_attempt "$num" "$head_sha")
      if [ "$INVALID_VERDICT_MAX_ATTEMPTS" -eq 0 ]; then
        log "gemini returned empty for PR #$num@$head_sha; wrote $invalid_artifact; will retry next tick (invalid-output cap disabled)"
      elif [ "$invalid_attempts" -ge "$INVALID_VERDICT_MAX_ATTEMPTS" ]; then
        log "gemini returned empty for PR #$num@$head_sha; wrote $invalid_artifact; reached invalid-output cap ($invalid_attempts/$INVALID_VERDICT_MAX_ATTEMPTS)"
      else
        log "gemini returned empty for PR #$num@$head_sha; wrote $invalid_artifact; will retry next tick ($invalid_attempts/$INVALID_VERDICT_MAX_ATTEMPTS)"
      fi
    else
      log "gemini returned empty for PR #$num@$head_sha; wrote $invalid_artifact; will retry next tick"
    fi
    continue
  fi

  if ! event=$(printf '%s' "$review" | review_verdict_event); then
    invalid_artifact=$(write_invalid_verdict_artifact "$num" "$head_sha" "INVALID_VERDICT" "$review")
    write_dry_run_artifact "$num" "$head_sha" "INVALID" "$prompt_tmp" "$review"
    rm -f "$prompt_tmp" "$gemini_err_tmp"
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
        log "PR #$num@$head_sha: gemini did not emit a valid final GitHub review event (got: $verdict_line); wrote $invalid_artifact; will retry next tick (invalid-output cap disabled)"
      elif [ "$invalid_attempts" -ge "$INVALID_VERDICT_MAX_ATTEMPTS" ]; then
        log "PR #$num@$head_sha: gemini did not emit a valid final GitHub review event (got: $verdict_line); wrote $invalid_artifact; reached invalid-output cap ($invalid_attempts/$INVALID_VERDICT_MAX_ATTEMPTS)"
      else
        log "PR #$num@$head_sha: gemini did not emit a valid final GitHub review event (got: $verdict_line); wrote $invalid_artifact; will retry next tick ($invalid_attempts/$INVALID_VERDICT_MAX_ATTEMPTS)"
      fi
    else
      log "PR #$num@$head_sha: gemini did not emit a valid final GitHub review event (got: $verdict_line); wrote $invalid_artifact; will retry next tick"
    fi
    continue
  fi
  if [ -z "$DRY_RUN" ]; then
    clear_invalid_verdict_attempts "$num" "$head_sha"
  fi

  review_body=$(printf '%s' "$review" | review_body_before_verdict)
  body=$(cat <<EOF
$review_body

---
*Drafted by \`gemini\` running on $REVIEWER_RUNNER_NAME, posted by @$BOT_LOGIN. Verdict and findings are gemini's; no human read this diff before posting.*
EOF
)

  if [ -n "$DRY_RUN" ]; then
    write_dry_run_artifact "$num" "$head_sha" "$event" "$prompt_tmp" "$review"
    rm -f "$prompt_tmp" "$gemini_err_tmp"
    log "Dry run: would post $event review on PR #$num@$head_sha"
    review_actions=$((review_actions + 1))
    continue
  fi

  rm -f "$prompt_tmp" "$gemini_err_tmp"

  if post_review "$num" "$event" "$body"; then
    clear_review_failure_attempts "$num" "$head_sha"
    apply_review_labels "$num" "$event" || log "PR #$num: failed to apply review labels"
    log "Posted $event review on PR #$num@$head_sha"
    review_actions=$((review_actions + 1))
  else
    record_review_failure_and_log "$num" "$head_sha" "Failed to post review on PR #$num@$head_sha"
  fi
done <<< "$PRS"
