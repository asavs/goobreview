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
MAX_PRS="${REVIEWER_MAX_PRS:-1}"
APPLY_LABELS="${REVIEWER_APPLY_LABELS:-1}"
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

mkdir -p "$STATE_DIR"
mkdir -p "$RUNTIME_STATE_DIR"
chmod 700 "$RUNTIME_STATE_DIR" 2>/dev/null || true
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

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

validate_reviewer_config
load_effective_required_checks_json >/dev/null

write_dry_run_artifact() {
  local num="$1"
  local head_sha="$2"
  local event="$3"
  local prompt_file="$4"
  local review_body="$5"
  local output_file="$DRY_RUN_OUT"

  [ -n "$output_file" ] || return 0

  mkdir -p "$(dirname "$output_file")"
  {
    printf 'GoobReview dry run\n'
    printf 'Repository: %s\n' "$REPO"
    printf 'PR: #%s\n' "$num"
    printf 'Head SHA: %s\n' "$head_sha"
    printf 'Parsed review event: %s\n' "$event"
    printf 'Generated at: %s\n' "$(date -Is)"
    printf '\n===== GEMINI PROMPT PAYLOAD START =====\n'
    cat "$prompt_file"
    printf '\n===== GEMINI PROMPT PAYLOAD END =====\n'
    printf '\n===== GEMINI RESPONSE START =====\n'
    printf '%s\n' "$review_body"
    printf '===== GEMINI RESPONSE END =====\n'
  } >"$output_file"
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

while IFS=$'\t' read -r num author head_sha draft; do
  [ -n "${num:-}" ] || continue
  if skip_reason=$(reviewer_pr_skip_reason "$num" "$author" "$head_sha" "${draft:-false}" "$BOT_LOGIN" "$EXTRA_SKIP_USER" "$ONLY_PR" "$BOT_AUTHOR"); then
    log "$skip_reason"
    continue
  fi

  if [ "$review_actions" -ge "$MAX_PRS" ]; then
    log "Reached REVIEWER_MAX_PRS=$MAX_PRS, stopping this tick"
    break
  fi

  if [ -z "$RENDER_PROMPT_ONLY" ] && [ -z "$DRY_RUN" ]; then
    if ! existing=$(github_api_paginate_array "repos/$REPO/pulls/$num/reviews" 2>>"$LOG_FILE" |
      jq -s --arg bot "$BOT_LOGIN" --arg bot_author "$BOT_AUTHOR" --arg head "$head_sha" \
        '[.[] | select((.user.login == $bot or .user.login == $bot_author) and .commit_id == $head)] | length'); then
      log "PR #$num@$head_sha: failed to read existing reviews, will retry next tick"
      continue
    fi
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

  if ! ci_state=$(REQUIRED_CHECKS_JSON="$EFFECTIVE_REQUIRED_CHECKS_JSON" bash "$SCRIPT_DIR/check-ci.sh" "$REPO" "$head_sha" "$REQUIRED_CHECKS_FILE" 2>>"$LOG_FILE"); then
    log "PR #$num@$head_sha: failed to read CI check-runs, will retry next tick"
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
        log "PR #$num@$head_sha: CI not yet terminal (state=$ci_state), will retry next tick"
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
          log "Posted REQUEST_CHANGES (CI failure) on PR #$num@$head_sha"
          review_actions=$((review_actions + 1))
        else
          log "Failed to post REQUEST_CHANGES (CI failure) on PR #$num@$head_sha, will retry next tick"
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
    log "PR #$num@$head_sha: failed to prepare PR-head worktree, will retry next tick"
    continue
  fi

  if ! build_review_prompt "$num" "$prompt_tmp" "$ci_state" "$head_sha" "$review_worktree"; then
    rm -f "$prompt_tmp"
    log "PR #$num@$head_sha: failed to build Gemini prompt, will retry next tick"
    continue
  fi

  if [ -n "$RENDER_PROMPT_ONLY" ]; then
    if [ -n "$PROMPT_OUT" ] && [ "$PROMPT_OUT" != "-" ]; then
      mkdir -p "$(dirname "$PROMPT_OUT")"
      cp "$prompt_tmp" "$PROMPT_OUT"
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
    log "gemini failed for PR #$num, will retry next tick"
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
    verdict_line=$(printf '%s' "$review" | sed -n '1p')
    if [ -z "$DRY_RUN" ]; then
      invalid_attempts=$(record_invalid_verdict_attempt "$num" "$head_sha")
      if [ "$INVALID_VERDICT_MAX_ATTEMPTS" -eq 0 ]; then
        log "PR #$num@$head_sha: gemini did not emit a valid first-line GitHub review event (got: $verdict_line); wrote $invalid_artifact; will retry next tick (invalid-output cap disabled)"
      elif [ "$invalid_attempts" -ge "$INVALID_VERDICT_MAX_ATTEMPTS" ]; then
        log "PR #$num@$head_sha: gemini did not emit a valid first-line GitHub review event (got: $verdict_line); wrote $invalid_artifact; reached invalid-output cap ($invalid_attempts/$INVALID_VERDICT_MAX_ATTEMPTS)"
      else
        log "PR #$num@$head_sha: gemini did not emit a valid first-line GitHub review event (got: $verdict_line); wrote $invalid_artifact; will retry next tick ($invalid_attempts/$INVALID_VERDICT_MAX_ATTEMPTS)"
      fi
    else
      log "PR #$num@$head_sha: gemini did not emit a valid first-line GitHub review event (got: $verdict_line); wrote $invalid_artifact; will retry next tick"
    fi
    continue
  fi
  if [ -z "$DRY_RUN" ]; then
    clear_invalid_verdict_attempts "$num" "$head_sha"
  fi

  review_body=$(printf '%s' "$review" | review_body_after_verdict)
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
    apply_review_labels "$num" "$event" || log "PR #$num: failed to apply review labels"
    log "Posted $event review on PR #$num@$head_sha"
    review_actions=$((review_actions + 1))
  else
    log "Failed to post review on PR #$num@$head_sha, will retry next tick"
  fi
done <<< "$PRS"
