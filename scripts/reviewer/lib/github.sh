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
            .anchors += [{path: $path, line: .new, side: "RIGHT", introduced: true}]
            | .new += 1
          elif ($raw | startswith("-")) then
            .anchors += [{path: $path, line: .old, side: "LEFT", introduced: false}]
            | .old += 1
          elif ($raw | startswith("\\ No newline")) then .
          else .anchors += [{path: $path, line: .new, side: "RIGHT", introduced: false}] | .old += 1 | .new += 1
          end)
    | .anchors[]
  '
}

github_pr_review_threads_json() {
  local num="$1"
  local owner repo_name query after variables response nodes has_next
  local threads_file

  owner="${REPO%%/*}"
  repo_name="${REPO#*/}"
  after=""
  threads_file=$(mktemp)

  # shellcheck disable=SC2016
  query='
    query($owner: String!, $name: String!, $number: Int!, $after: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100, after: $after) {
            pageInfo {
              hasNextPage
              endCursor
            }
            nodes {
              id
              isResolved
              isOutdated
              viewerCanResolve
              path
              line
              originalLine
              startLine
              originalStartLine
              diffSide
              startDiffSide
              comments(first: 20) {
                totalCount
                nodes {
                  author {
                    login
                  }
                  body
                  url
                  createdAt
                  path
                  line
                  originalLine
                  startLine
                  originalStartLine
                  outdated
                }
              }
            }
          }
        }
      }
    }'

  while :; do
    variables=$(jq -n \
      --arg owner "$owner" \
      --arg name "$repo_name" \
      --argjson number "$num" \
      --arg after "$after" \
      '{owner: $owner, name: $name, number: $number, after: (if $after == "" then null else $after end)}')
    if ! response=$(github_api_graphql "$query" "$variables"); then
      rm -f "$threads_file"
      return 1
    fi

    nodes=$(printf '%s\n' "$response" | jq -c '.data.repository.pullRequest.reviewThreads.nodes[]?') || {
      rm -f "$threads_file"
      return 1
    }
    if [ -n "$nodes" ]; then
      printf '%s\n' "$nodes" >>"$threads_file"
    fi
    has_next=$(printf '%s\n' "$response" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false') || {
      rm -f "$threads_file"
      return 1
    }
    [ "$has_next" = "true" ] || break
    after=$(printf '%s\n' "$response" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""') || {
      rm -f "$threads_file"
      return 1
    }
    [ -n "$after" ] || break
  done

  jq -s . "$threads_file"
  rm -f "$threads_file"
}

github_unresolved_bot_review_threads_json() {
  local threads_json="$1"
  local bot_login="$2"
  local bot_author="${3:-}"

  printf '%s\n' "$threads_json" |
    jq --arg bot "$bot_login" --arg bot_author "$bot_author" '
      [
        .[]?
        | select(.isResolved == false)
        | select(((.comments.nodes[0].author.login // "") == $bot)
            or ($bot_author != "" and (.comments.nodes[0].author.login // "") == $bot_author))
      ]'
}

# Assign each unresolved bot thread a stable, meaningful handle derived from
# the heading of its first (bot-authored) comment, slugified. The model named
# the bug when it opened the thread; we reuse that name as the address it
# refers back to, instead of an opaque ordinal. The handle is re-derived from
# live thread state every tick and only ever echoed back within the same
# prompt, so no name->id map is persisted. Collisions are disambiguated
# deterministically: a slug shared by two threads gains a "-l<line>" suffix,
# and any still-identical slug gains a "-<n>" running suffix.
github_review_thread_handle_map_json() {
  jq '
    def slugify($s):
      ($s // "")
      | ascii_downcase
      | gsub("[^a-z0-9]+"; "-")
      | gsub("^-+"; "")
      | gsub("-+$"; "")
      | .[0:48]
      | gsub("-+$"; "");
    def first_line($body):
      ($body // "") | split("\n") | (map(select(test("[^[:space:]]")))[0] // "");
    def heading($body):
      ($body // "")
      | split("\n")
      | (map(select(test("^[[:space:]]*#{1,6}[[:space:]]+")))[0] // "")
      | sub("^[[:space:]]*#{1,6}[[:space:]]+"; "")
      | sub("[[:space:]]+$"; "");
    [
      .[]?
      | select(.isResolved == false)
      | (.comments.nodes[0].body // "") as $body
      | (heading($body)) as $head
      | (if ($head | length) > 0 then slugify($head) else slugify(first_line($body)) end) as $base0
      | (if ($base0 | length) > 0 then $base0 else "thread" end) as $base
      | {
          id,
          viewerCanResolve: (.viewerCanResolve == true),
          path,
          line: (.line // .originalLine // null),
          subject: (first_line($body)),
          base: $base
        }
    ]
    | . as $items
    | (reduce $items[] as $it ({}; .[$it.base] += 1)) as $basecount
    | [ $items[]
        | . + {cand: (if ($basecount[.base] // 0) > 1
                      then (.base + "-l" + ((.line // 0) | tostring))
                      else .base end)} ] as $items2
    | (reduce $items2[] as $it ({}; .[$it.cand] += 1)) as $candcount
    | reduce range(0; ($items2 | length)) as $i ({seen: {}, out: []};
        $items2[$i] as $it
        | (.seen[$it.cand] // 0) as $n
        | (if ($candcount[$it.cand] // 0) > 1
           then ($it.cand + "-" + (($n + 1) | tostring))
           else $it.cand end) as $handle
        | .seen[$it.cand] = ($n + 1)
        | .out += [ {
            id: $it.id,
            viewerCanResolve: $it.viewerCanResolve,
            path: $it.path,
            line: $it.line,
            subject: $it.subject,
            handle: $handle
          } ])
    | .out
  '
}

github_resolvable_review_thread_ids() {
  jq -r '
    .[]?
    | select(.isResolved == false)
    | select(.viewerCanResolve == true)
    | .id // empty
  '
}

github_resolvable_review_thread_ids_for_handles() {
  local handle_map_json="$1"
  local handles_file="$2"
  local current_threads_json="${3:-$handle_map_json}"

  jq -r -R -s --argjson prompt_threads "$handle_map_json" --argjson current_threads "$current_threads_json" '
    ($current_threads
      | map(select(.isResolved == false and .viewerCanResolve == true) | .id)
    ) as $current_resolvable_ids
    |
    split("\n")
    | map(select(test("^[a-z0-9][a-z0-9-]*$")))
    | unique
    | . as $handles
    | $prompt_threads[] as $thread
    | select($handles | index($thread.handle))
    | select($current_resolvable_ids | index($thread.id))
    | $thread.id
  ' "$handles_file"
}

github_resolve_review_thread() {
  local thread_id="$1"
  local query variables response

  # shellcheck disable=SC2016
  query='
    mutation($threadId: ID!) {
      resolveReviewThread(input: {threadId: $threadId}) {
        thread {
          id
          isResolved
        }
      }
    }'
  variables=$(jq -n --arg threadId "$thread_id" '{threadId: $threadId}')
  response=$(github_api_graphql "$query" "$variables") || return 1
  printf '%s\n' "$response" |
    jq -e --arg threadId "$thread_id" '
      .data.resolveReviewThread.thread.id == $threadId
      and .data.resolveReviewThread.thread.isResolved == true
    ' >/dev/null
}

# Post a reply comment into an existing review thread. The reviewer is text-only
# and never holds the token, so the engine carries its conversational turns to
# GitHub on its behalf.
github_reply_to_review_thread() {
  local thread_id="$1"
  local body="$2"
  local query variables response

  # shellcheck disable=SC2016
  query='
    mutation($threadId: ID!, $body: String!) {
      addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) {
        comment {
          id
        }
      }
    }'
  variables=$(jq -n --arg threadId "$thread_id" --arg body "$body" '{threadId: $threadId, body: $body}')
  response=$(github_api_graphql "$query" "$variables") || return 1
  printf '%s\n' "$response" |
    jq -e '.data.addPullRequestReviewThreadReply.comment.id != null' >/dev/null
}

# Resolve each selected bot thread, leaving a confirming reply first so the
# resolution reads as a conversation turn ("confirmed fixed, resolving") rather
# than a silent state flip. The reply is best-effort; a failed reply never
# blocks the resolution itself.
github_resolve_review_thread_handles_json() {
  local handle_map_json="$1"
  local handles_file="$2"
  local current_threads_json="${3:-$handle_map_json}"
  local head_sha="${4:-}"
  local id resolved=0 failed=0 reply_body

  if [ -n "$head_sha" ]; then
    reply_body="Confirmed fixed at ${head_sha} — resolving this thread."
  else
    reply_body="Confirmed fixed — resolving this thread."
  fi

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if ! github_reply_to_review_thread "$id" "$reply_body"; then
      printf 'failed to post resolve reply on review thread %s\n' "$id" >&2
    fi
    if github_resolve_review_thread "$id"; then
      resolved=$((resolved + 1))
    else
      failed=$((failed + 1))
    fi
  done < <(github_resolvable_review_thread_ids_for_handles "$handle_map_json" "$handles_file" "$current_threads_json")

  printf '%s\n' "$resolved"
  [ "$failed" -eq 0 ]
}

# Post a still-open acknowledgment reply to each unresolved thread listed in
# the replies file (handle<TAB>body pairs). Does not resolve — the reviewer
# flagged these as still present, so they should remain open for the author.
github_reply_still_open_thread_handles_json() {
  local handle_map_json="$1"
  local replies_file="$2"
  local current_threads_json="${3:-$handle_map_json}"
  local handle reply_body id replied=0 failed=0

  while IFS=$'\t' read -r handle reply_body; do
    [ -n "$handle" ] || continue
    id=$(printf '%s\n' "$handle_map_json" | jq -r --arg h "$handle" '.[] | select(.handle == $h) | .id // empty' | head -n 1)
    [ -n "$id" ] || continue
    if ! printf '%s\n' "$current_threads_json" | jq -e --arg id "$id" 'any(.[]; .id == $id and .isResolved == false)' >/dev/null 2>&1; then
      continue
    fi
    if github_reply_to_review_thread "$id" "$reply_body"; then
      replied=$((replied + 1))
    else
      printf 'failed to post still-open reply on review thread %s\n' "$id" >&2
      failed=$((failed + 1))
    fi
  done < "$replies_file"

  printf '%s\n' "$replied"
  [ "$failed" -eq 0 ]
}

# Convert ordinary Markdown finding sections into native inline-review
# comments. Only locations that GitHub's own diff exposes are emitted. This
# makes a bad or stale citation harmless instead of sending an invalid anchor
# to the review API.
#
# There is no line-matching dedup against existing threads: the reviewer is
# shown its open threads by handle and is asked to address each one explicitly
# (resolve, or leave open). Suppressing by cited path:line was error-prone -- a
# drifted line could silently swallow a genuine new finding. The replacement
# accepts the louder, safer failure (a visible duplicate thread) over a silent
# one (a dropped finding).
review_inline_comments_json() {
  local num="$1"
  local review_body="$2"
  local snapshot_root="${3:-}"
  local changed_files anchors comments seen section locations path start_line end_line anchor side anchor_introduced has_range chosen_anchor chosen_side chosen_start chosen_end chosen_has_range chosen_anchor_introduced finding_introduced

  changed_files=$(mktemp)
  anchors=$(mktemp)
  comments=$(mktemp)
  seen=$(mktemp)
  : >"$comments"
  : >"$seen"

  if ! github_api_paginate_array "repos/$REPO/pulls/$num/files" 2>>"$LOG_FILE" >"$changed_files"; then
    rm -f "$changed_files" "$anchors" "$comments" "$seen"
    return 1
  fi
  if ! github_review_changed_line_anchors <"$changed_files" >"$anchors"; then
    rm -f "$changed_files" "$anchors" "$comments" "$seen"
    return 1
  fi

  while IFS= read -r -d '' section; do
    locations=$(printf '%s' "$section" | review_explicit_source_locations "$snapshot_root")
    chosen_anchor=""
    chosen_side=""
    chosen_start=""
    chosen_end=""
    chosen_has_range=0
    chosen_anchor_introduced=false
    finding_introduced=false
    while IFS=$'\t' read -r path start_line end_line; do
      if [ -z "${path:-}" ] || [ -z "${start_line:-}" ]; then
        continue
      fi
      end_line="${end_line:-$start_line}"
      anchor=""
      has_range=0
      if [ "$end_line" -gt "$start_line" ]; then
        anchor=$(jq -s -c --arg path "$path" --argjson start "$start_line" --argjson end "$end_line" '
          map(select(.path == $path and .side == "RIGHT" and .line >= $start and .line <= $end)) as $hits
          | if (($hits | length) == ($end - $start + 1)
                and (($hits | map(.line) | sort) == [range($start; $end + 1)]))
            then {
              path: $path,
              start_line: $start,
              line: $end,
              side: "RIGHT",
              start_side: "RIGHT",
              introduced: (all($hits[]; .introduced == true))
            }
            else empty
            end
        ' "$anchors")
        if [ -n "$anchor" ]; then
          has_range=1
        fi
      fi
      if [ -z "$anchor" ]; then
        anchor=$(jq -c --arg path "$path" --argjson line "$start_line" \
          'select(.path == $path and .line == $line and .side == "RIGHT")' "$anchors" | head -n 1)
      fi
      if [ -z "$anchor" ]; then
        anchor=$(jq -c --arg path "$path" --argjson line "$start_line" \
          'select(.path == $path and .line == $line)' "$anchors" | head -n 1)
      fi
      [ -n "$anchor" ] || continue

      side=$(printf '%s' "$anchor" | jq -r '.side')
      anchor_introduced=$(printf '%s' "$anchor" | jq -r '.introduced == true')
      if [ "$anchor_introduced" = "true" ]; then
        finding_introduced=true
      fi
      if [ -n "$chosen_anchor" ]; then
        continue
      fi
      if grep -Fqx -- "$path"$'\t'"$start_line"$'\t'"$end_line"$'\t'"$side" "$seen"; then
        continue
      fi
      printf '%s\t%s\t%s\t%s\n' "$path" "$start_line" "$end_line" "$side" >>"$seen"
      chosen_anchor="$anchor"
      chosen_side="$side"
      chosen_start="$start_line"
      chosen_end="$end_line"
      chosen_has_range="$has_range"
      chosen_anchor_introduced="$anchor_introduced"
    done <<<"$locations"
    [ -n "$chosen_anchor" ] || continue
    if [ "$chosen_has_range" -eq 1 ]; then
      jq -n \
        --arg path "$(printf '%s' "$chosen_anchor" | jq -r '.path')" \
        --argjson start_line "$chosen_start" \
        --argjson line "$chosen_end" \
        --arg side "$chosen_side" \
        --argjson anchor_introduced "$chosen_anchor_introduced" \
        --argjson finding_introduced "$finding_introduced" \
        --arg body "$section" \
        '{path: $path, start_line: $start_line, start_side: $side, line: $line, side: $side, body: $body,
          _goobreview_anchor_introduced: $anchor_introduced,
          _goobreview_finding_introduced: $finding_introduced}' >>"$comments"
    else
      jq -n \
        --arg path "$(printf '%s' "$chosen_anchor" | jq -r '.path')" \
        --argjson line "$chosen_start" \
        --arg side "$chosen_side" \
        --argjson anchor_introduced "$chosen_anchor_introduced" \
        --argjson finding_introduced "$finding_introduced" \
        --arg body "$section" \
        '{path: $path, line: $line, side: $side, body: $body,
          _goobreview_anchor_introduced: $anchor_introduced,
          _goobreview_finding_introduced: $finding_introduced}' >>"$comments"
    fi
  done < <(printf '%s' "$review_body" | review_markdown_finding_sections)

  jq -s . "$comments"
  rm -f "$changed_files" "$anchors" "$comments" "$seen"
}

review_inline_comments_pr_scoped_count() {
  jq '[.[]? | select(._goobreview_finding_introduced == true)] | length'
}

review_event_after_scope_guard() {
  local event="$1"
  local inline_comments_json="$2"
  local inline_comment_count pr_scoped_inline_comment_count

  inline_comment_count=$(printf '%s\n' "$inline_comments_json" | jq 'length') || return 1
  pr_scoped_inline_comment_count=$(printf '%s\n' "$inline_comments_json" | review_inline_comments_pr_scoped_count) || return 1
  if [ "$event" = "REQUEST_CHANGES" ] && [ "$inline_comment_count" -gt 0 ] && [ "$pr_scoped_inline_comment_count" -eq 0 ]; then
    printf 'COMMENT\n'
  else
    printf '%s\n' "$event"
  fi
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
    '($comments | map(with_entries(select(.key | startswith("_goobreview_") | not)))) as $post_comments
    | {event: $event, body: $body, commit_id: $commit_id} + if ($post_comments | length) > 0 then {comments: $post_comments} else {} end')
  github_api_post_json "repos/$REPO/pulls/$num/reviews" "$payload" >/dev/null
}
