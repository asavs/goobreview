#!/usr/bin/env bash
# GitHub mutation helpers for posting reviews and syncing review side effects.

post_review() {
  local num="$1"
  local event="$2"
  local body="$3"
  local payload

  case "$event" in
    APPROVE|REQUEST_CHANGES|COMMENT) ;;
    *)                log "invalid review event: $event"; return 1 ;;
  esac

  payload=$(jq -n --arg event "$event" --arg body "$body" '{event: $event, body: $body}')
  github_api_post_json "repos/$REPO/pulls/$num/reviews" "$payload" >/dev/null
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

  github_api_post_json "repos/$REPO/issues/$num/labels" "$labels_json" >/dev/null 2>>"$LOG_FILE"
}
