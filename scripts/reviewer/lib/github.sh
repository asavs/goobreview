#!/usr/bin/env bash
# GitHub mutation helpers for posting reviews and syncing review side effects.

github_review_changed_line_anchors() {
  jq -s -c '
    .[]
    | select(.patch != null)
    | .filename as $path
    | .patch as $patch
    | reduce ($patch | split("\n")[]) as $raw
        ({old: null, new: null, anchors: []};
          if ($raw | startswith("@@ ")) then
            ($raw | capture("^@@ -(?<old>[0-9]+)(?:,[0-9]+)? \\+(?<new>[0-9]+)")) as $h
            | .old = ($h.old | tonumber)
            | .new = ($h.new | tonumber)
          elif .old == null then .
          elif ($raw | startswith("+")) then
            .anchors += [{path: $path, line: .new, side: "RIGHT"}]
            | .new += 1
          elif ($raw | startswith("-")) then
            .anchors += [{path: $path, line: .old, side: "LEFT"}]
            | .old += 1
          elif ($raw | startswith("\\ No newline")) then .
          else .old += 1 | .new += 1
          end)
    | .anchors[]
  '
}

# Convert ordinary Markdown finding sections into native inline-review
# comments. Only locations that GitHub's own diff exposes are emitted. This
# makes a bad or stale citation harmless instead of sending an invalid anchor
# to the review API.
review_inline_comments_json() {
  local num="$1"
  local review_body="$2"
  local changed_files anchors comments seen section locations path line anchor side

  changed_files=$(mktemp)
  anchors=$(mktemp)
  comments=$(mktemp)
  seen=$(mktemp)
  : >"comments"
  : >"seen"

  if ! github_api_paginate_array "repos/$REPO/pulls/$num/files" 2>>"$LOG_FILE" >"$changed_files"; then
    rm -f "$changed_files" "$anchors" "$comments" "$seen"
    return 1
  fi
  if ! github_review_changed_line_anchors <"$changed_files" >"$anchors"; then
    rm -f "$changed_files" "$anchors" "$comments" "$seen"
    return 1
  fi

  while IFS= read -r -d '' section; do
    locations=$(printf '%s' "$section" | review_source_locations)
    while IFS=$'\t' read -r path line; do
      [ -n "${path:-}" ] && [ -n "${line:-}" ] || continue
      anchor=$(jq -c --arg path "$path" --argjson line "$line" \
        'select(.path == $path and .line == $line and .side == "RIGHT")' "$anchors" | head -n 1)
      if [ -z "$anchor" ]; then
        anchor=$(jq -c --arg path "$path" --argjson line "$line" \
          'select(.path == $path and .line == $line)' "$anchors" | head -n 1)
      fi
      [ -n "$anchor" ] || continue

      side=$(printf '%s' "$anchor" | jq -r '.side')
      if grep -Fqx -- "$path"$'\t'"$line"$'\t'"$side" "$seen"; then
        break
      fi
      printf '%s\t%s\t%s\n' "$path" "$line" "$side" >>"$seen"
      jq -n --arg path "$path" --argjson line "$line" --arg side "$side" --arg body "$section" \
        '{path: $path, line: $line, side: $side, body: $body}' >>"$comments"
      break
    done <<<"$locations"
  done < <(printf '%s' "$review_body" | review_markdown_finding_sections)

  jq -s . "$comments"
  rm -f "$changed_files" "$anchors" "$comments" "$seen"
}

post_review() {
  local num="$1"
  local event="$2"
  local body="$3"
  local head_sha="$4"
  local comments_json="$5"
  local payload

  case "$event" in
    APPROVE|REQUEST_CHANGES|COMMENT) ;;
    *)                log "invalid review event: $event"; return 1 ;;
  esac

  if ! printf '%s' "$comments_json" | jq -e 'type == "array"' >/dev/null; then
    log "invalid inline review comments JSON"
    return 1
  fi

  payload=$(jq -n --arg event "$event" --arg body "$body" --arg commit_id "$head_sha" --argjson comments "$comments_json" \
    '{event: $event, body: $body, commit_id: $commit_id} + if ($comments | length) > 0 then {comments: $comments} else {} end')
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
