#!/usr/bin/env bash
# GitHub API and review posting fixtures for the reviewer suite. Sourced by run-fixtures.sh, which
# provides the assert helpers, TMP_ROOT, and the sourced reviewer libs; the
# runner's registration list controls execution order.
# shellcheck disable=SC2034,SC2154,SC2317,SC2329

test_github_api_retries_and_logs() {
  local bin_dir curl_state curl_args log_file output_file status old_path

  bin_dir="$TMP_ROOT/github-api-bin"
  curl_state="$TMP_ROOT/github-api-count"
  curl_args="$TMP_ROOT/github-api-args"
  log_file="$TMP_ROOT/github-api.log"
  output_file="$TMP_ROOT/github-api.out"
  mkdir -p "$bin_dir"
  : > "$curl_args"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
body_file=""
headers_file=""
url="${*: -1}"
printf '%s\n' "$*" >> "$GITHUB_API_TEST_ARGS"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      body_file="$2"
      shift 2
      ;;
    -D)
      headers_file="$2"
      shift 2
      ;;
    -w)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$headers_file" ] && printf 'HTTP/2 200\n' > "$headers_file"
count=$(cat "$GITHUB_API_TEST_COUNT" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$GITHUB_API_TEST_COUNT"
case "$url" in
  *retry*)
    if [ "$count" -eq 1 ]; then
      printf 'server error token=%s\n' "$GH_TOKEN" > "$body_file"
      printf '500'
      exit 0
    fi
    printf '{"ok":true}\n' > "$body_file"
    printf '200'
    exit 0
    ;;
  *missing*)
    printf '{"message":"not found"}\n' > "$body_file"
    printf '404'
    exit 0
    ;;
  *)
    printf 'unexpected url %s\n' "$url" >&2
    printf '000'
    exit 7
    ;;
esac
EOF
  chmod +x "$bin_dir/curl"

  old_path="$PATH"
  status=0
  GH_TOKEN='secret-token' \
  REVIEWER_GITHUB_RETRIES=1 \
  REVIEWER_GITHUB_RETRY_SLEEP=0 \
  REVIEWER_GITHUB_CONNECT_TIMEOUT=3 \
  REVIEWER_GITHUB_MAX_TIME=9 \
  GITHUB_API_TEST_COUNT="$curl_state" \
  GITHUB_API_TEST_ARGS="$curl_args" \
  PATH="$bin_dir:$old_path" \
    bash -c '. scripts/reviewer/lib/github-api.sh; github_api_get "repos/example/repo/retry"' >"$output_file" 2>"$log_file" || status=$?
  if [ "$status" -ne 0 ]; then
    sed -n '1,120p' "$log_file" >&2
    fail "GitHub API retry returns eventual success body"
  fi
  assert_eq "GitHub API retry returns eventual success body" '{"ok":true}' "$(cat "$output_file")"
  assert_eq "GitHub API retry attempts once after transient status" "2" "$(cat "$curl_state")"
  assert_contains "GitHub API retry log records HTTP status" "http=500" "$log_file"
  assert_contains "GitHub API retry log redacts token snippets" "token=[REDACTED]" "$log_file"
  assert_not_contains "GitHub API retry log does not leak token" "secret-token" "$log_file"
  assert_contains "GitHub API curl uses connect timeout knob" "--connect-timeout 3" "$curl_args"
  assert_contains "GitHub API curl uses max time knob" "--max-time 9" "$curl_args"

  printf '0\n' > "$curl_state"
  status=0
  GH_TOKEN='secret-token' \
  REVIEWER_GITHUB_RETRIES=3 \
  REVIEWER_GITHUB_RETRY_SLEEP=0 \
  GITHUB_API_TEST_COUNT="$curl_state" \
  GITHUB_API_TEST_ARGS="$curl_args" \
  PATH="$bin_dir:$old_path" \
    bash -c '. scripts/reviewer/lib/github-api.sh; github_api_get "repos/example/repo/missing"' > /dev/null 2>"$log_file" || status=$?
  if [ "$status" -eq 0 ]; then
    fail "GitHub API non-retryable 404 fails"
  fi
  pass "GitHub API non-retryable 404 fails"
  assert_eq "GitHub API does not retry non-retryable 404" "1" "$(cat "$curl_state")"
}

test_post_review_uses_rest_api() {
  local captured_path captured_payload inline_comments

  REPO="example/repo"
  LOG_FILE="$TMP_ROOT/post-review.log"
  : > "$LOG_FILE"

  # shellcheck disable=SC2317 # Mocked API helper is invoked indirectly by post_review.
  github_api_post_json() {
    captured_path="$1"
    captured_payload="$2"
    printf '{"id": 1}\n'
  }

  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture review body.
  inline_comments='[{"path":"src/app.py","line":42,"side":"RIGHT","body":"This is stale.\n\n```suggestion\nrender()\n```","_goobreview_anchor_introduced":true,"_goobreview_finding_introduced":true}]'
  post_review 17 REQUEST_CHANGES "Please fix this." deadbeef "$inline_comments"

  assert_eq "post_review posts to pull reviews REST endpoint" "repos/example/repo/pulls/17/reviews" "$captured_path"
  assert_eq "post_review sends review event" "REQUEST_CHANGES" "$(printf '%s\n' "$captured_payload" | jq -r '.event')"
  assert_eq "post_review sends review body" "Please fix this." "$(printf '%s\n' "$captured_payload" | jq -r '.body')"
  assert_eq "post_review ties review to analyzed head" "deadbeef" "$(printf '%s\n' "$captured_payload" | jq -r '.commit_id')"
  assert_eq "post_review includes inline comments atomically" "src/app.py" "$(printf '%s\n' "$captured_payload" | jq -r '.comments[0].path')"
  assert_contains "post_review preserves suggestion fences in inline comment body" '```suggestion' <(printf '%s\n' "$captured_payload" | jq -r '.comments[0].body')
  assert_eq "post_review strips internal scope metadata" "false" "$(printf '%s\n' "$captured_payload" | jq 'any(.comments[0] | keys[]; startswith("_goobreview_"))')"

  if post_review 17 NOPE "bad" deadbeef '[]' >/dev/null 2>&1; then
    fail "post_review rejects invalid event"
  fi
  pass "post_review rejects invalid event"

  if post_review 17 COMMENT "bad" deadbeef '{}' >/dev/null 2>&1; then
    fail "post_review rejects non-array inline comments"
  fi
  pass "post_review rejects non-array inline comments"
}

test_review_check_run_signal_helpers() {
  local path_file payload_file

  REPO="example/repo"
  LOG_FILE="$TMP_ROOT/check-run.log"
  path_file="$TMP_ROOT/check-run-captured-path"
  payload_file="$TMP_ROOT/check-run-captured-payload"
  : > "$LOG_FILE"

  assert_eq "APPROVE maps to success check conclusion" "success" "$(review_check_run_conclusion_for_event APPROVE)"
  assert_eq "REQUEST_CHANGES maps to failure check conclusion" "failure" "$(review_check_run_conclusion_for_event REQUEST_CHANGES)"
  assert_eq "COMMENT maps to neutral check conclusion" "neutral" "$(review_check_run_conclusion_for_event COMMENT)"
  if review_check_run_conclusion_for_event NOPE >/dev/null; then
    fail "unknown review event has no check conclusion"
  fi
  pass "unknown review event has no check conclusion"

  # File-based capture: github_create_review_check_run reads the mock through a
  # command substitution, so variable assignments would die with the subshell.
  # shellcheck disable=SC2317 # Mocked API helper is invoked indirectly.
  github_api_post_json() {
    printf '%s\n' "$1" > "$path_file"
    printf '%s\n' "$2" > "$payload_file"
    printf '{"id": 42}\n'
  }

  assert_eq "check run create returns the new id" "42" "$(github_create_review_check_run deadbeef)"
  assert_eq "check run create posts to the check-runs endpoint" "repos/example/repo/check-runs" "$(cat "$path_file")"
  assert_eq "check run create names the goobreview check" "goobreview" "$(jq -r '.name' "$payload_file")"
  assert_eq "check run create targets the reviewed head" "deadbeef" "$(jq -r '.head_sha' "$payload_file")"
  assert_eq "check run create starts in_progress" "in_progress" "$(jq -r '.status' "$payload_file")"

  # shellcheck disable=SC2317 # Mocked API helper is invoked indirectly.
  github_api_post_json() { return 1; }
  if github_create_review_check_run deadbeef >/dev/null 2>&1; then
    fail "check run create propagates API failure"
  fi
  pass "check run create propagates API failure"

  # shellcheck disable=SC2317 # Mocked API helper is invoked indirectly.
  github_api_patch_json() {
    printf '%s\n' "$1" > "$path_file"
    printf '%s\n' "$2" > "$payload_file"
    printf '{"id": 42}\n'
  }
  github_conclude_review_check_run 42 success "Review posted: APPROVE" "GoobReview posted an APPROVE review on this head SHA."
  assert_eq "check run conclude patches the check-run id" "repos/example/repo/check-runs/42" "$(cat "$path_file")"
  assert_eq "check run conclude completes the run" "completed" "$(jq -r '.status' "$payload_file")"
  assert_eq "check run conclude records the review conclusion" "success" "$(jq -r '.conclusion' "$payload_file")"
  assert_eq "check run conclude carries the outcome title" "Review posted: APPROVE" "$(jq -r '.output.title' "$payload_file")"

  if github_conclude_review_check_run 42 bogus "t" "s" >/dev/null 2>&1; then
    fail "check run conclude rejects unknown conclusions"
  fi
  pass "check run conclude rejects unknown conclusions"
}

test_inline_review_comments_follow_diff_anchors() {
  local body comments

  REPO="example/repo"
  LOG_FILE="$TMP_ROOT/inline-comments.log"
  : > "$LOG_FILE"

  # shellcheck disable=SC2317 # Mocked API helper is invoked indirectly by review_inline_comments_json.
  github_api_paginate_array() {
    printf '%s\n' '{"filename":"src/app.py","patch":"@@ -10,1 +10,0 @@\n-old-only\n@@ -40,3 +40,5 @@\n context\n-old\n+new\n+another\n+third\n context-after"}'
  }

  body="### Render stays stale
Location: src/app.py:42
The line is read from a ref that does not schedule a render.

### Suggest direct replacement
Location: src/app.py:42-43
This should schedule a render immediately.

\`\`\`suggestion
setState(new)
render()
\`\`\`

### Malformed suggestion stays out of native inline comments
Location: src/app.py:42
This has an unclosed suggestion fence.

\`\`\`suggestion
setState(other)

### Not on this diff
Location: src/other.py:9
This is outside the changed lines.

### Deleted line
Location: src/app.py:10
This was removed without a replacement.

### Context-only line
Location: src/app.py:40
This line is not itself changed.

### Old symptom has new cause
Location: src/app.py:41
The old symptom at \`src/app.py:44\` fails only because this line now passes the new value.

### Incomplete range
Location: src/app.py:43-99
This starts on the diff but extends outside it.

### Missing line
Location: src/app.py:99
This does not exist."
  comments=$(review_inline_comments_json 17 "$body")

  assert_eq "inline-comment parser emits verified anchors including context lines" "6" "$(printf '%s\n' "$comments" | jq 'length')"
  assert_eq "inline-comment parser prefers added side" "RIGHT" "$(printf '%s\n' "$comments" | jq -r '.[0].side')"
  assert_eq "inline-comment parser strips heading from posted inline body" "The line is read from a ref that does not schedule a render." "$(printf '%s\n' "$comments" | jq -r '.[0].body | split("\n")[0]')"
  assert_not_contains "inline-comment parser strips Location lines from posted bodies" "Location:" <(printf '%s\n' "$comments" | jq -r '.[].body')
  assert_contains "inline-comment parser preserves valid suggestion fence" '```suggestion' <(printf '%s\n' "$comments" | jq -r '.[] | select(.line == 43) | .body')
  assert_eq "inline-comment parser emits multi-line suggestion start_line" "42" "$(printf '%s\n' "$comments" | jq -r '.[] | select(.body | contains("schedule a render immediately")) | .start_line')"
  assert_eq "inline-comment parser emits multi-line suggestion start_side" "RIGHT" "$(printf '%s\n' "$comments" | jq -r '.[] | select(.body | contains("schedule a render immediately")) | .start_side')"
  assert_eq "inline-comment parser marks introduced findings as PR-scoped" "true" "$(printf '%s\n' "$comments" | jq -r '.[0]._goobreview_finding_introduced')"
  assert_eq "inline-comment parser marks context-only findings as out of scope" "false" "$(printf '%s\n' "$comments" | jq -r '.[] | select(.body | contains("This line is not itself changed.")) | ._goobreview_finding_introduced')"
  assert_eq "inline-comment parser keeps old-symptom new-cause findings PR-scoped" "true" "$(printf '%s\n' "$comments" | jq -r '.[] | select(.body | contains("old symptom at")) | ._goobreview_finding_introduced')"
  assert_eq "inline-comment parser records old-symptom cause as introduced" "true" "$(printf '%s\n' "$comments" | jq -r '.[] | select(.body | contains("old symptom at")) | ._goobreview_anchor_introduced')"
  assert_eq "inline-comment parser counts PR-scoped findings" "4" "$(printf '%s\n' "$comments" | review_inline_comments_pr_scoped_count)"
  assert_eq "scope guard preserves request changes with any PR-scoped finding" "REQUEST_CHANGES" "$(review_event_after_scope_guard REQUEST_CHANGES "$comments")"
  assert_eq "scope guard downgrades all out-of-scope blocking findings" "COMMENT" "$(review_event_after_scope_guard REQUEST_CHANGES '[{"_goobreview_finding_introduced":false}]')"
  assert_eq "scope guard leaves body-only blocking findings alone" "REQUEST_CHANGES" "$(review_event_after_scope_guard REQUEST_CHANGES '[]')"
  assert_not_contains "inline-comment parser omits malformed suggestion fence from native comments" "Malformed suggestion" <(printf '%s\n' "$comments" | jq -r '.[].body')
  assert_eq "inline-comment parser anchors deleted lines on the left" "LEFT" "$(printf '%s\n' "$comments" | jq -r '.[] | select(.line == 10) | .side')"
  assert_eq "inline-comment parser anchors context lines on the right" "RIGHT" "$(printf '%s\n' "$comments" | jq -r '.[] | select(.line == 40) | .side')"
  assert_eq "inline-comment parser falls back to single-line anchor for incomplete ranges" "null" "$(printf '%s\n' "$comments" | jq -r '.[] | select(.body | contains("starts on the diff")) | .start_line')"
}

test_suggestion_cap_demotes_oversized_blocks() {
  local old_cap exact_sections demoted body comments

  old_cap="${SUGGESTION_MAX_LINES:-}"
  SUGGESTION_MAX_LINES=2

  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture review body.
  exact_sections=$(printf '%s\n' \
    '### Exact cap stays applicable' \
    'Location: src/app.py:42-43' \
    'The changed range needs a replacement.' \
    '' \
    '```suggestion' \
    'setState(new)' \
    'render()' \
    '```' |
    review_markdown_finding_sections | tr '\0' '\n')
  assert_contains "suggestion cap preserves fence at exact limit" '```suggestion' <(printf '%s' "$exact_sections")
  assert_not_contains "suggestion cap does not mark exact-limit fence" '[goobreview: suggestion of' <(printf '%s' "$exact_sections")

  demoted=$(printf '%s\n' \
    '```suggestion' \
    'setState(new)' \
    'render()' \
    'notify()' \
    '```' |
    review_demote_oversized_suggestions)
  assert_not_contains "suggestion cap demotes oversized opening fence" '```suggestion' <(printf '%s' "$demoted")
  assert_contains "suggestion cap keeps oversized block as plain fence" '```' <(printf '%s' "$demoted")
  assert_contains "suggestion cap preserves oversized body" 'notify()' <(printf '%s' "$demoted")
  assert_contains "suggestion cap marker includes actual and maximum counts" '[goobreview: suggestion of 3 lines exceeds the 2-line cap; shown as a snippet, not an applicable suggestion.]' <(printf '%s' "$demoted")

  REPO="example/repo"
  LOG_FILE="$TMP_ROOT/suggestion-cap-inline.log"
  : > "$LOG_FILE"

  # shellcheck disable=SC2317 # Mocked API helper is invoked indirectly by review_inline_comments_json.
  github_api_paginate_array() {
    printf '%s\n' '{"filename":"src/app.py","patch":"@@ -40,1 +40,5 @@\n context\n+setState(old)\n+renderOld()\n+notifyOld()\n+doneOld()"}'
  }

  body="### Exact cap inline suggestion
Location: src/app.py:42-43
This should keep the applicable replacement.

\`\`\`suggestion
setState(new)
render()
\`\`\`

### Oversized inline suggestion
Location: src/app.py:42-44
This should not expose an Apply suggestion button.

\`\`\`suggestion
setState(new)
render()
notify()
\`\`\`"
  comments=$(review_inline_comments_json 17 "$body")
  assert_contains "inline suggestion cap preserves exact-limit suggestion" '```suggestion' <(printf '%s\n' "$comments" | jq -r '.[] | select(._goobreview_heading // "" | contains("Exact cap inline")) | .body')
  assert_not_contains "inline suggestion cap demotes oversized suggestion before promotion" '```suggestion' <(printf '%s\n' "$comments" | jq -r '.[] | select(._goobreview_heading // "" | contains("Oversized inline")) | .body')
  assert_contains "inline suggestion cap marker includes both counts" 'suggestion of 3 lines exceeds the 2-line cap' <(printf '%s\n' "$comments" | jq -r '.[] | select(._goobreview_heading // "" | contains("Oversized inline")) | .body')

  if [ -n "$old_cap" ]; then
    SUGGESTION_MAX_LINES="$old_cap"
  else
    unset SUGGESTION_MAX_LINES
  fi
}
test_review_thread_resolution_helpers() {
  local threads current_threads handle_map handles_file calls_file reply_calls_file resolved selected_ids resolvable_handle

  calls_file="$TMP_ROOT/resolve-thread-calls"
  reply_calls_file="$TMP_ROOT/resolve-thread-reply-calls"
  handles_file="$TMP_ROOT/resolve-thread-handles"
  : > "$calls_file"
  : > "$reply_calls_file"
  printf '%s\n' null-deref-footgun stale-render not-a-real-thread > "$handles_file"

  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture comment bodies.
  threads='[
    {
      "id": "thread-resolvable",
      "isResolved": false,
      "viewerCanResolve": true,
      "path": "src/app.py",
      "line": 42,
      "comments": {"nodes": [{"author": {"login": "goobreview[bot]"}, "body": "### Null deref footgun\n`src/app.py:42` dereferences a possibly-null ref."}]}
    },
    {
      "id": "thread-not-resolvable",
      "isResolved": false,
      "viewerCanResolve": false,
      "path": "src/app.py",
      "line": 45,
      "comments": {"nodes": [{"author": {"login": "goobreview[bot]"}, "body": "### Stale render\n`src/app.py:45` never schedules a render."}]}
    },
    {
      "id": "thread-already-resolved",
      "isResolved": true,
      "viewerCanResolve": true,
      "path": "src/app.py",
      "line": 46,
      "comments": {"nodes": [{"author": {"login": "goobreview[bot]"}, "body": "### Already handled\nFixed."}]}
    }
  ]'

  handle_map=$(printf '%s\n' "$threads" | github_review_thread_handle_map_json)
  resolvable_handle=$(printf '%s\n' "$handle_map" | jq -r '.[] | select(.id == "thread-resolvable") | .handle')
  assert_eq "handle map derives a slug from the thread heading" "null-deref-footgun" "$resolvable_handle"
  current_threads='[
    {
      "id": "thread-resolvable",
      "isResolved": false,
      "viewerCanResolve": true
    },
    {
      "id": "thread-not-resolvable",
      "isResolved": false,
      "viewerCanResolve": false
    }
  ]'
  selected_ids=$(github_resolvable_review_thread_ids_for_handles "$handle_map" "$handles_file" "$current_threads")
  assert_eq "resolver maps selected handles through latest GitHub state" "thread-resolvable" "$selected_ids"

  # shellcheck disable=SC2317 # Mocked API helper is invoked indirectly by github_resolve_review_thread_handles_json.
  github_api_graphql() {
    local query="$1" thread_id
    thread_id=$(printf '%s\n' "$2" | jq -r '.threadId')
    if printf '%s' "$query" | grep -q 'addPullRequestReviewThreadReply'; then
      printf '%s\n' "$thread_id" >>"$reply_calls_file"
      jq -n --arg id "$thread_id" '{data: {addPullRequestReviewThreadReply: {comment: {id: ("c-" + $id)}}}}'
      return 0
    fi
    printf '%s\n' "$thread_id" >>"$calls_file"
    jq -n --arg thread_id "$thread_id" \
      '{data: {resolveReviewThread: {thread: {id: $thread_id, isResolved: true}}}}'
  }

  resolved=$(github_resolve_review_thread_handles_json "$handle_map" "$handles_file" "$current_threads" deadbeef)
  assert_eq "resolver resolves only explicitly selected resolvable threads" "1" "$resolved"
  assert_eq "resolver calls GitHub mutation only for the selected resolvable thread" "thread-resolvable" "$(cat "$calls_file")"
  assert_eq "resolver posts a confirming reply before resolving the thread" "thread-resolvable" "$(cat "$reply_calls_file")"
}

test_review_state_uses_github_reviews_only() {
  if declare -F apply_review_labels >/dev/null; then
    fail "reviewer does not retain label state helper"
  fi
  pass "reviewer does not retain label state helper"

  if [ -e "$REVIEWER_DIR/ensure-labels.sh" ]; then
    fail "reviewer does not ship label setup helper"
  fi
  pass "reviewer does not ship label setup helper"

  assert_not_contains "review posting has no Issues API side effect" "/issues/" "$LIB_DIR/github.sh"
}
