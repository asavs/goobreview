#!/usr/bin/env bash
# Reviewer end-to-end loop fixtures for the reviewer suite. Sourced by run-fixtures.sh, which
# provides the assert helpers, TMP_ROOT, and the sourced reviewer libs; the
# runner's registration list controls execution order.
# shellcheck disable=SC2034,SC2154,SC2317,SC2329

test_pr_queue_skip_reasons() {
  local pulls rows reason

  pulls='[{"number":1,"draft":true,"user":{"login":"alice"},"head":{"sha":"sha1"}},
    {"number":2,"draft":false,"user":{"login":"goobreview[bot]"},"head":{"sha":"sha2"}},
    {"number":3,"user":{"login":"maintainer"},"head":{"sha":"sha3"}},
    {"number":4,"draft":false,"user":{"login":"reviewer"},"head":{"sha":"sha4"}}]'
  rows=$(printf '%s\n' "$pulls" | jq -c '.[]' | pull_request_queue_rows)

  assert_contains "PR queue preserves draft rows" $'1\talice\tsha1\ttrue\t' <(printf '%s\n' "$rows")
  assert_contains "PR queue defaults missing draft to false" $'3\tmaintainer\tsha3\tfalse\t' <(printf '%s\n' "$rows")

  reason=$(reviewer_pr_skip_reason 1 alice sha1 true 'goobreview[bot]' '' '')
  assert_eq "draft skip reason is explicit" "PR #1@sha1 is a draft, skipping until it is marked ready for review" "$reason"

  reason=$(reviewer_pr_skip_reason 2 'goobreview[bot]' sha2 false 'goobreview[bot]' '' '')
  assert_eq "bot author skip reason is explicit" "PR #2@sha2 is authored by goobreview[bot], skipping self-review" "$reason"

  reason=$(reviewer_pr_skip_reason 2 'app/goobreview' sha2 false 'goobreview[bot]' '' '' 'app/goobreview')
  assert_eq "app author skip reason is explicit" "PR #2@sha2 is authored by goobreview[bot], skipping self-review" "$reason"

  reason=$(reviewer_pr_skip_reason 4 reviewer sha4 false 'goobreview[bot]' reviewer '')
  assert_eq "reviewer user skip reason is explicit" "PR #4@sha4 is authored by REVIEWER_USER=reviewer, skipping configured reviewer identity" "$reason"

  if reviewer_pr_skip_reason 3 maintainer sha3 false 'goobreview[bot]' reviewer '' >/dev/null; then
    fail "reviewable PR has no skip reason"
  fi
  pass "reviewable PR has no skip reason"

  if ! pr_has_requested_reviewer '{"requested_reviewers":[{"login":"goobreview[bot]"}]}' 'goobreview[bot]' 'app/goobreview'; then
    fail "requested bot reviewer is detected"
  fi
  pass "requested bot reviewer is detected"

  if pr_has_requested_reviewer '{"requested_reviewers":[{"login":"alice"}]}' 'goobreview[bot]' 'app/goobreview'; then
    fail "unrelated requested reviewer is ignored"
  fi
  pass "unrelated requested reviewer is ignored"
}

test_reviewer_re_requested_review_bypasses_reviewed_sha_skip() {
  local state_dir runtime_dir test_reviewer env_file key_file bin_dir ci_count posts_file reactions_file check_runs_file status output

  state_dir="$TMP_ROOT/re-request-state"
  runtime_dir="$TMP_ROOT/re-request-runtime"
  test_reviewer="$TMP_ROOT/re-request-reviewer"
  bin_dir="$TMP_ROOT/re-request-bin"
  ci_count="$TMP_ROOT/re-request-ci-count"
  posts_file="$TMP_ROOT/re-request-posts"
  reactions_file="$TMP_ROOT/re-request-reactions"
  check_runs_file="$TMP_ROOT/re-request-check-runs"
  mkdir -p "$state_dir" "$runtime_dir" "$bin_dir"
  cp -R "$REVIEWER_DIR" "$test_reviewer"
  : > "$posts_file"
  : > "$reactions_file"
  : > "$check_runs_file"

  cat > "$test_reviewer/get-installation-token.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  token) printf 'test-token\n' ;;
  slug)  printf 'goobreview\n' ;;
  *)     exit 1 ;;
esac
EOF
  chmod +x "$test_reviewer/get-installation-token.sh"

  cat > "$test_reviewer/check-ci.sh" <<EOF
#!/usr/bin/env bash
count=\$(cat "$ci_count" 2>/dev/null || printf 0)
count=\$((count + 1))
printf '%s\n' "\$count" > "$ci_count"
printf 'failing\n'
EOF
  chmod +x "$test_reviewer/check-ci.sh"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
method=GET
body_file=""
data=""
url="${*: -1}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X)
      method="$2"
      shift 2
      ;;
    -o)
      body_file="$2"
      shift 2
      ;;
    --data)
      data="$2"
      shift 2
      ;;
    -D|-w|-H)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
case "$method $url" in
  *'GET '*'repos/example/repo/pulls?state=open&per_page=100&page=1')
    if [ "${REQUEST_REVIEWER:-0}" = "1" ]; then
      printf '%s\n' '[{"number":1,"draft":false,"user":{"login":"alice"},"head":{"sha":"sha1"},"requested_reviewers":[{"login":"goobreview[bot]"}]}]' > "$body_file"
    else
      printf '%s\n' '[{"number":1,"draft":false,"user":{"login":"alice"},"head":{"sha":"sha1"},"requested_reviewers":[]}]' > "$body_file"
    fi
    printf '200'
    ;;
  *'GET '*'repos/example/repo/pulls/1/reviews?per_page=100&page=1')
    printf '%s\n' '[{"user":{"login":"goobreview[bot]"},"commit_id":"sha1","state":"APPROVED"}]' > "$body_file"
    printf '200'
    ;;
  *'GET '*'repos/example/repo/commits/sha1/check-runs?filter=latest&per_page=100&page=1')
    printf '%s\n' '{"total_count":1,"check_runs":[{"name":"ci","status":"completed","conclusion":"failure"}]}' > "$body_file"
    printf '200'
    ;;
  *'POST '*'repos/example/repo/issues/1/reactions')
    printf 'reaction\n' >> "$REACTIONS_FILE"
    printf '%s\n' '{"id":1,"content":"eyes"}' > "$body_file"
    printf '201'
    ;;
  *'POST '*'repos/example/repo/check-runs')
    printf 'create\n%s\n' "$data" >> "$CHECK_RUNS_FILE"
    printf '%s\n' '{"id":77}' > "$body_file"
    printf '201'
    ;;
  *'PATCH '*'repos/example/repo/check-runs/77')
    printf 'conclude\n%s\n' "$data" >> "$CHECK_RUNS_FILE"
    printf '%s\n' '{"id":77}' > "$body_file"
    printf '200'
    ;;
  *'POST '*'repos/example/repo/pulls/1/reviews')
    printf 'post\n' >> "$POSTS_FILE"
    printf '%s\n' '{"id":1}' > "$body_file"
    printf '200'
    ;;
  *)
    printf 'unexpected curl %s %s\n' "$method" "$url" >&2
    printf '000'
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/curl"

  cat > "$bin_dir/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bin_dir/gh"

  cat > "$bin_dir/agy" <<'EOF'
#!/usr/bin/env bash
printf 'Looks good.\nAPPROVE\n'
EOF
  chmod +x "$bin_dir/agy"

  key_file="$TMP_ROOT/re-request-key.pem"
  printf 'key\n' > "$key_file"
  chmod 600 "$key_file"

  printf '## Role\nReview.\n' > "$TMP_ROOT/re-request-personality.md"
  printf 'Final non-empty line: APPROVE, REQUEST_CHANGES, or COMMENT.\n' > "$TMP_ROOT/re-request-engine.md"
  printf '["ci"]\n' > "$TMP_ROOT/re-request-required.json"

  env_file="$TMP_ROOT/re-request.env"
  cat > "$env_file" <<EOF
REVIEWER_REPO=example/repo
REVIEWER_STATE=$state_dir
REVIEWER_RUNTIME_STATE=$runtime_dir
REVIEWER_APP_ID=1
REVIEWER_APP_INSTALLATION_ID=2
REVIEWER_APP_PRIVATE_KEY_PATH=$key_file
REVIEWER_PERSONALITY_FILE=$TMP_ROOT/re-request-personality.md
REVIEWER_PROMPT=$TMP_ROOT/re-request-engine.md
REVIEWER_REQUIRED_CHECKS_FILE=$TMP_ROOT/re-request-required.json
REVIEWER_MAX_PRS=1
REVIEWER_MAX_ATTEMPTS=1
EOF

  status=0
  # shellcheck disable=SC1090 # Fixture env file is created dynamically above.
  output=$(set -a; . "$env_file"; set +a; POSTS_FILE="$posts_file" REACTIONS_FILE="$reactions_file" CHECK_RUNS_FILE="$check_runs_file" PATH="$bin_dir:$PATH" bash "$test_reviewer/reviewer.sh" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    fail "reviewed SHA without re-request fixture exits successfully"
  fi
  pass "reviewed SHA without re-request fixture exits successfully"
  assert_not_contains "reviewed SHA without re-request does not post" "post" "$posts_file"
  assert_not_contains "skipped PR gets no review-started reaction" "reaction" "$reactions_file"
  assert_not_contains "skipped PR opens no review check run" "create" "$check_runs_file"
  assert_contains "reviewed SHA without re-request logs skip" "PR #1@sha1 already reviewed by goobreview[bot], skipping" "$state_dir/log.txt"

  : > "$posts_file"
  : > "$reactions_file"
  : > "$check_runs_file"
  : > "$state_dir/log.txt"
  rm -f "$ci_count"

  status=0
  # shellcheck disable=SC1090 # Fixture env file is created dynamically above.
  output=$(set -a; . "$env_file"; set +a; REQUEST_REVIEWER=1 POSTS_FILE="$posts_file" REACTIONS_FILE="$reactions_file" CHECK_RUNS_FILE="$check_runs_file" PATH="$bin_dir:$PATH" bash "$test_reviewer/reviewer.sh" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    fail "reviewed SHA with re-request fixture exits successfully"
  fi
  pass "reviewed SHA with re-request fixture exits successfully"
  assert_eq "re-requested review reaches CI gate" "1" "$(cat "$ci_count")"
  assert_not_contains "CI-failure fast path posts no PR review" "post" "$posts_file"
  assert_contains "CI-failure fast path still signals review start" "reaction" "$reactions_file"
  assert_contains "CI-failure fast path opens a review check run" "create" "$check_runs_file"
  assert_contains "CI-failure fast path concludes the review check run" "conclude" "$check_runs_file"
  assert_contains "CI-failure fast path concludes check run as failure" '"conclusion": "failure"' "$check_runs_file"
  assert_contains "CI-failure fast path explains no model review ran" "did not invoke the reviewer model or post a PR review" "$check_runs_file"
  assert_contains "CI-failure fast path logs no PR review" "Marked CI gate failure on PR #1@sha1 without posting a PR review" "$state_dir/log.txt"
  assert_contains "re-requested review logs bypass" "PR #1@sha1 already reviewed by goobreview[bot], but review was re-requested; reviewing again" "$state_dir/log.txt"
}

test_run_once_sync_failure_fails_closed() {
  local state_dir env_file output status

  state_dir="$TMP_ROOT/run-once-sync-failure"
  mkdir -p "$state_dir"
  env_file="$TMP_ROOT/run-once-sync-failure.env"
  cat > "$env_file" <<EOF
REVIEWER_STATE=$state_dir
REVIEWER_SYNC_REPO_DIR=$TMP_ROOT/not-a-git-worktree
EOF
  mkdir -p "$TMP_ROOT/not-a-git-worktree"

  status=0
  output=$(REVIEWER_ENV_FILE="$env_file" bash "$REVIEWER_DIR/run-once.sh" 2>&1) || status=$?

  if [ "$status" -eq 0 ]; then
    printf '%s\n' "$output" >&2
    fail "run-once exits nonzero when sync fails"
  fi
  pass "run-once exits nonzero when sync fails"
  assert_contains "run-once reports review did not run" "review did not run" <(printf '%s\n' "$output")
  assert_contains "run-once logs sync failure without review" "sync failed before reviewer tick; review did not run" "$state_dir/log.txt"
  assert_not_contains "run-once does not enter live reviewer after sync failure" "missing REVIEWER_REPO" "$state_dir/log.txt"
}

test_reviewer_attempt_budget_stops_repeated_expensive_failures() {
  local state_dir runtime_dir test_reviewer env_file key_file bin_dir attempts_file status output

  state_dir="$TMP_ROOT/attempt-budget-state"
  runtime_dir="$TMP_ROOT/attempt-budget-runtime"
  test_reviewer="$TMP_ROOT/attempt-budget-reviewer"
  bin_dir="$TMP_ROOT/attempt-budget-bin"
  attempts_file="$TMP_ROOT/attempt-budget-ci-attempts"
  mkdir -p "$state_dir" "$runtime_dir" "$bin_dir"
  cp -R "$REVIEWER_DIR" "$test_reviewer"

  cat > "$test_reviewer/get-installation-token.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  token) printf 'test-token\n' ;;
  slug)  printf 'goobreview\n' ;;
  *)     exit 1 ;;
esac
EOF
  chmod +x "$test_reviewer/get-installation-token.sh"

  cat > "$test_reviewer/check-ci.sh" <<EOF
#!/usr/bin/env bash
count=\$(cat "$attempts_file" 2>/dev/null || printf 0)
count=\$((count + 1))
printf '%s\n' "\$count" > "$attempts_file"
exit 1
EOF
  chmod +x "$test_reviewer/check-ci.sh"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
body_file=""
url="${*: -1}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      body_file="$2"
      shift 2
      ;;
    -D|-w)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
case "$url" in
  *'/repos/example/repo/pulls?state=open&per_page=100&page=1')
    printf '%s\n' '[{"number":1,"draft":false,"user":{"login":"alice"},"head":{"sha":"sha1"}},{"number":2,"draft":false,"user":{"login":"bob"},"head":{"sha":"sha2"}},{"number":3,"draft":false,"user":{"login":"carol"},"head":{"sha":"sha3"}}]' > "$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/pulls/'*'/reviews?per_page=100&page=1')
    printf '%s\n' '[]' > "$body_file"
    printf '200'
    ;;
  *)
    printf 'unexpected curl URL: %s\n' "$url" >&2
    printf '000'
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/curl"

  cat > "$bin_dir/agy" <<'EOF'
#!/usr/bin/env bash
printf 'Looks good.\nAPPROVE\n'
EOF
  chmod +x "$bin_dir/agy"

  key_file="$TMP_ROOT/attempt-budget-key.pem"
  printf 'key\n' > "$key_file"
  chmod 600 "$key_file"

  printf '## Role\nReview.\n' > "$TMP_ROOT/attempt-budget-personality.md"
  printf 'Final non-empty line: APPROVE, REQUEST_CHANGES, or COMMENT.\n' > "$TMP_ROOT/attempt-budget-engine.md"
  printf '["ci"]\n' > "$TMP_ROOT/attempt-budget-required.json"

  env_file="$TMP_ROOT/attempt-budget.env"
  cat > "$env_file" <<EOF
REVIEWER_REPO=example/repo
REVIEWER_DRY_RUN=1
REVIEWER_STATE=$state_dir
REVIEWER_RUNTIME_STATE=$runtime_dir
REVIEWER_APP_ID=1
REVIEWER_APP_INSTALLATION_ID=2
REVIEWER_APP_PRIVATE_KEY_PATH=$key_file
REVIEWER_PERSONALITY_FILE=$TMP_ROOT/attempt-budget-personality.md
REVIEWER_PROMPT=$TMP_ROOT/attempt-budget-engine.md
REVIEWER_REQUIRED_CHECKS_FILE=$TMP_ROOT/attempt-budget-required.json
REVIEWER_MAX_PRS=1
REVIEWER_MAX_ATTEMPTS=1
EOF

  status=0
  # shellcheck disable=SC1090 # Fixture env file is created dynamically above.
  output=$(set -a; . "$env_file"; set +a; PATH="$bin_dir:$PATH" bash "$test_reviewer/reviewer.sh" 2>&1) || status=$?

  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    fail "attempt budget fixture reviewer exits successfully"
  fi
  pass "attempt budget fixture reviewer exits successfully"
  assert_eq "attempt budget stops after first expensive failure" "1" "$(cat "$attempts_file")"
  assert_contains "attempt budget stop is logged" "Reached REVIEWER_MAX_ATTEMPTS=1 after 1 attempted review(s), stopping this tick" "$state_dir/log.txt"
  assert_not_contains "attempt budget does not walk second PR" "PR #2@sha2: failed to read CI check-runs" "$state_dir/log.txt"
}

test_reviewer_failure_cap_skips_poisoned_pr() {
  local state_dir runtime_dir test_reviewer env_file key_file bin_dir attempts_file status output

  state_dir="$TMP_ROOT/failure-cap-state"
  runtime_dir="$TMP_ROOT/failure-cap-runtime"
  test_reviewer="$TMP_ROOT/failure-cap-reviewer"
  bin_dir="$TMP_ROOT/failure-cap-bin"
  attempts_file="$TMP_ROOT/failure-cap-ci-attempts"
  mkdir -p "$state_dir" "$runtime_dir" "$bin_dir"
  cp -R "$REVIEWER_DIR" "$test_reviewer"

  cat > "$test_reviewer/get-installation-token.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  token) printf 'test-token\n' ;;
  slug)  printf 'goobreview\n' ;;
  *)     exit 1 ;;
esac
EOF
  chmod +x "$test_reviewer/get-installation-token.sh"

  cat > "$test_reviewer/check-ci.sh" <<EOF
#!/usr/bin/env bash
count=\$(cat "$attempts_file" 2>/dev/null || printf 0)
count=\$((count + 1))
printf '%s\n' "\$count" > "$attempts_file"
exit 1
EOF
  chmod +x "$test_reviewer/check-ci.sh"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
body_file=""
url="${*: -1}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      body_file="$2"
      shift 2
      ;;
    -D|-w)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
case "$url" in
  *'/repos/example/repo/pulls?state=open&per_page=100&page=1')
    printf '%s\n' '[{"number":1,"draft":false,"user":{"login":"alice"},"head":{"sha":"sha1"}},{"number":2,"draft":false,"user":{"login":"bob"},"head":{"sha":"sha2"}}]' > "$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/pulls/'*'/reviews?per_page=100&page=1')
    printf '%s\n' '[]' > "$body_file"
    printf '200'
    ;;
  *)
    printf 'unexpected curl URL: %s\n' "$url" >&2
    printf '000'
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/curl"

  cat > "$bin_dir/agy" <<'EOF'
#!/usr/bin/env bash
printf 'Looks good.\nAPPROVE\n'
EOF
  chmod +x "$bin_dir/agy"

  cat > "$bin_dir/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bin_dir/gh"

  key_file="$TMP_ROOT/failure-cap-key.pem"
  printf 'key\n' > "$key_file"
  chmod 600 "$key_file"

  printf '## Role\nReview.\n' > "$TMP_ROOT/failure-cap-personality.md"
  printf 'Final non-empty line: APPROVE, REQUEST_CHANGES, or COMMENT.\n' > "$TMP_ROOT/failure-cap-engine.md"
  printf '["ci"]\n' > "$TMP_ROOT/failure-cap-required.json"
  printf '1\n' > "$state_dir/review-failure-1-sha1.count"

  env_file="$TMP_ROOT/failure-cap.env"
  cat > "$env_file" <<EOF
REVIEWER_REPO=example/repo
REVIEWER_STATE=$state_dir
REVIEWER_RUNTIME_STATE=$runtime_dir
REVIEWER_APP_ID=1
REVIEWER_APP_INSTALLATION_ID=2
REVIEWER_APP_PRIVATE_KEY_PATH=$key_file
REVIEWER_PERSONALITY_FILE=$TMP_ROOT/failure-cap-personality.md
REVIEWER_PROMPT=$TMP_ROOT/failure-cap-engine.md
REVIEWER_REQUIRED_CHECKS_FILE=$TMP_ROOT/failure-cap-required.json
REVIEWER_MAX_PRS=1
REVIEWER_MAX_ATTEMPTS=1
REVIEWER_FAILURE_MAX_ATTEMPTS=1
EOF

  status=0
  # shellcheck disable=SC1090 # Fixture env file is created dynamically above.
  output=$(set -a; . "$env_file"; set +a; PATH="$bin_dir:$PATH" bash "$test_reviewer/reviewer.sh" 2>&1) || status=$?

  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    fail "failure cap fixture reviewer exits successfully"
  fi
  pass "failure cap fixture reviewer exits successfully"
  assert_eq "failure cap skips poisoned first PR and attempts second" "1" "$(cat "$attempts_file")"
  assert_contains "failure cap skip is logged" "PR #1@sha1: review failures reached REVIEWER_FAILURE_MAX_ATTEMPTS=1; skipping until the PR head changes" "$state_dir/log.txt"
  assert_contains "second PR failure is recorded" "PR #2@sha2: failed to read CI check-runs; reached failure cap (1/1), skipping until the PR head changes" "$state_dir/log.txt"
}

# Regression for the queue livelock: a PR capped on invalid model output must
# be skipped before the tick's attempt budget is spent and before any GitHub
# side effects, or with REVIEWER_MAX_ATTEMPTS=1 it consumes every tick forever
# and starves every PR sorted behind it.
test_reviewer_invalid_output_cap_skips_before_attempt_budget() {
  local state_dir runtime_dir test_reviewer env_file key_file bin_dir attempts_file signals_file status output

  state_dir="$TMP_ROOT/invalid-cap-state"
  runtime_dir="$TMP_ROOT/invalid-cap-runtime"
  test_reviewer="$TMP_ROOT/invalid-cap-reviewer"
  bin_dir="$TMP_ROOT/invalid-cap-bin"
  attempts_file="$TMP_ROOT/invalid-cap-ci-attempts"
  signals_file="$TMP_ROOT/invalid-cap-signals"
  mkdir -p "$state_dir" "$runtime_dir" "$bin_dir"
  cp -R "$REVIEWER_DIR" "$test_reviewer"
  : > "$signals_file"

  cat > "$test_reviewer/get-installation-token.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  token) printf 'test-token\n' ;;
  slug)  printf 'goobreview\n' ;;
  *)     exit 1 ;;
esac
EOF
  chmod +x "$test_reviewer/get-installation-token.sh"

  cat > "$test_reviewer/check-ci.sh" <<EOF
#!/usr/bin/env bash
count=\$(cat "$attempts_file" 2>/dev/null || printf 0)
count=\$((count + 1))
printf '%s\n' "\$count" > "$attempts_file"
exit 1
EOF
  chmod +x "$test_reviewer/check-ci.sh"

  cat > "$bin_dir/curl" <<EOF
#!/usr/bin/env bash
body_file=""
url="\${*: -1}"
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o)
      body_file="\$2"
      shift 2
      ;;
    -D|-w|-H|--data)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
case "\$url" in
  *'/repos/example/repo/pulls?state=open&per_page=100&page=1')
    printf '%s\n' '[{"number":1,"draft":false,"user":{"login":"alice"},"head":{"sha":"sha1"}},{"number":2,"draft":false,"user":{"login":"bob"},"head":{"sha":"sha2"}}]' > "\$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/pulls/'*'/reviews?per_page=100&page=1')
    printf '%s\n' '[]' > "\$body_file"
    printf '200'
    ;;
  *'/reactions'|*'/check-runs'*)
    printf '%s\n' "\$url" >> "$signals_file"
    printf '%s\n' '{"id":1}' > "\$body_file"
    printf '201'
    ;;
  *)
    printf 'unexpected curl URL: %s\n' "\$url" >&2
    printf '000'
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/curl"

  cat > "$bin_dir/agy" <<'EOF'
#!/usr/bin/env bash
printf 'Looks good.\nAPPROVE\n'
EOF
  chmod +x "$bin_dir/agy"

  key_file="$TMP_ROOT/invalid-cap-key.pem"
  printf 'key\n' > "$key_file"
  chmod 600 "$key_file"

  printf '## Role\nReview.\n' > "$TMP_ROOT/invalid-cap-personality.md"
  printf 'Final non-empty line: APPROVE, REQUEST_CHANGES, or COMMENT.\n' > "$TMP_ROOT/invalid-cap-engine.md"
  printf '["ci"]\n' > "$TMP_ROOT/invalid-cap-required.json"
  printf '1\n' > "$state_dir/invalid-verdict-1-sha1.count"

  env_file="$TMP_ROOT/invalid-cap.env"
  cat > "$env_file" <<EOF
REVIEWER_REPO=example/repo
REVIEWER_STATE=$state_dir
REVIEWER_RUNTIME_STATE=$runtime_dir
REVIEWER_APP_ID=1
REVIEWER_APP_INSTALLATION_ID=2
REVIEWER_APP_PRIVATE_KEY_PATH=$key_file
REVIEWER_PERSONALITY_FILE=$TMP_ROOT/invalid-cap-personality.md
REVIEWER_PROMPT=$TMP_ROOT/invalid-cap-engine.md
REVIEWER_REQUIRED_CHECKS_FILE=$TMP_ROOT/invalid-cap-required.json
REVIEWER_MAX_PRS=1
REVIEWER_MAX_ATTEMPTS=1
REVIEWER_INVALID_VERDICT_MAX_ATTEMPTS=1
EOF

  status=0
  # shellcheck disable=SC1090 # Fixture env file is created dynamically above.
  output=$(set -a; . "$env_file"; set +a; PATH="$bin_dir:$PATH" bash "$test_reviewer/reviewer.sh" 2>&1) || status=$?

  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    fail "invalid-output cap fixture reviewer exits successfully"
  fi
  pass "invalid-output cap fixture reviewer exits successfully"
  assert_contains "invalid-output cap skip is logged" "PR #1@sha1: invalid agy output reached REVIEWER_INVALID_VERDICT_MAX_ATTEMPTS=1; skipping until the PR head changes" "$state_dir/log.txt"
  assert_eq "invalid-output-capped PR does not consume the attempt budget" "1" "$(cat "$attempts_file")"
  assert_not_contains "invalid-output-capped skip emits no GitHub signals" "repos" "$signals_file"
}

test_reviewer_agy_quota_failure_reacts_and_skips_failure_cap() {
  local state_dir runtime_dir test_reviewer env_file key_file bin_dir status output
  local source_dir tarball reactions_file check_runs_file failure_count_file

  state_dir="$TMP_ROOT/quota-state"
  runtime_dir="$TMP_ROOT/quota-runtime"
  test_reviewer="$TMP_ROOT/quota-reviewer"
  bin_dir="$TMP_ROOT/quota-bin"
  source_dir="$TMP_ROOT/quota-source"
  tarball="$TMP_ROOT/quota.tar.gz"
  reactions_file="$TMP_ROOT/quota-reactions"
  check_runs_file="$TMP_ROOT/quota-check-runs"
  failure_count_file="$state_dir/review-failure-1-sha1.count"
  mkdir -p "$state_dir" "$runtime_dir" "$bin_dir" "$source_dir/repo-root"
  cp -R "$REVIEWER_DIR" "$test_reviewer"
  printf 'hello\n' > "$source_dir/repo-root/README.md"
  tar -czf "$tarball" -C "$source_dir" repo-root

  cat > "$test_reviewer/get-installation-token.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  token) printf 'test-token\n' ;;
  slug)  printf 'goobreview\n' ;;
  *)     exit 1 ;;
esac
EOF
  chmod +x "$test_reviewer/get-installation-token.sh"

  cat > "$test_reviewer/check-ci.sh" <<'EOF'
#!/usr/bin/env bash
printf 'success\n'
EOF
  chmod +x "$test_reviewer/check-ci.sh"

  cat > "$bin_dir/curl" <<EOF
#!/usr/bin/env bash
body_file=""
data_file=""
method="GET"
url="\${*: -1}"
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o)
      body_file="\$2"
      shift 2
      ;;
    -d|--data|--data-binary)
      data_file="\$2"
      shift 2
      ;;
    -X)
      method="\$2"
      shift 2
      ;;
    -D|-w|-H)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
case "\$url" in
  *'/repos/example/repo/pulls?state=open&per_page=100&page=1')
    printf '%s\n' '[{"number":1,"draft":false,"user":{"login":"alice"},"head":{"sha":"sha1","ref":"feature"},"base":{"ref":"main"},"title":"Quota PR","body":"Please review","changed_files":1}]' > "\$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/pulls/1/reviews?per_page=100&page=1')
    printf '%s\n' '[]' > "\$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/pulls/1/files?per_page=100&page=1')
    printf '%s\n' '[{"filename":"README.md","status":"modified","additions":1,"deletions":0,"patch":"@@ -1,0 +1,1 @@\n+hello"}]' > "\$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/pulls/1/commits?per_page=100&page=1')
    printf '%s\n' '[{"commit":{"message":"Update README"}}]' > "\$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/commits/sha1')
    printf '%s\n' '{"commit":{"committer":{"date":"2026-07-04T23:00:00Z"}}}' > "\$body_file"
    printf '200'
    ;;
  *'/graphql')
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' > "\$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/tarball/sha1')
    cat "$tarball" > "\$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/issues/1/reactions')
    printf '%s\n' "\$data_file" >> "$reactions_file"
    printf '%s\n' '{"id":1,"content":"confused"}' > "\$body_file"
    printf '201'
    ;;
  *'/repos/example/repo/check-runs')
    printf '%s\n' "\$data_file" >> "$check_runs_file"
    printf '%s\n' '{"id":88}' > "\$body_file"
    printf '201'
    ;;
  *'/repos/example/repo/check-runs/88')
    printf '%s\n' "\$data_file" >> "$check_runs_file"
    printf '%s\n' '{"id":88}' > "\$body_file"
    printf '200'
    ;;
  *)
    printf 'unexpected curl URL: %s\n' "\$url" >&2
    printf '000'
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/curl"

  cat > "$bin_dir/timeout" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --kill-after=*) shift ;;
esac
shift
"$@"
EOF
  chmod +x "$bin_dir/timeout"

  cat > "$bin_dir/agy" <<'EOF'
#!/usr/bin/env bash
printf 'upstream error: 429 rate limit exceeded, retry later\n' >&2
exit 1
EOF
  chmod +x "$bin_dir/agy"

  key_file="$TMP_ROOT/quota-key.pem"
  printf 'key\n' > "$key_file"
  chmod 600 "$key_file"

  printf '## Role\nReview.\n' > "$TMP_ROOT/quota-personality.md"
  printf 'Final non-empty line: APPROVE, REQUEST_CHANGES, or COMMENT.\n' > "$TMP_ROOT/quota-engine.md"
  printf '[]\n' > "$TMP_ROOT/quota-required.json"

  env_file="$TMP_ROOT/quota.env"
  cat > "$env_file" <<EOF
REVIEWER_REPO=example/repo
REVIEWER_STATE=$state_dir
REVIEWER_RUNTIME_STATE=$runtime_dir
REVIEWER_APP_ID=1
REVIEWER_APP_INSTALLATION_ID=2
REVIEWER_APP_PRIVATE_KEY_PATH=$key_file
REVIEWER_PERSONALITY_FILE=$TMP_ROOT/quota-personality.md
REVIEWER_PROMPT=$TMP_ROOT/quota-engine.md
REVIEWER_REQUIRED_CHECKS_FILE=$TMP_ROOT/quota-required.json
REVIEWER_MAX_PRS=1
REVIEWER_MAX_ATTEMPTS=1
REVIEWER_FAILURE_MAX_ATTEMPTS=1
REVIEWER_IGNORE_AGY_BACKOFF=1
EOF

  # Two ticks in a row, both hitting the quota-exhausted agy stub. With
  # REVIEWER_FAILURE_MAX_ATTEMPTS=1, a non-quota failure would trip the
  # failure cap and permanently skip this PR after the first tick; quota
  # failures must not consume that budget, so the PR stays eligible.
  : > "$reactions_file"
  : > "$check_runs_file"
  status=0
  # shellcheck disable=SC1090 # Fixture env file is created dynamically above.
  output=$(set -a; . "$env_file"; set +a; PATH="$bin_dir:$PATH" bash "$test_reviewer/reviewer.sh" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    fail "quota fixture first tick exits successfully"
  fi
  pass "quota fixture first tick exits successfully"
  assert_contains "first quota failure posts confused reaction" '"content":"confused"' "$reactions_file"
  assert_contains "quota tick opens an in-progress review check run" '"status": "in_progress"' "$check_runs_file"
  assert_contains "quota failure concludes the review check run neutral" '"conclusion": "neutral"' "$check_runs_file"
  assert_contains "first quota failure is exempted from the failure cap" "PR #1@sha1: agy quota exhausted; not counted toward the failure cap, will retry once backoff clears" "$state_dir/log.txt"
  assert_eq "no failure-attempt file recorded after first quota failure" "0" "$( [ -f "$failure_count_file" ] && cat "$failure_count_file" || printf 0)"

  : > "$reactions_file"
  status=0
  # shellcheck disable=SC1090 # Fixture env file is created dynamically above.
  output=$(set -a; . "$env_file"; set +a; PATH="$bin_dir:$PATH" bash "$test_reviewer/reviewer.sh" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    fail "quota fixture second tick exits successfully"
  fi
  pass "quota fixture second tick exits successfully"
  assert_contains "second quota failure posts confused reaction again" '"content":"confused"' "$reactions_file"
  assert_not_contains "repeated quota failures never trip the failure cap" "review failures reached REVIEWER_FAILURE_MAX_ATTEMPTS" "$state_dir/log.txt"
  assert_eq "no failure-attempt file recorded after second quota failure" "0" "$( [ -f "$failure_count_file" ] && cat "$failure_count_file" || printf 0)"
}

test_reviewer_research_capture_posts_selected_review_only() {
  local state_dir runtime_dir test_reviewer env_file key_file bin_dir config_dir status output
  local source_dir tarball review_payload reactions_file check_runs_file posted_body manifest research_dir dry_run_out dry_comments_json
  local manifest_latency dry_run_latency head_committed_at_fixture expected_review_worktree

  head_committed_at_fixture="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
  state_dir="$TMP_ROOT/research-state"
  runtime_dir="$TMP_ROOT/research-runtime"
  test_reviewer="$TMP_ROOT/research-reviewer"
  bin_dir="$TMP_ROOT/research-bin"
  config_dir="$TMP_ROOT/research-config"
  source_dir="$TMP_ROOT/research-source"
  tarball="$TMP_ROOT/research.tar.gz"
  review_payload="$TMP_ROOT/research-review-payload.json"
  reactions_file="$TMP_ROOT/research-reactions"
  check_runs_file="$TMP_ROOT/research-check-runs"
  mkdir -p "$state_dir" "$runtime_dir" "$bin_dir" "$config_dir/personalities" "$source_dir/repo-root"
  cp -R "$REVIEWER_DIR" "$test_reviewer"
  cp "$REVIEWER_DIR/../../config/personalities/control.md" "$config_dir/personalities/control.md"
  cp "$REVIEWER_DIR/../../config/personalities/linus.md" "$config_dir/personalities/linus.md"
  cp "$REVIEWER_DIR/../../config/personalities/angry.md" "$config_dir/personalities/angry.md"
  printf 'hello\n' > "$source_dir/repo-root/README.md"
  tar -czf "$tarball" -C "$source_dir" repo-root

  cat > "$test_reviewer/get-installation-token.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  token) printf 'test-token\n' ;;
  slug)  printf 'goobreview\n' ;;
  *)     exit 1 ;;
esac
EOF
  chmod +x "$test_reviewer/get-installation-token.sh"

  cat > "$test_reviewer/check-ci.sh" <<'EOF'
#!/usr/bin/env bash
printf 'success\n'
EOF
  chmod +x "$test_reviewer/check-ci.sh"

  cat > "$bin_dir/curl" <<EOF
#!/usr/bin/env bash
body_file=""
data_file=""
method="GET"
url="\${*: -1}"
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o)
      body_file="\$2"
      shift 2
      ;;
    -d|--data|--data-binary)
      data_file="\$2"
      shift 2
      ;;
    -X)
      method="\$2"
      shift 2
      ;;
    -D|-w|-H)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
case "\$url" in
  *'/repos/example/repo')
    printf '%s\n' "{\"private\":\${FIXTURE_REPO_PRIVATE:-false}}" > "\$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/pulls?state=open&per_page=100&page=1')
    printf '%s\n' '[{"number":1,"draft":false,"user":{"login":"alice"},"head":{"sha":"sha1","ref":"feature"},"base":{"ref":"main"},"title":"Research PR","body":"Please review","changed_files":1}]' > "\$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/pulls/1')
    printf '%s\n' '{"number":1,"head":{"sha":"sha1"}}' > "\$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/pulls/1/reviews?per_page=100&page=1')
    printf '%s\n' '[]' > "\$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/pulls/1/files?per_page=100&page=1')
    printf '%s\n' '[{"filename":"README.md","status":"modified","additions":1,"deletions":0,"patch":"@@ -1,0 +1,1 @@\n+hello"}]' > "\$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/pulls/1/commits?per_page=100&page=1')
    printf '%s\n' '[{"commit":{"message":"Update README"}}]' > "\$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/commits/sha1')
    printf '%s\n' '{"commit":{"committer":{"date":"$head_committed_at_fixture"}}}' > "\$body_file"
    printf '200'
    ;;
  *'/graphql')
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' > "\$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/tarball/sha1')
    cat "$tarball" > "\$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/issues/1/reactions')
    printf '%s\n' "\$data_file" >> "$reactions_file"
    printf '%s\n' '{"id":1,"content":"eyes"}' > "\$body_file"
    printf '201'
    ;;
  *'/repos/example/repo/check-runs')
    printf '%s\n' "\$data_file" >> "$check_runs_file"
    printf '%s\n' '{"id":99}' > "\$body_file"
    printf '201'
    ;;
  *'/repos/example/repo/check-runs/99')
    printf '%s\n' "\$data_file" >> "$check_runs_file"
    printf '%s\n' '{"id":99}' > "\$body_file"
    printf '200'
    ;;
  *'/repos/example/repo/pulls/1/reviews')
    if [ -n "\$data_file" ]; then
      printf '%s\n' "\$data_file" > "$review_payload"
    fi
    printf '%s\n' '{"id":123}' > "\$body_file"
    printf '200'
    ;;
  *)
    printf 'unexpected curl URL: %s\n' "\$url" >&2
    printf '000'
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/curl"

  cat > "$bin_dir/timeout" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --kill-after=*) shift ;;
esac
shift
"$@"
EOF
  chmod +x "$bin_dir/timeout"

  cat > "$bin_dir/agy" <<'EOF'
#!/usr/bin/env bash
printf 'fake agy stderr trace\n' >&2
agents_md_content="$(cat AGENTS.md 2>/dev/null || true)"
if [ -n "${REVIEWER_DRY_RUN:-}" ]; then
  printf '### README location\nLocation: README.md:1\nThis needs review.\nAPPROVE\n'
  exit 0
fi
case "$agents_md_content" in
  *"Mauro, SHUT"*) printf 'linus review\nCOMMENT\n' ;;
  *"very angry senior engineer"*) printf 'angry review\nCOMMENT\n' ;;
  *)
    printf 'control review\nAPPROVE\n'
    ;;
esac
EOF
  chmod +x "$bin_dir/agy"

  key_file="$TMP_ROOT/research-key.pem"
  printf 'key\n' > "$key_file"
  chmod 600 "$key_file"
  printf '[]\n' > "$TMP_ROOT/research-required.json"

  env_file="$TMP_ROOT/research.env"
  cat > "$env_file" <<EOF
REVIEWER_REPO=example/repo
REVIEWER_STATE=$state_dir
REVIEWER_RUNTIME_STATE=$runtime_dir
REVIEWER_CONFIG_DIR=$config_dir
REVIEWER_APP_ID=1
REVIEWER_APP_INSTALLATION_ID=2
REVIEWER_APP_PRIVATE_KEY_PATH=$key_file
REVIEWER_POSTED_PERSONALITY=angry
REVIEWER_RESEARCH_CONSENT=1
REVIEWER_REQUIRED_CHECKS_FILE=$TMP_ROOT/research-required.json
REVIEWER_MAX_PRS=1
REVIEWER_MAX_ATTEMPTS=1
EOF

  : > "$reactions_file"
  : > "$check_runs_file"
  status=0
  # shellcheck disable=SC1090 # Fixture env file is created dynamically above.
  output=$(set -a; . "$env_file"; set +a; PATH="$bin_dir:$PATH" bash "$test_reviewer/reviewer.sh" 2>&1) || status=$?

  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    fail "research capture fixture reviewer exits successfully"
  fi
  pass "research capture fixture reviewer exits successfully"

  assert_contains "live tick posts review-started eyes reaction" '"content":"eyes"' "$reactions_file"
  assert_contains "live tick opens an in-progress review check run" '"status": "in_progress"' "$check_runs_file"
  assert_contains "posted COMMENT review concludes the check run neutral" '"conclusion": "neutral"' "$check_runs_file"

  posted_body=$(jq -r '.body' "$review_payload")
  assert_contains "posted review uses selected angry arm" "angry review" <(printf '%s\n' "$posted_body")
  assert_not_contains "posted review does not include counterfactual control arm" "control review" <(printf '%s\n' "$posted_body")

  manifest=$(find "$state_dir/research-runs" -name manifest.json | head -n 1)
  if [ -z "$manifest" ]; then
    fail "research manifest is written"
  fi
  pass "research manifest is written"
  assert_eq "manifest records selected posted personality" "angry" "$(jq -r '.posted_personality' "$manifest")"
  assert_eq "manifest records posted arm" "angry" "$(jq -r '.posted_arm' "$manifest")"
  assert_eq "manifest records counterfactual arm" "none" "$(jq -r '.counterfactual_arm' "$manifest")"
  assert_eq "manifest records posted arm event" "COMMENT" "$(jq -r '.posted_event' "$manifest")"
  assert_eq "manifest records counterfactual event" "APPROVE" "$(jq -r '.counterfactual_event' "$manifest")"
  assert_eq "manifest records posted transcript source" "stdout_fallback" "$(jq -r '.posted_transcript_source' "$manifest")"
  assert_eq "manifest records counterfactual transcript source" "stdout_fallback" "$(jq -r '.counterfactual_transcript_source' "$manifest")"
  assert_eq "manifest records public eligibility" "public-consented" "$(jq -r '.research_eligible' "$manifest")"
  assert_eq "manifest records head pushed-at timestamp" "$head_committed_at_fixture" "$(jq -r '.head_pushed_at' "$manifest")"
  manifest_latency=$(jq -r '.review_latency_seconds' "$manifest")
  if [ "$manifest_latency" -ge 0 ] 2>/dev/null && [ "$manifest_latency" -lt 86400 ] 2>/dev/null; then
    pass "manifest records a sane non-negative review latency"
  else
    printf 'unexpected review_latency_seconds: %s\n' "$manifest_latency" >&2
    fail "manifest records a sane non-negative review latency"
  fi

  research_dir="$(dirname "$manifest")"
  assert_contains "posted artifact preserves angry response" "angry review" "$research_dir/angry/artifact.txt"
  assert_contains "counterfactual artifact preserves control response" "control review" "$research_dir/none/artifact.txt"
  assert_contains "posted artifact includes agents.md section" "===== AGY AGENTS.MD START =====" "$research_dir/angry/artifact.txt"
  assert_contains "counterfactual artifact includes agents.md section" "===== AGY AGENTS.MD START =====" "$research_dir/none/artifact.txt"
  assert_contains "posted artifact agents.md reflects angry personality" "You are a very angry senior engineer." "$research_dir/angry/artifact.txt"
  assert_contains "counterfactual artifact agents.md reflects control personality" "## Role" "$research_dir/none/artifact.txt"

  # Regression (mog-template #179): write_research_review_artifact re-renders
  # AGENTS.md for the archive but was omitting the snapshot worktree dir arg
  # to write_agents_md, so every archived AGENTS.md had a blank "mounted
  # read-only at:" line and a sha256 that didn't match what the model
  # actually received. review_worktree here is example/repo@sha1's cached
  # snapshot dir; assert both archived arms captured its real, non-blank path.
  expected_review_worktree="$runtime_dir/worktrees/example_repo/heads/sha1"
  assert_contains "posted artifact agents.md captures the snapshot mount path" \
    "mounted read-only at: $expected_review_worktree" "$research_dir/angry/artifact.txt"
  assert_contains "counterfactual artifact agents.md captures the snapshot mount path" \
    "mounted read-only at: $expected_review_worktree" "$research_dir/none/artifact.txt"

  dry_run_out="$TMP_ROOT/research-dry-run.txt"
  : > "$reactions_file"
  : > "$check_runs_file"
  status=0
  # shellcheck disable=SC1090 # Fixture env file is created dynamically above.
  output=$(set -a; . "$env_file"; set +a; REVIEWER_DRY_RUN=1 REVIEWER_DRY_RUN_OUT="$dry_run_out" PATH="$bin_dir:$PATH" bash "$test_reviewer/reviewer.sh" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    fail "dry-run inline-comment fixture reviewer exits successfully"
  fi
  pass "dry-run inline-comment fixture reviewer exits successfully"
  assert_not_contains "dry-run posts no review-started reaction" "content" "$reactions_file"
  assert_not_contains "dry-run opens no review check run" "status" "$check_runs_file"
  assert_contains "dry-run artifact records agy execution context" "===== AGY EXECUTION CONTEXT START =====" "$dry_run_out"
  assert_contains "dry-run artifact explains hidden agy layer" "Hidden Antigravity CLI system prompt/tool definitions: not observable by GoobReview" "$dry_run_out"
  assert_contains "dry-run artifact records agy command template" "agy --sandbox --dangerously-skip-permissions" "$dry_run_out"
  assert_contains "dry-run artifact records the actual agy invocation" "Invocation (recorded):" "$dry_run_out"
  assert_contains "dry-run recorded invocation keeps the --add-dir attachments" "--add-dir" "$dry_run_out"
  assert_contains "dry-run recorded invocation elides the prompt to a byte count" "bytes>" "$dry_run_out"
  assert_contains "dry-run artifact records runtime cwd" "Runtime cwd: $runtime_dir/agy-runtime" "$dry_run_out"
  assert_contains "dry-run artifact records snapshot path" "PR-head snapshot path:" "$dry_run_out"
  assert_contains "dry-run artifact records prompt hash" "Prompt SHA256:" "$dry_run_out"
  assert_contains "dry-run artifact records response hash" "Response SHA256:" "$dry_run_out"
  assert_contains "dry-run artifact records agents.md hash in execution context" "AGENTS.MD SHA256:" "$dry_run_out"
  assert_contains "dry-run artifact records head pushed-at" "Head pushed at: $head_committed_at_fixture" "$dry_run_out"
  assert_not_contains "dry-run artifact does not mark review latency unavailable" "Review latency seconds: unavailable" "$dry_run_out"
  assert_contains "dry-run artifact includes agents.md section" "===== AGY AGENTS.MD START =====" "$dry_run_out"
  assert_eq "dry-run launch json records head pushed-at timestamp" "$head_committed_at_fixture" "$(jq -r '.head_pushed_at' "$dry_run_out.launch.json")"
  assert_eq "dry-run launch json records transcript source" "stdout_fallback" "$(jq -r '.transcript_source' "$dry_run_out.launch.json")"
  dry_run_latency=$(jq -r '.review_latency_seconds' "$dry_run_out.launch.json")
  if [ "$dry_run_latency" -ge 0 ] 2>/dev/null && [ "$dry_run_latency" -lt 86400 ] 2>/dev/null; then
    pass "dry-run launch json records a sane non-negative review latency"
  else
    printf 'unexpected review_latency_seconds: %s\n' "$dry_run_latency" >&2
    fail "dry-run launch json records a sane non-negative review latency"
  fi
  assert_contains "dry-run artifact agents.md has personality content" "You are a very angry senior engineer." "$dry_run_out"
  assert_contains "dry-run artifact agents.md has format contract" "Use REQUEST_CHANGES only for concrete issues that should block merge." "$dry_run_out"
  assert_contains "dry-run artifact captures agy stderr" "fake agy stderr trace" "$dry_run_out"
  assert_contains "dry-run artifact reports resolved inline comments" "Resolved inline comments: 1" "$dry_run_out"
  awk '
    /^===== RESOLVED INLINE COMMENTS START =====$/ { found = 1; next }
    /^===== RESOLVED INLINE COMMENTS END =====$/ { exit }
    found { print }
  ' "$dry_run_out" > "$TMP_ROOT/research-dry-comments.json"
  dry_comments_json="$TMP_ROOT/research-dry-comments.json"
  assert_eq "dry-run artifact includes resolved inline comment path" "README.md" "$(jq -r '.[0].path' "$dry_comments_json")"
  assert_eq "dry-run artifact includes resolved inline comment line" "1" "$(jq -r '.[0].line' "$dry_comments_json")"

  awk '
    found && /^===== AGY PROMPT PAYLOAD END =====$/ { exit }
    found { print; next }
    /^===== AGY PROMPT PAYLOAD START =====$/ { found = 1 }
  ' "$research_dir/none/artifact.txt" > "$TMP_ROOT/research-none-tail.txt"
  awk '
    found && /^===== AGY PROMPT PAYLOAD END =====$/ { exit }
    found { print; next }
    /^===== AGY PROMPT PAYLOAD START =====$/ { found = 1 }
  ' "$research_dir/angry/artifact.txt" > "$TMP_ROOT/research-angry-tail.txt"
  assert_not_contains "control research prompt omits angry assistant cutoff" "Assistant: *closes their eyes for half a second longer than politeness requires* Right. Fine. The " "$TMP_ROOT/research-none-tail.txt"
  assert_contains "angry research prompt includes assistant cutoff" "Assistant: *closes their eyes for half a second longer than politeness requires* Right. Fine. The " "$TMP_ROOT/research-angry-tail.txt"
  assert_eq "angry research prompt starts transcript-shaped user turn" "User:" "$(head -n 1 "$TMP_ROOT/research-angry-tail.txt")"

  # Private repos are excluded from capture unless explicitly opted in, and the
  # manifest then records the private eligibility honestly.
  local priv_state_off priv_state_on priv_manifest
  priv_state_off="$TMP_ROOT/research-state-private-off"
  priv_state_on="$TMP_ROOT/research-state-private-on"
  mkdir -p "$priv_state_off" "$priv_state_on"

  status=0
  # shellcheck disable=SC1090 # Fixture env file is created dynamically above.
  output=$(set -a; . "$env_file"; set +a; REVIEWER_STATE="$priv_state_off" FIXTURE_REPO_PRIVATE=true PATH="$bin_dir:$PATH" bash "$test_reviewer/reviewer.sh" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    fail "private-repo capture fixture without opt-in exits successfully"
  fi
  pass "private-repo capture fixture without opt-in exits successfully"
  if [ -d "$priv_state_off/research-runs" ]; then
    fail "private repo without opt-in writes no paired research artifacts"
  fi
  pass "private repo without opt-in writes no paired research artifacts"

  status=0
  # shellcheck disable=SC1090 # Fixture env file is created dynamically above.
  output=$(set -a; . "$env_file"; set +a; REVIEWER_STATE="$priv_state_on" REVIEWER_RESEARCH_ALLOW_PRIVATE=1 FIXTURE_REPO_PRIVATE=true PATH="$bin_dir:$PATH" bash "$test_reviewer/reviewer.sh" 2>&1) || status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    fail "private-repo capture fixture with opt-in exits successfully"
  fi
  pass "private-repo capture fixture with opt-in exits successfully"
  priv_manifest=$(find "$priv_state_on/research-runs" -name manifest.json | head -n 1)
  if [ -z "$priv_manifest" ]; then
    fail "private repo with opt-in writes research manifest"
  fi
  pass "private repo with opt-in writes research manifest"
  assert_eq "manifest records private visibility" "private" "$(jq -r '.repo_visibility' "$priv_manifest")"
  assert_eq "manifest records private eligibility" "private-consented" "$(jq -r '.research_eligible' "$priv_manifest")"
}
