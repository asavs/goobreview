#!/usr/bin/env bash
# GitHub mutation helpers for posting reviews and syncing review side effects.

post_review() {
  local num="$1"
  local event="$2"
  local body="$3"
  local comments_json="$4"
  local payload

  payload=$(jq -n \
    --arg event "$event" \
    --arg body "$body" \
    --argjson comments "$comments_json" \
    '{event: $event, body: $body} + (if ($comments | length) > 0 then {comments: $comments} else {} end)')

  if printf '%s' "$payload" | gh api -X POST "repos/$REPO/pulls/$num/reviews" --input - >/dev/null 2>>"$LOG_FILE"; then
    return 0
  fi

  if [ "$(printf '%s' "$comments_json" | jq 'length')" -gt 0 ]; then
    log "PR #$num: inline review post failed, retrying as top-level review"
    payload=$(jq -n --arg event "$event" --arg body "$body" '{event: $event, body: $body}')
    printf '%s' "$payload" | gh api -X POST "repos/$REPO/pulls/$num/reviews" --input - >/dev/null 2>>"$LOG_FILE"
    return $?
  fi

  return 1
}

sync_pr_checklist() {
  local num="$1"
  local meta_json="$2"
  local current_body cleaned_body blockers block new_body start_count end_count

  [ "$UPDATE_CHECKLIST" = "1" ] || return 0

  current_body=$(gh pr view "$num" --repo "$REPO" --json body --jq '.body // ""' 2>>"$LOG_FILE") || return 1
  start_count=$(printf '%s\n' "$current_body" | grep -c '^<!-- agent-review-checklist:start -->$' || true)
  end_count=$(printf '%s\n' "$current_body" | grep -c '^<!-- agent-review-checklist:end -->$' || true)

  if [ "$start_count" -ne "$end_count" ] || [ "$start_count" -gt 1 ]; then
    log "PR #$num: malformed agent checklist markers, refusing to mutate PR body"
    return 1
  fi

  if [ "$start_count" -eq 1 ]; then
    cleaned_body=$(printf '%s\n' "$current_body" | sed '/^<!-- agent-review-checklist:start -->$/,/^<!-- agent-review-checklist:end -->$/d')
  else
    cleaned_body="$current_body"
  fi

  if [ -z "${meta_json// }" ]; then
    [ "$current_body" = "$cleaned_body" ] && return 0
    gh pr edit "$num" --repo "$REPO" --body "$cleaned_body" >/dev/null 2>>"$LOG_FILE"
    return $?
  fi

  blockers=$(printf '%s' "$meta_json" | jq -r '
    [
      .findings[]?
      | select(.blocking == true or .severity == "P1")
      | "- [ ] [`" + (.id // "finding") + "`] [" + (.severity // "P1") + "] " + (.title // "Finding") +
        (if ((.path // "") != "") then
          " (`" + .path + (if (.line | type) == "number" then ":" + (.line | tostring) else "" end) + "`)"
        else
          ""
        end)
    ] | .[]')

  if [ -z "${blockers// }" ]; then
    [ "$current_body" = "$cleaned_body" ] && return 0
    gh pr edit "$num" --repo "$REPO" --body "$cleaned_body" >/dev/null 2>>"$LOG_FILE"
    return $?
  fi

  block=$(cat <<EOF
<!-- agent-review-checklist:start -->
## Agent Review Checklist

$blockers
<!-- agent-review-checklist:end -->
EOF
)

  new_body=$(printf '%s\n\n%s\n' "$cleaned_body" "$block")
  gh pr edit "$num" --repo "$REPO" --body "$new_body" >/dev/null 2>>"$LOG_FILE"
}

apply_review_labels() {
  local num="$1"
  local event="$2"
  local meta_json="${3:-}"
  local labels_json

  [ "$APPLY_LABELS" = "1" ] || return 0

  labels_json=$(printf '%s' "${meta_json:-{}}" | jq -c --arg event "$event" '
    ["agent-reviewed"]
    + (if $event == "REQUEST_CHANGES" then ["agent-requested-changes"] else [] end)
    + (if $event == "COMMENT" then ["needs-human-decision"] else [] end)
    + (if ((.follow_up_issues // []) | length) > 0 then ["follow-up-candidates"] else [] end)
    | unique
    | {labels: .}')

  printf '%s' "$labels_json" | gh api -X POST "repos/$REPO/issues/$num/labels" --input - >/dev/null 2>>"$LOG_FILE"
}
