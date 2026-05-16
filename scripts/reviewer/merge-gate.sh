#!/usr/bin/env bash
set -euo pipefail

REPO="${REVIEWER_REPO:-}"
PR_NUMBER="${1:-${REVIEWER_ONLY_PR:-}}"
REQUIRE_CHECKS="${MERGE_GATE_REQUIRE_CHECKS:-0}"
REQUIRE_RESOLVED_THREADS="${MERGE_GATE_REQUIRE_RESOLVED_THREADS:-1}"

if [ -z "$REPO" ]; then
  printf 'missing REVIEWER_REPO; set it to owner/repo\n' >&2
  exit 2
fi

if [ -z "$PR_NUMBER" ]; then
  printf 'usage: %s <pr-number>\n' "$0" >&2
  exit 2
fi

require() { command -v "$1" >/dev/null || { printf 'missing: %s\n' "$1" >&2; exit 1; }; }
require gh
require jq

owner="${REPO%%/*}"
repo_name="${REPO#*/}"
fail=0

info=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json number,state,isDraft,mergeable,reviewDecision,headRefOid,title,url)
state=$(printf '%s' "$info" | jq -r '.state')
is_draft=$(printf '%s' "$info" | jq -r '.isDraft')
mergeable=$(printf '%s' "$info" | jq -r '.mergeable')
decision=$(printf '%s' "$info" | jq -r '.reviewDecision')
head_sha=$(printf '%s' "$info" | jq -r '.headRefOid')
title=$(printf '%s' "$info" | jq -r '.title')
url=$(printf '%s' "$info" | jq -r '.url')

printf 'PR #%s: %s\n%s\nhead: %s\n\n' "$PR_NUMBER" "$title" "$url" "$head_sha"

if [ "$state" != "OPEN" ]; then
  printf 'FAIL: PR state is %s, expected OPEN\n' "$state"
  fail=1
else
  printf 'OK: PR is open\n'
fi

if [ "$is_draft" = "true" ]; then
  printf 'FAIL: PR is still draft\n'
  fail=1
else
  printf 'OK: PR is ready for review\n'
fi

if [ "$mergeable" != "MERGEABLE" ]; then
  printf 'FAIL: PR mergeable state is %s\n' "$mergeable"
  fail=1
else
  printf 'OK: PR is mergeable\n'
fi

reviews=$(gh api "repos/$REPO/pulls/$PR_NUMBER/reviews")
head_approvals=$(printf '%s' "$reviews" | jq --arg head "$head_sha" '[.[] | select(.commit_id == $head and .state == "APPROVED")] | length')
head_changes=$(printf '%s' "$reviews" | jq --arg head "$head_sha" '[.[] | select(.commit_id == $head and .state == "CHANGES_REQUESTED")] | length')

if [ "$head_changes" -gt 0 ]; then
  printf 'FAIL: latest head has %s change-request review(s)\n' "$head_changes"
  fail=1
elif [ "$head_approvals" -gt 0 ] || [ "$decision" = "APPROVED" ]; then
  printf 'OK: latest head is approved\n'
else
  printf 'FAIL: latest head is not approved\n'
  fail=1
fi

if checks=$(gh pr checks "$PR_NUMBER" --repo "$REPO" 2>&1); then
  if printf '%s\n' "$checks" | grep -Eq 'fail|cancel|timed out|action_required'; then
    printf 'FAIL: one or more checks are failing\n'
    printf '%s\n' "$checks"
    fail=1
  else
    printf 'OK: checks are passing or neutral\n'
  fi
else
  if [ "$REQUIRE_CHECKS" = "1" ]; then
    printf 'FAIL: checks unavailable or failing\n%s\n' "$checks"
    fail=1
  else
    printf 'WARN: checks unavailable; MERGE_GATE_REQUIRE_CHECKS=1 would block\n'
  fi
fi

if [ "$REQUIRE_RESOLVED_THREADS" = "1" ]; then
  threads=$(gh api graphql \
    -f owner="$owner" \
    -f name="$repo_name" \
    -F number="$PR_NUMBER" \
    -f query='
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            reviewThreads(first: 100) {
              nodes {
                isResolved
              }
            }
          }
        }
      }')
  unresolved=$(printf '%s' "$threads" | jq '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved == false)] | length')
  if [ "$unresolved" -gt 0 ]; then
    printf 'FAIL: %s unresolved review thread(s)\n' "$unresolved"
    fail=1
  else
    printf 'OK: no unresolved review threads\n'
  fi
else
  printf 'WARN: unresolved review thread gate disabled\n'
fi

exit "$fail"
