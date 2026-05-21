#!/usr/bin/env bash
# GitHub mutation helpers for posting reviews and syncing review side effects.

post_review() {
  local num="$1"
  local event="$2"
  local body="$3"
  local flag

  case "$event" in
    APPROVE)          flag="--approve" ;;
    REQUEST_CHANGES)  flag="--request-changes" ;;
    COMMENT)          flag="--comment" ;;
    *)                log "invalid review event: $event"; return 1 ;;
  esac

  printf '%s' "$body" | gh pr review "$num" --repo "$REPO" "$flag" --body-file - >/dev/null 2>>"$LOG_FILE"
}

apply_review_labels() {
  local num="$1"
  local event="$2"
  local labels_json

  [ "$APPLY_LABELS" = "1" ] || return 0

  labels_json=$(jq -n -c --arg event "$event" '
    ["agent-reviewed"]
    + (if $event == "REQUEST_CHANGES" then ["agent-requested-changes"] else [] end)
    + (if $event == "COMMENT" then ["needs-human-decision"] else [] end)
    | unique
    | {labels: .}')

  printf '%s' "$labels_json" | gh api -X POST "repos/$REPO/issues/$num/labels" --input - >/dev/null 2>>"$LOG_FILE"
}
