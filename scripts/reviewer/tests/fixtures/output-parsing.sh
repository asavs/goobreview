#!/usr/bin/env bash
# Review-output parsing fixtures for the reviewer suite. Sourced by run-fixtures.sh, which
# provides the assert helpers, TMP_ROOT, and the sourced reviewer libs; the
# runner's registration list controls execution order.
# shellcheck disable=SC2034,SC2154,SC2317,SC2329

test_output_parser() {
  local valid approve expected_body locations sections malformed_sections resolved_handles

  # shellcheck disable=SC2016
  valid='## Summary
This helper lets callers spoof users.

## Blocking Findings
### User spoofing
Location: src/auth.py:42

Impact: Anyone can select a different user by query string.
Fix: Use the authenticated session user instead.
REQUEST_CHANGES'
  expected_body=$(printf '%s' "$valid" | sed '$d')

  assert_eq "valid verdict maps to event" "REQUEST_CHANGES" "$(printf '%s' "$valid" | review_verdict_event)"
  assert_eq "review body strips only final verdict line" "$expected_body" "$(printf '%s' "$valid" | review_body_before_verdict)"
  assert_eq "file and line references stay in body" "1" "$(printf '%s' "$valid" | review_body_before_verdict | grep -c 'src/auth.py:42')"

  locations=$(printf '%s\n' \
    "See \`src/auth.py:42\` and src/auth.py:42-45." \
    'The generated file dist/app.js:9 is not a second finding.' \
    '../outside.py:3 must not be accepted as a repository path.' |
    review_source_locations)
  assert_eq "source-location parser finds unique path and line ranges" $'src/auth.py\t42\t42\nsrc/auth.py\t42\t45\ndist/app.js\t9\t9' "$locations"

  file_url_locations=$(printf '%s\n' \
    "[Player.tsx:530](file:///tmp/test-snap/client/src/Player.tsx#L530-L535)" |
    review_source_locations "/tmp/test-snap")
  assert_eq "source-location parser extracts repo-relative range from file-url link" \
    $'client/src/Player.tsx\t530\t535' "$file_url_locations"

  sections=$(printf '%s\n' \
    '## Summary' \
    'No blocking findings.' \
    '' \
    '### Session can be spoofed' \
    'Location: src/auth.py:42' \
    "The query string controls the effective user." \
    '' \
    '```suggestion' \
    'user = session.user' \
    '```' \
    '' \
    '### Unrelated note' \
    'No source location.' |
    review_markdown_finding_sections | tr '\0' '\n')
  assert_contains "finding-section parser keeps explicit-location finding heading" "### Session can be spoofed" <(printf '%s' "$sections")
  assert_not_contains "finding-section parser skips sections without Location" "### Unrelated note" <(printf '%s' "$sections")
  assert_contains "finding-section parser preserves valid suggestion fences" '```suggestion' <(printf '%s' "$sections")

  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture review text.
  h1_sections=$(printf '%s\n' \
    '# Alias try_files redirect loop' \
    'Location: deploy/nginx/mog.conf:43' \
    'The alias block causes a redirect loop.' |
    review_markdown_finding_sections | tr '\0' '\n')
  assert_contains "finding-section parser accepts h1 headings" "# Alias try_files redirect loop" <(printf '%s' "$h1_sections")

  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture review text.
  malformed_sections=$(printf '%s\n' \
    '### Broken suggestion fence' \
    'Location: src/auth.py:42' \
    'The changed line needs a replacement.' \
    '```suggestion' \
    'return session.user' |
    review_markdown_finding_sections | tr '\0' '\n')
  assert_not_contains "finding-section parser rejects malformed suggestion fences for inline promotion" "### Broken suggestion fence" <(printf '%s' "$malformed_sections")

  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture review text.
  resolved_handles=$(printf '%s\n' \
    '## Summary' \
    'null-deref-footgun is mentioned here but must not resolve.' \
    '' \
    '## Unresolved Prior Threads' \
    '- still-open-thing must stay open.' \
    '' \
    '## Resolved Prior Threads' \
    '- null-deref-footgun fixed by the session rewrite.' \
    '- `p2-stale-render` no longer reproduces.' \
    '- null-deref-footgun duplicate should only appear once.' \
    '' \
    '## Remaining Findings' \
    '- off-by-one is still broken.' |
    review_resolved_thread_handles)
  assert_eq "resolved-thread parser extracts leading slug handle per bullet in resolved section only" $'null-deref-footgun\np2-stale-render' "$resolved_handles"

  if printf 'NOPE\n' | review_verdict_event >/dev/null; then
    fail "malformed verdict is rejected"
  fi
  pass "malformed verdict is rejected"

  if printf 'APPROVE\nintro\n' | review_verdict_event >/dev/null; then
    fail "verdict must be final non-empty line"
  fi
  pass "verdict must be final non-empty line"

  approve='## Summary
No findings.
APPROVE'
  assert_eq "approve output remains parseable without metadata" "APPROVE" "$(printf '%s' "$approve" | review_verdict_event)"

  assert_eq "verdict line tolerates CRLF and whitespace" "APPROVE" "$(printf '%s\r\n' '  APPROVE' | review_verdict_event)"
  if printf '%s\n' 'approve' | review_verdict_event >/dev/null; then
    fail "verdict remains case-sensitive"
  fi
  pass "verdict remains case-sensitive"
}

# Recovery heuristic (motivated by a live review that put every citation in the
# finding heading and anchored nothing): a section whose heading carries a
# path:line token is promotable even without a Location line. Explicit Location
# lines still win, prose citations never anchor.
test_heading_location_fallback() {
  local heading_section heading_loc explicit_wins neither_section prose_loc range_loc

  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture review text.
  heading_section=$(printf '%s\n' \
    '### Stationary remote player animation defaults to left in `client/src/components/RemotePlayer.tsx:31`' \
    'The default direction is wrong for a stationary player.' |
    review_markdown_finding_sections | tr '\0' '\n')
  assert_contains "finding-section parser emits a heading-anchored section without a Location line" \
    '### Stationary remote player animation defaults to left' <(printf '%s' "$heading_section")

  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture review text.
  heading_loc=$(printf '%s\n' \
    '### Stationary remote player defaults to left in `client/src/components/RemotePlayer.tsx:31`' \
    'The default direction is wrong.' |
    review_explicit_source_locations)
  assert_eq "heading path:line token yields the section location when no Location line exists" \
    $'client/src/components/RemotePlayer.tsx\t31\t31' "$heading_loc"

  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture review text.
  explicit_wins=$(printf '%s\n' \
    '### Bug near `client/src/A.tsx:99`' \
    'Location: client/src/B.tsx:5' \
    'The real anchor is the explicit line, not the heading token.' |
    review_explicit_source_locations)
  assert_eq "explicit Location line takes precedence over a heading token in the same section" \
    $'client/src/B.tsx\t5\t5' "$explicit_wins"

  neither_section=$(printf '%s\n' \
    '### Heading with no citation at all' \
    'The bug lives at src/prose.ts:12 down here in the body.' |
    review_markdown_finding_sections | tr '\0' '\n')
  assert_not_contains "finding-section parser skips a section with neither a Location line nor a heading token" \
    '### Heading with no citation' <(printf '%s' "$neither_section")

  # A section with no Location line and no heading token never reaches this
  # extractor in the daemon (review_markdown_finding_sections drops it first);
  # calling it directly, the empty result trips grep's no-match exit under the
  # suite's `set -e`, so the capture is guarded like the other empty-output cases.
  prose_loc=$(printf '%s\n' \
    '### Heading with no citation at all' \
    'The bug lives at src/prose.ts:12 down here in the body.' |
    review_explicit_source_locations || true)
  assert_eq "path:line in the body prose does not anchor a heading-fallback section" "" "$prose_loc"

  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture review text.
  range_loc=$(printf '%s\n' \
    '### Off-by-one across `client/src/loop.ts:10-12`' \
    'The range boundary is mismatched.' |
    review_explicit_source_locations)
  assert_eq "heading range token yields an inclusive line range" \
    $'client/src/loop.ts\t10\t12' "$range_loc"
}

# A live review emitted its first Location line as a markdown link
# (`Location: [path:line](file://.../path)`), which the bare-token anchor parser
# would not swallow. Normalize the presentation of a Location value before
# extraction: collapse a markdown link to its TEXT (discarding the URL so no
# path:line is ever parsed out of a link target) and strip surrounding
# backticks. Safety stays downstream in snapshot/diff validation.
test_location_line_normalization() {
  local snap file_url_loc https_loc backtick_loc heading_link_loc url_only_loc

  snap="/tmp/goobreview-runtime-x/worktrees/y/heads/deadbeef"

  # Exact live shape (shortened): a file:// link Location. TEXT anchors; URL is
  # discarded entirely regardless of the snapshot root.
  # shellcheck disable=SC2016 # Backticks/link syntax are literal Markdown in the fixture.
  file_url_loc=$(printf '%s\n' \
    '### Snapshot applied without validation' \
    "Location: [scripts/apply-artifacts.sh:94-112](file://$snap/scripts/apply-artifacts.sh)" \
    'The snapshot is trusted blindly.' |
    review_explicit_source_locations "$snap")
  assert_eq "markdown-link Location with a file:// URL anchors to its TEXT token" \
    $'scripts/apply-artifacts.sh\t94\t112' "$file_url_loc"

  # A markdown-link Location with an https blob URL. The #L fragment in the URL
  # is not a path:line token, so only the TEXT anchors.
  # shellcheck disable=SC2016 # Backticks/link syntax are literal Markdown in the fixture.
  https_loc=$(printf '%s\n' \
    '### Off-by-one' \
    'Location: [client/src/loop.ts:10-12](https://github.com/asavs/goobreview/blob/deadbeef/client/src/loop.ts#L10-L12)' \
    'The range boundary is mismatched.' |
    review_explicit_source_locations)
  assert_eq "markdown-link Location with an https blob URL anchors to its TEXT token" \
    $'client/src/loop.ts\t10\t12' "$https_loc"

  # A backticked Location value normalizes to the bare token.
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture.
  backtick_loc=$(printf '%s\n' \
    '### Session can be spoofed' \
    'Location: `src/auth.py:42`' \
    'The query string controls the effective user.' |
    review_explicit_source_locations)
  assert_eq "backticked Location value normalizes to a bare path:line token" \
    $'src/auth.py\t42\t42' "$backtick_loc"

  # A heading carrying a link-wrapped path:line token still resolves via the
  # last-token rule; the #L fragment in the link target is not a location token.
  # shellcheck disable=SC2016 # Backticks/link syntax are literal Markdown in the fixture.
  heading_link_loc=$(printf '%s\n' \
    '### Off-by-one in [`client/src/loop.ts:10-12`](https://github.com/asavs/goobreview/blob/deadbeef/client/src/loop.ts#L10-L12)' \
    'The range boundary is mismatched.' |
    review_explicit_source_locations)
  assert_eq "heading link-wrapped path:line token anchors and ignores the URL target" \
    $'client/src/loop.ts\t10\t12' "$heading_link_loc"

  # Negative: the only path:line-shaped text lives inside the link URL. Because
  # the URL is discarded, nothing anchors. The empty result trips grep's no-match
  # exit under the suite's `set -e`, so the capture is guarded like the other
  # empty-output cases.
  # shellcheck disable=SC2016 # Link syntax is literal Markdown in the fixture.
  url_only_loc=$(printf '%s\n' \
    '### Suspicious raw link' \
    'Location: [see the diff here](https://example.com/raw/scripts/evil.sh:99)' \
    'Body text.' |
    review_explicit_source_locations || true)
  assert_eq "a path:line living only inside a Location link URL never anchors" \
    "" "$url_only_loc"
}

test_review_post_body_cleanup() {
  local anchored_linked bare_linked cleaned stripped summary wrapped_linked

  cleaned=$(printf '%s\n' \
    '### Broken cleanup' \
    'Location: client/src/hooks/useQaGameDebug.ts:58-69' \
    '' \
    'This cleanup deletes the active debug surface.' |
    review_inline_comment_post_body)
  assert_eq "inline post-body cleanup strips parser heading and location" \
    'This cleanup deletes the active debug surface.' "$cleaned"

  bare_linked=$(printf '%s\n' \
    'file:///tmp/snap/client/src/hooks/useQaGameDebug.ts' |
    review_rewrite_snapshot_file_links abc123 owner/repo /tmp/snap)
  assert_contains "anchor-less file-url links are rewritten to GitHub blob links" \
    'https://github.com/owner/repo/blob/abc123/client/src/hooks/useQaGameDebug.ts' \
    <(printf '%s' "$bare_linked")
  assert_not_contains "anchor-less file-url rewrite removes dead file scheme" 'file:///tmp/snap' <(printf '%s' "$bare_linked")

  wrapped_linked=$(printf '%s\n' \
    '[useQaGameDebug](file:///tmp/snap/client/src/hooks/useQaGameDebug.ts) is wrong.' |
    review_rewrite_snapshot_file_links abc123 owner/repo /tmp/snap)
  assert_contains "markdown-wrapped anchor-less file-url links keep the closing paren" \
    '[useQaGameDebug](https://github.com/owner/repo/blob/abc123/client/src/hooks/useQaGameDebug.ts) is wrong.' \
    <(printf '%s' "$wrapped_linked")
  assert_not_contains "markdown-wrapped anchor-less file-url rewrite removes dead file scheme" 'file:///tmp/snap' <(printf '%s' "$wrapped_linked")

  anchored_linked=$(printf '%s\n' \
    '[useQaGameDebug](file:///tmp/snap/client/src/hooks/useQaGameDebug.ts#L58-L69) is wrong.' |
    review_rewrite_snapshot_file_links abc123 owner/repo /tmp/snap)
  assert_contains "file-url links are rewritten to GitHub blob links" \
    'https://github.com/owner/repo/blob/abc123/client/src/hooks/useQaGameDebug.ts#L58-L69' \
    <(printf '%s' "$anchored_linked")
  assert_not_contains "file-url rewrite removes dead file scheme" 'file:///tmp/snap' <(printf '%s' "$anchored_linked")

  stripped=$(printf '%s\n' \
    'Seriously, this is broken.' \
    '' \
    'Here are the concrete issues that must be resolved before this can land:' |
    review_strip_dangling_finding_intro)
  assert_eq "dangling intro is stripped after inline promotion" 'Seriously, this is broken.' "$stripped"

  summary=$(review_inline_summary_body REQUEST_CHANGES 2)
  assert_eq "inline-only request changes gets non-empty summary" \
    'I found 2 merge-blocking findings and posted them inline.' "$summary"
}

test_review_body_dedup_filter() {
  local full_body promoted_json filtered

  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture review text.
  full_body='## Summary
This PR changes the auth path.

### Render stays stale
Location: src/app.py:42
This is read from a ref that does not schedule a render.

### Not promoted
Location: src/app.py:99
This has no diff anchor so it stays in the body.'

  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture review text.
  promoted_json='[{"path":"src/app.py","line":42,"side":"RIGHT","body":"### Render stays stale\nLocation: src/app.py:42\nThis is read from a ref that does not schedule a render."}]'

  filtered=$(printf '%s\n' "$full_body" | review_body_without_promoted_sections "$promoted_json")

  assert_not_contains "dedup filter strips promoted finding section from body" "### Render stays stale" <(printf '%s\n' "$filtered")
  assert_contains "dedup filter preserves summary section" "## Summary" <(printf '%s\n' "$filtered")
  assert_contains "dedup filter preserves non-promoted finding in body" "### Not promoted" <(printf '%s\n' "$filtered")
  assert_eq "dedup filter passthrough when no inline comments" \
    "$(printf '%s\n' "$full_body")" \
    "$(printf '%s\n' "$full_body" | review_body_without_promoted_sections '[]')"

  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture review text.
  h1_promoted_json='[{"path":"deploy/nginx/mog.conf","line":43,"side":"RIGHT","body":"# Alias redirect loop\nLocation: deploy/nginx/mog.conf:43\nThis alias causes a loop."}]'
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture text.
  h1_filtered=$(printf '%s\n' \
    '# Alias redirect loop' \
    'Location: deploy/nginx/mog.conf:43' \
    'This alias causes a loop.' |
    review_body_without_promoted_sections "$h1_promoted_json")
  assert_not_contains "dedup filter strips promoted h1 section from body" "Alias redirect loop" <(printf '%s\n' "$h1_filtered")

  # A heading-anchored finding (no Location line) is stripped the same way once
  # promoted, since the promoted comment's first line is the heading itself.
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture review text.
  heading_promoted_json='[{"path":"client/src/RemotePlayer.tsx","line":31,"side":"RIGHT","body":"### Defaults to left in `client/src/RemotePlayer.tsx:31`\nThe default direction is wrong."}]'
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture review text.
  heading_filtered=$(printf '%s\n' \
    '### Defaults to left in `client/src/RemotePlayer.tsx:31`' \
    'The default direction is wrong.' |
    review_body_without_promoted_sections "$heading_promoted_json")
  assert_not_contains "dedup filter strips a promoted heading-anchored section from the body" "Defaults to left in" <(printf '%s\n' "$heading_filtered")
}

test_unresolved_thread_replies_parser() {
  local replies

  # shellcheck disable=SC2016 # Backticks are literal Markdown in the fixture text.
  replies=$(printf '%s\n' \
    '## Resolved Prior Threads' \
    '- p2-stale-render confirmed fixed.' \
    '' \
    '## Unresolved Prior Threads' \
    '- null-deref-footgun still present — guard added to wrong branch.' \
    '- `missing-null-check`: not fixed — checked only the success path.' \
    '- null-deref-footgun duplicate should only appear once.' \
    '' \
    '## New Findings' \
    '- off-by-one is new.' |
    review_unresolved_thread_replies)

  assert_contains "unresolved reply parser extracts unresolved handle" "null-deref-footgun" <(printf '%s\n' "$replies")
  assert_contains "unresolved reply parser extracts reply body text" "guard added to wrong branch" <(printf '%s\n' "$replies")
  assert_contains "unresolved reply parser handles backtick-quoted handles" "missing-null-check" <(printf '%s\n' "$replies")
  assert_not_contains "unresolved reply parser ignores resolved section" "p2-stale-render" <(printf '%s\n' "$replies")
  assert_eq "unresolved reply parser deduplicates handles" "2" "$(printf '%s\n' "$replies" | grep -c $'\t' || printf 0)"
}

test_still_open_thread_reply_posting() {
  local handle_map replies_file replied reply_calls_file threads

  reply_calls_file="$TMP_ROOT/still-open-reply-calls"
  replies_file="$TMP_ROOT/still-open-replies.txt"
  : > "$reply_calls_file"

  handle_map='[
    {"handle": "null-deref-footgun", "id": "thread-1"},
    {"handle": "stale-render", "id": "thread-2"}
  ]'

  threads='[
    {"id": "thread-1", "isResolved": false},
    {"id": "thread-2", "isResolved": true}
  ]'

  printf '%s\t%s\n' "null-deref-footgun" "still present — guard added to wrong branch" > "$replies_file"
  printf '%s\t%s\n' "stale-render" "still open" >> "$replies_file"
  printf '%s\t%s\n' "not-in-map" "unmatched handle" >> "$replies_file"

  # shellcheck disable=SC2317 # Mocked API helper is invoked indirectly.
  github_api_graphql() {
    local thread_id
    thread_id=$(printf '%s\n' "$2" | jq -r '.threadId')
    printf '%s\n' "$thread_id" >> "$reply_calls_file"
    jq -n --arg id "$thread_id" '{data: {addPullRequestReviewThreadReply: {comment: {id: ("c-" + $id)}}}}'
  }

  replied=$(github_reply_still_open_thread_handles_json "$handle_map" "$replies_file" "$threads")
  assert_eq "still-open reply posts only to open unresolved threads" "1" "$replied"
  assert_eq "still-open reply targets the correct thread ID" "thread-1" "$(cat "$reply_calls_file")"
  assert_not_contains "still-open reply skips already-resolved thread" "thread-2" "$reply_calls_file"
}

# shellcheck disable=SC2016 # Fixtures intentionally use literal Markdown backticks.
test_trace_to_details() {
  local result

  # No trace — pass through unchanged
  result=$(printf '%s\n' \
    '## Summary' \
    'Looks fine.' \
    'APPROVE' | review_trace_to_details)
  assert_contains "no-trace content passes through unchanged" "## Summary" <(printf '%s' "$result")
  assert_not_contains "no-trace output has no details block" "<details>" <(printf '%s' "$result")

  # Trace with 2+ lines — wrapped in <details>
  result=$(printf '%s\n' \
    'I will check the directory structure of the snapshot.' \
    'I will view `src/main.ts` from the head snapshot.' \
    '' \
    'Are you kidding me?' \
    'APPROVE' | review_trace_to_details)
  assert_contains "trace is wrapped in details block" "<details>" <(printf '%s' "$result")
  assert_contains "trace details has summary" "Review trace" <(printf '%s' "$result")
  assert_contains "trace is followed by separator" "---" <(printf '%s' "$result")
  assert_contains "trace preserves original lines" "I will check the directory structure" <(printf '%s' "$result")
  assert_contains "trace preserves original lines" "I will view \`src/main.ts\`" <(printf '%s' "$result")
  assert_contains "actual review body follows separator" "Are you kidding me?" <(printf '%s' "$result")
  assert_eq "details block appears before review body" \
    "yes" \
    "$(printf '%s' "$result" | awk 'BEGIN{details_line=0; review_line=0} /^<details>/{details_line=NR} /^Are you kidding me/{review_line=NR} END{print (details_line > 0 && review_line > details_line ? "yes" : "no")}')"

  # Single trace line — no wrapping (threshold is 2)
  result=$(printf '%s\n' \
    'I will check the directory.' \
    '' \
    '## Summary' \
    'APPROVE' | review_trace_to_details)
  assert_not_contains "single trace line does not wrap" "<details>" <(printf '%s' "$result")

  # Non-trace first line — no wrapping
  result=$(printf '%s\n' \
    '## Summary' \
    'Looks fine.' \
    'APPROVE' | review_trace_to_details)
  assert_not_contains "non-trace first line does not trigger wrapping" "<details>" <(printf '%s' "$result")

  # Path linking within trace
  local tmp_worktree
  tmp_worktree=$(mktemp -d)
  mkdir -p "$tmp_worktree/client/src"
  touch "$tmp_worktree/client/src/main.ts"
  mkdir -p "$tmp_worktree/src"
  touch "$tmp_worktree/src/audio.ts"
  result=$(printf '%s\n' \
    'I will view `client/src/main.ts:42` from the head snapshot.' \
    'I will view `client/src/main.ts:10-12` in full.' \
    'I will view `src/audio.ts` too.' \
    'I will view `nonexistent.ts` — not in snapshot.' \
    '' \
    'Findings.' \
    'APPROVE' | review_trace_to_details "abc123" "owner/repo" "$tmp_worktree")
  assert_contains "cited line becomes a blob link with an #L line fragment" \
    '[`client/src/main.ts:42`](https://github.com/owner/repo/blob/abc123/client/src/main.ts#L42)' \
    <(printf '%s' "$result")
  assert_contains "cited line range becomes a blob link with an #L-range fragment" \
    '[`client/src/main.ts:10-12`](https://github.com/owner/repo/blob/abc123/client/src/main.ts#L10-L12)' \
    <(printf '%s' "$result")
  assert_contains "existing path without a line keeps a plain blob link for src/audio.ts" \
    '[`src/audio.ts`](https://github.com/owner/repo/blob/abc123/src/audio.ts)' \
    <(printf '%s' "$result")
  assert_contains "nonexistent path remains as plain backticks" \
    '`nonexistent.ts`' \
    <(printf '%s' "$result")
  assert_not_contains "nonexistent path does not get linked" \
    'nonexistent.ts`](https://' \
    <(printf '%s' "$result")
  rm -rf "$tmp_worktree"

  # Trace followed by empty lines then review — still wraps
  result=$(printf '%s\n' \
    'I will read the diff first.' \
    'I will examine the test files.' \
    '' \
    '' \
    '## Main Finding' \
    'APPROVE' | review_trace_to_details)
  assert_contains "trace wraps even with extra blank lines before review" "<details>" <(printf '%s' "$result")

  # I'll variant
  result=$(printf '%s\n' \
    "I'll check the files first." \
    "I'll view \`foo.ts\` next." \
    '' \
    'Findings.' \
    'APPROVE' | review_trace_to_details)
  assert_contains "I'll variant is detected as trace" "<details>" <(printf '%s' "$result")

  local trace_file trace_block sidecar_worktree
  sidecar_worktree=$(mktemp -d)
  mkdir -p "$sidecar_worktree/client/src"
  touch "$sidecar_worktree/client/src/main.ts"
  trace_file="$TMP_ROOT/thinking.trace"
  printf 'I will inspect `client/src/main.ts:99`.\nI will inspect `client/src/main.ts:5-8`.\nI will inspect `missing.ts`.\n' > "$trace_file"
  trace_block=$(review_trace_details_block "$trace_file" "abc123" "owner/repo" "$sidecar_worktree")
  assert_contains "sidecar trace emits compact details summary" "<details><summary>Review trace</summary>" <(printf '%s' "$trace_block")
  assert_contains "sidecar trace linkifies cited line with an #L fragment" \
    '[`client/src/main.ts:99`](https://github.com/owner/repo/blob/abc123/client/src/main.ts#L99)' \
    <(printf '%s' "$trace_block")
  assert_contains "sidecar trace linkifies cited range with an #L-range fragment" \
    '[`client/src/main.ts:5-8`](https://github.com/owner/repo/blob/abc123/client/src/main.ts#L5-L8)' \
    <(printf '%s' "$trace_block")
  assert_contains "sidecar trace leaves missing path unlinked" '`missing.ts`' <(printf '%s' "$trace_block")
  assert_contains "sidecar trace details ends with separator" "---" <(printf '%s' "$trace_block")

  # Regression (mog-template #179): reviewer.sh captures trace_block via
  # command substitution, which strips the trailing blank lines that
  # review_trace_details_block emits after "---", so a naive concatenation
  # with the review body glues the separator onto the body's first line
  # ("---logic here is completely brain-damaged."). The posted-body
  # assembly must go through review_body_with_trace_prefix, which restores
  # the blank line.
  local composed_body
  composed_body=$(review_body_with_trace_prefix "$trace_block" "Logic here is completely brain-damaged.")
  assert_not_contains "trace separator is not glued to the review body" \
    '---Logic here' \
    <(printf '%s' "$composed_body")
  # grep -F splits a pattern containing a literal newline into independent
  # per-line alternatives (matching any one of them), which would make this
  # assertion pass even on the unfixed, glued output -- so this checks the
  # exact contiguous substring via a bash glob comparison instead.
  if [[ "$composed_body" == *$'---\n\nLogic here is completely brain-damaged.'* ]]; then
    pass "trace separator is followed by a blank line before the body"
  else
    printf 'composed body did not have a blank line after the trace separator:\n%s\n' "$composed_body" >&2
    fail "trace separator is followed by a blank line before the body"
  fi
  rm -rf "$sidecar_worktree"
}

test_review_footer_note() {
  assert_eq "zero duration formats as seconds" "0s" "$(format_agy_duration 0)"
  assert_eq "sub-minute duration formats as seconds" "59s" "$(format_agy_duration 59)"
  assert_eq "minute duration formats with zero-padded seconds" "4m12s" "$(format_agy_duration 252)"
  assert_eq "non-numeric duration degrades to zero" "0s" "$(format_agy_duration bogus)"

  # shellcheck disable=SC2016 # Backticks are literal Markdown in the footer.
  assert_eq "footer carries model, duration, and linked engine sha" \
    '*Drafted autonomously by gemini-3-pro in 4m12s via goobreview antigravity-cli [`abc1234`](https://github.com/asavs/goobreview/commit/abc1234).*' \
    "$(review_footer_note "gemini-3-pro" 252 "abc1234")"
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the footer.
  assert_eq "footer omits engine link when sha is unknown" \
    '*Drafted autonomously by auto in 0s via goobreview antigravity-cli.*' \
    "$(review_footer_note "auto" 0 "unknown")"
}
