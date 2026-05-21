#!/usr/bin/env bash
set -euo pipefail

REPO="${REVIEWER_REPO:-}"
SKIP_USER="${REVIEWER_USER:-}"
ONLY_PR="${REVIEWER_ONLY_PR:-}"
DRY_RUN="${REVIEWER_DRY_RUN:-}"
GEMINI_TIMEOUT="${REVIEWER_GEMINI_TIMEOUT:-600}"
GEMINI_MODEL="${REVIEWER_GEMINI_MODEL:-auto}"
GEMINI_QUOTA_DEFAULT_BACKOFF="${REVIEWER_GEMINI_QUOTA_DEFAULT_BACKOFF:-3600}"
GEMINI_QUOTA_BACKOFF_PADDING="${REVIEWER_GEMINI_QUOTA_BACKOFF_PADDING:-300}"
MAX_PRS="${REVIEWER_MAX_PRS:-1}"
APPLY_LABELS="${REVIEWER_APPLY_LABELS:-1}"
UPDATE_CHECKLIST="${REVIEWER_UPDATE_CHECKLIST:-1}"
STATE_DIR="${REVIEWER_STATE:-$HOME/.goobreview}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PROMPT_FILE="${REVIEWER_PROMPT:-$SCRIPT_DIR/review-prompt.md}"
REPO_DIR="${REVIEWER_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CONFIG_DIR="${REVIEWER_CONFIG_DIR:-$REPO_DIR/config}"

# shellcheck disable=SC1091
. "$LIB_DIR/config.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/gemini.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/github.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/output.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/prompt.sh"

DEFAULT_REQUIRED_CHECKS_FILE="$CONFIG_DIR/required-checks.json"
if [ ! -f "$DEFAULT_REQUIRED_CHECKS_FILE" ] && [ -f "$CONFIG_DIR/required-checks.example.json" ]; then
  DEFAULT_REQUIRED_CHECKS_FILE="$CONFIG_DIR/required-checks.example.json"
fi
DEFAULT_PROJECT_DOCS_FILE="$CONFIG_DIR/project-docs.txt"
if [ ! -f "$DEFAULT_PROJECT_DOCS_FILE" ] && [ -f "$CONFIG_DIR/project-docs.example.txt" ]; then
  DEFAULT_PROJECT_DOCS_FILE="$CONFIG_DIR/project-docs.example.txt"
fi
DEFAULT_HEAD_CONTEXT_PATHS_FILE="$CONFIG_DIR/head-context-paths.txt"
if [ ! -f "$DEFAULT_HEAD_CONTEXT_PATHS_FILE" ] && [ -f "$CONFIG_DIR/head-context-paths.example.txt" ]; then
  DEFAULT_HEAD_CONTEXT_PATHS_FILE="$CONFIG_DIR/head-context-paths.example.txt"
fi
REQUIRED_CHECKS_FILE="${REVIEWER_REQUIRED_CHECKS_FILE:-$DEFAULT_REQUIRED_CHECKS_FILE}"
PROJECT_DOCS_FILE="${REVIEWER_PROJECT_DOCS_FILE:-$DEFAULT_PROJECT_DOCS_FILE}"
HEAD_CONTEXT_PATHS_FILE="${REVIEWER_HEAD_CONTEXT_PATHS_FILE:-$DEFAULT_HEAD_CONTEXT_PATHS_FILE}"
PERSONALITY_FILE="${REVIEWER_PERSONALITY_FILE:-}"
case "$PERSONALITY_FILE" in
  ''|/*) ;;
  *) PERSONALITY_FILE="$REPO_DIR/$PERSONALITY_FILE" ;;
esac
ALLOW_REQUIRED_CHECKS_OVERRIDE="${REVIEWER_ALLOW_REQUIRED_CHECKS_OVERRIDE:-0}"
HEAD_CONTEXT_MAX_LINES="${REVIEWER_HEAD_CONTEXT_MAX_LINES:-180}"
PROJECT_DOC_MAX_LINES="${REVIEWER_PROJECT_DOC_MAX_LINES:-240}"
DEFAULT_PROJECT_DOC_PATHS=$'AGENTS.md\nCONTRIBUTING.md\nREADME.md\ndocs/pr-review-workflow.md'
DEFAULT_HEAD_CONTEXT_PATHS=$'README.md\nCONTRIBUTING.md\nAGENTS.md\n.github/workflows/ci.yml'
REVIEWER_RUNNER_NAME="${REVIEWER_RUNNER_NAME:-reviewer daemon}"

SEEN_FILE="$STATE_DIR/seen.txt"
LOG_FILE="$STATE_DIR/log.txt"
LOCK_FILE="$STATE_DIR/lock"
GEMINI_BACKOFF_FILE="$STATE_DIR/gemini_backoff_until"

mkdir -p "$STATE_DIR"
touch "$SEEN_FILE"

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

validate_reviewer_config
load_effective_required_checks_json
load_required_checks_display

PROJECT_DOC_PATHS="${REVIEWER_PROJECT_DOC_PATHS:-$(read_path_list "$PROJECT_DOCS_FILE" "$DEFAULT_PROJECT_DOC_PATHS")}"
HEAD_CONTEXT_PATHS="${REVIEWER_HEAD_CONTEXT_PATHS:-$(read_path_list "$HEAD_CONTEXT_PATHS_FILE" "$DEFAULT_HEAD_CONTEXT_PATHS")}"

if remaining=$(gemini_backoff_remaining); then
  log "Gemini quota backoff active for ${remaining}s"
  exit 0
fi

if [ -z "${GH_TOKEN:-}" ]; then
  GH_TOKEN=$("$SCRIPT_DIR/get-installation-token.sh" token 2>>"$LOG_FILE") || { log "failed to mint installation token"; exit 1; }
  export GH_TOKEN
fi
if [ -z "${REVIEWER_APP_SLUG:-}" ]; then
  REVIEWER_APP_SLUG=$("$SCRIPT_DIR/get-installation-token.sh" slug 2>>"$LOG_FILE") || { log "failed to fetch app slug"; exit 1; }
fi
BOT_LOGIN="${REVIEWER_APP_SLUG}[bot]"
if [ -z "$SKIP_USER" ]; then
  SKIP_USER="$BOT_LOGIN"
fi

PRS=$(gh pr list --repo "$REPO" --state open --json number,author,headRefOid,isDraft \
  --jq '.[] | select(.isDraft == false) | [.number, .author.login, .headRefOid] | @tsv')

review_actions=0

while IFS=$'\t' read -r num author head_sha; do
  [ -n "${num:-}" ] || continue
  [ -n "${head_sha:-}" ] || { log "PR #$num has no head SHA, skipping"; continue; }
  [ -z "$ONLY_PR" ] || [ "$num" = "$ONLY_PR" ] || continue
  [ "$author" != "$SKIP_USER" ] || continue

  if [ "$review_actions" -ge "$MAX_PRS" ]; then
    log "Reached REVIEWER_MAX_PRS=$MAX_PRS, stopping this tick"
    break
  fi

  seen_key="$num $head_sha"
  if grep -qxF "$seen_key" "$SEEN_FILE"; then
    continue
  fi

  existing=$(gh api "repos/$REPO/pulls/$num/reviews" \
    --jq "[.[] | select(.user.login == \"$BOT_LOGIN\" and .commit_id == \"$head_sha\")] | length")
  if [ "$existing" -gt 0 ]; then
    log "PR #$num@$head_sha already reviewed by $BOT_LOGIN, marking seen"
    echo "$seen_key" >> "$SEEN_FILE"
    continue
  fi

  if ! ci_state=$(REQUIRED_CHECKS_JSON="$EFFECTIVE_REQUIRED_CHECKS_JSON" bash "$SCRIPT_DIR/check-ci.sh" "$REPO" "$head_sha" "$REQUIRED_CHECKS_FILE" 2>>"$LOG_FILE"); then
    log "PR #$num@$head_sha: failed to read CI check-runs, will retry next tick"
    continue
  fi

  case "$ci_state" in
    success)
      ;;
    pending|incomplete)
      log "PR #$num@$head_sha: CI not yet terminal (state=$ci_state), will retry next tick"
      continue
      ;;
    failing)
      log "PR #$num@$head_sha: CI is failing, posting REQUEST_CHANGES without Gemini"
      ci_summary=$(gh pr checks "$num" --repo "$REPO" 2>>"$LOG_FILE" || true)
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
      if post_review "$num" "REQUEST_CHANGES" "$ci_failure_body" "[]"; then
        echo "$seen_key" >> "$SEEN_FILE"
        log "Posted REQUEST_CHANGES (CI failure) on PR #$num@$head_sha"
        review_actions=$((review_actions + 1))
      else
        log "Failed to post REQUEST_CHANGES (CI failure) on PR #$num@$head_sha, will retry next tick"
      fi
      continue
      ;;
    *)
      log "PR #$num@$head_sha: unexpected CI state '$ci_state', will retry next tick"
      continue
      ;;
  esac

  log "Reviewing PR #$num@$head_sha"

  meta=$(gh pr view "$num" --repo "$REPO" --json title,body,author,baseRefName,headRefName,headRefOid,url)
  checks=$(gh pr checks "$num" --repo "$REPO" 2>>"$LOG_FILE" || true)
  prompt_tmp=$(mktemp "$STATE_DIR/prompt.$num.XXXXXX")
  tree_tmp=$(mktemp "$STATE_DIR/tree.$num.XXXXXX")
  diff_paths_tmp=$(mktemp "$STATE_DIR/diff-paths.$num.XXXXXX")

  if ! gh api "repos/$REPO/git/trees/$head_sha?recursive=1" \
    --jq '.tree[] | select(.type=="blob") | .path' >"$tree_tmp" 2>>"$LOG_FILE"; then
    log "PR #$num@$head_sha: failed to read PR head file tree; continuing with empty tree context"
    : >"$tree_tmp"
  fi

  if ! gh pr diff "$num" --repo "$REPO" --name-only >"$diff_paths_tmp" 2>>"$LOG_FILE"; then
    log "PR #$num@$head_sha: failed to read PR diff paths; inline comments will rely on GitHub validation"
    rm -f "$diff_paths_tmp"
  fi

  build_review_prompt "$num" "$head_sha" "$ci_state" "$required_checks_display" "$meta" "$checks" "$tree_tmp" "$prompt_tmp"
  rm -f "$tree_tmp"

  gemini_err_tmp=$(mktemp "$STATE_DIR/gemini.$num.err.XXXXXX")
  if ! review=$(run_gemini_review "$prompt_tmp" "$gemini_err_tmp"); then
    cat "$gemini_err_tmp" >> "$LOG_FILE"
    set_gemini_quota_backoff "$gemini_err_tmp" || true
    rm -f "$prompt_tmp" "$gemini_err_tmp" "$diff_paths_tmp"
    log "gemini failed for PR #$num, will retry next tick"
    continue
  fi
  cat "$gemini_err_tmp" >> "$LOG_FILE"
  rm -f "$prompt_tmp" "$gemini_err_tmp"

  if [ -z "${review// }" ]; then
    rm -f "$diff_paths_tmp"
    log "gemini returned empty for PR #$num, will retry next tick"
    continue
  fi

  if ! event=$(printf '%s' "$review" | review_verdict_event); then
    rm -f "$diff_paths_tmp"
    verdict_line=$(printf '%s' "$review" | grep -m 1 '^VERDICT: ' || true)
    log "PR #$num: gemini did not emit a valid VERDICT line (got: $verdict_line), will retry next tick"
    continue
  fi

  meta_json=$(printf '%s' "$review" | review_meta_json_or_empty "PR #$num")
  comments_json=$(review_inline_comments_json "$meta_json" "$diff_paths_tmp")
  rm -f "$diff_paths_tmp"

  review_body=$(printf '%s' "$review" | review_body_after_verdict | strip_review_meta)
  if [ "$author" = "$BOT_LOGIN" ] && [ "$event" != "COMMENT" ]; then
    log "PR #$num is authored by $BOT_LOGIN; posting $event verdict as COMMENT"
    event="COMMENT"
    review_body=$(cat <<EOF
Note: GitHub does not allow @$BOT_LOGIN to approve or request changes on their own PR, so this automated review was posted as a comment.

$review_body
EOF
)
  fi

  body=$(cat <<EOF
$review_body

---
*Drafted by \`gemini\` running on $REVIEWER_RUNNER_NAME, posted by @$BOT_LOGIN. Verdict and findings are gemini's; no human read this diff before posting.*
EOF
)

  if [ -n "$DRY_RUN" ]; then
    inline_count=$(printf '%s' "$comments_json" | jq 'length')
    log "Dry run: would post $event review on PR #$num@$head_sha with $inline_count inline comments"
    review_actions=$((review_actions + 1))
    continue
  fi

  if post_review "$num" "$event" "$body" "$comments_json"; then
    sync_pr_checklist "$num" "$meta_json" || log "PR #$num: failed to sync agent checklist"
    apply_review_labels "$num" "$event" "$meta_json" || log "PR #$num: failed to apply review labels"
    echo "$seen_key" >> "$SEEN_FILE"
    log "Posted $event review on PR #$num@$head_sha"
    review_actions=$((review_actions + 1))
  else
    log "Failed to post review on PR #$num@$head_sha, will retry next tick"
  fi
done <<< "$PRS"
