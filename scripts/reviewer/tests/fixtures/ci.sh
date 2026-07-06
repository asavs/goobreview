#!/usr/bin/env bash
# CI gate fixtures for the reviewer suite. Sourced by run-fixtures.sh, which
# provides the assert helpers, TMP_ROOT, and the sourced reviewer libs; the
# runner's registration list controls execution order.
# shellcheck disable=SC2034,SC2154,SC2317,SC2329

test_ci_states() {
  local success_runs pending_runs failing_runs missing_runs duplicate_runs

  success_runs='{"check_runs":[
    {"name":"test","status":"completed","conclusion":"success","started_at":"2026-05-21T00:00:00Z"},
    {"name":"lint","status":"completed","conclusion":"success","started_at":"2026-05-21T00:00:01Z"},
    {"name":"build","status":"completed","conclusion":"failure","started_at":"2026-05-21T00:00:02Z"}
  ]}'
  assert_eq "required checks success ignores unrelated failures" "success" "$(printf '%s' "$success_runs" | reviewer_ci_state_from_json '["test","lint"]')"

  pending_runs='{"check_runs":[
    {"name":"test","status":"in_progress","conclusion":null,"started_at":"2026-05-21T00:00:00Z"},
    {"name":"lint","status":"completed","conclusion":"success","started_at":"2026-05-21T00:00:01Z"}
  ]}'
  assert_eq "pending required check waits" "pending" "$(printf '%s' "$pending_runs" | reviewer_ci_state_from_json '["test","lint"]')"

  failing_runs='{"check_runs":[
    {"name":"test","status":"completed","conclusion":"failure","started_at":"2026-05-21T00:00:00Z"},
    {"name":"lint","status":"completed","conclusion":"success","started_at":"2026-05-21T00:00:01Z"}
  ]}'
  assert_eq "failing required check blocks" "failing" "$(printf '%s' "$failing_runs" | reviewer_ci_state_from_json '["test","lint"]')"

  missing_runs='{"check_runs":[
    {"name":"test","status":"completed","conclusion":"success","started_at":"2026-05-21T00:00:00Z"}
  ]}'
  assert_eq "missing required check is incomplete" "incomplete" "$(printf '%s' "$missing_runs" | reviewer_ci_state_from_json '["test","lint"]')"

  duplicate_runs='{"check_runs":[
    {"name":"test","status":"completed","conclusion":"failure","started_at":"2026-05-21T00:00:00Z"},
    {"name":"test","status":"completed","conclusion":"success","started_at":"2026-05-21T00:01:00Z"},
    {"name":"lint","status":"completed","conclusion":"success","started_at":"2026-05-21T00:00:01Z"}
  ]}'
  assert_eq "duplicate check names use latest run" "success" "$(printf '%s' "$duplicate_runs" | reviewer_ci_state_from_json '["test","lint"]')"

  reviewer_validate_required_checks_json '["test","lint"]'
  pass "required check config accepts nonempty string array"
  if reviewer_validate_required_checks_json '["test",""]' >/dev/null 2>&1; then
    fail "required check config rejects empty names"
  fi
  pass "required check config rejects empty names"

  required_file="$TMP_ROOT/required-checks.json"
  printf '["test"]\n' > "$required_file"
  REQUIRED_CHECKS_FILE="$required_file"
  ALLOW_REQUIRED_CHECKS_OVERRIDE=0
  unset REVIEWER_REQUIRED_CHECKS_JSON
  assert_eq "required check config loads canonical file JSON" '["test"]' "$(load_effective_required_checks_json)"

  REVIEWER_REQUIRED_CHECKS_JSON='["override"]'
  assert_eq "required check env override is ignored by default" '["test"]' "$(load_effective_required_checks_json)"

  ALLOW_REQUIRED_CHECKS_OVERRIDE=1
  assert_eq "required check env override is explicit" '["override"]' "$(load_effective_required_checks_json)"

  printf '[""]\n' > "$required_file"
  unset REVIEWER_REQUIRED_CHECKS_JSON
  ALLOW_REQUIRED_CHECKS_OVERRIDE=0
  if ( REQUIRED_CHECKS_FILE="$required_file"; load_effective_required_checks_json ) >/dev/null 2>&1; then
    fail "required check file rejects empty names early"
  fi
  pass "required check file rejects empty names early"

  printf '["test"]\n' > "$required_file"
  REVIEWER_REQUIRED_CHECKS_JSON='{"bad":true}'
  ALLOW_REQUIRED_CHECKS_OVERRIDE=1
  if ( REQUIRED_CHECKS_FILE="$required_file"; load_effective_required_checks_json ) >/dev/null 2>&1; then
    fail "required check env override rejects non-array JSON"
  fi
  pass "required check env override rejects non-array JSON"
}



test_check_ci_paginates_required_check_runs() {
  local bin_dir count_file required_file output log_file status

  bin_dir="$TMP_ROOT/check-ci-page-bin"
  count_file="$TMP_ROOT/check-ci-page-count"
  required_file="$TMP_ROOT/check-ci-required.json"
  log_file="$TMP_ROOT/check-ci-page.log"
  mkdir -p "$bin_dir"
  printf '["late-check"]\n' > "$required_file"

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
count=$(cat "$CHECK_CI_PAGE_COUNT" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$CHECK_CI_PAGE_COUNT"
case "$url" in
  *'page=1')
    jq -n '{total_count: 101, check_runs: [range(0;100) | {name: ("unrelated-" + tostring), status: "completed", conclusion: "success", started_at: "2026-05-21T00:00:00Z"}]}' > "$body_file"
    printf '200'
    ;;
  *'page=2')
    jq -n '{total_count: 101, check_runs: [{name: "late-check", status: "completed", conclusion: "success", started_at: "2026-05-21T00:01:00Z"}]}' > "$body_file"
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

  output=$(GH_TOKEN='token' CHECK_CI_PAGE_COUNT="$count_file" PATH="$bin_dir:$PATH" bash "$REVIEWER_DIR/check-ci.sh" example/repo sha123 "$required_file" 2>"$log_file")
  assert_eq "check-ci finds required check beyond first page" "success" "$output"
  assert_eq "check-ci fetches second check-run page" "2" "$(cat "$count_file")"

  sed -i \
    -e "/jq -n '{total_count: 101, check_runs: \\[{name: \"late-check\"/,/    ;;/c\\
  *'page=2')\\
    printf 'GitHub unavailable on page 2\\n' >&2\\
    printf '503'\\
    exit 0\\
    ;;\\
" "$bin_dir/curl"
  printf '0\n' > "$count_file"
  status=0
  GH_TOKEN='token' CHECK_CI_PAGE_COUNT="$count_file" PATH="$bin_dir:$PATH" bash "$REVIEWER_DIR/check-ci.sh" example/repo sha123 "$required_file" > /dev/null 2>"$log_file" || status=$?
  if [ "$status" -eq 0 ]; then
    fail "check-ci fails when check-run pagination is incomplete"
  fi
  pass "check-ci fails when check-run pagination is incomplete"
  assert_contains "check-ci pagination failure is distinct from missing checks" "required-check data is incomplete" "$log_file"

  printf '0\n' > "$count_file"
  status=0
  CHECK_RUNS_JSON='{"total_count":101,"fetched_count":100,"pages_fetched":1,"complete":false,"check_runs":[]}' \
    bash "$REVIEWER_DIR/check-ci.sh" example/repo sha123 "$required_file" > /dev/null 2>"$log_file" || status=$?
  if [ "$status" -ne 0 ]; then
    fail "incomplete fixture JSON remains parseable as missing required checks"
  fi
  pass "incomplete fixture JSON remains parseable as missing required checks"
}

test_check_runs_summary_reports_only_needed_plumbing() {
  local output

  REPO="example/repo"
  # Invoked indirectly by github_check_runs_summary.
  # shellcheck disable=SC2317
  github_check_runs_json() {
    printf '%s\n' '{"total_count":2,"fetched_count":2,"pages_fetched":1,"complete":true,"check_runs":[{"name":"a","status":"completed","conclusion":"success"},{"name":"b","status":"completed","conclusion":"failure"}]}'
  }
  output=$(github_check_runs_summary sha123)
  assert_contains "check-run summary includes first result row" "$(printf 'a\tcompleted\tsuccess\t-')" <(printf '%s\n' "$output")
  assert_not_contains "check-run summary omits complete plumbing" "Check-run data: complete" <(printf '%s\n' "$output")
  assert_not_contains "check-run summary omits all-results plumbing" "Showing all 2 check runs." <(printf '%s\n' "$output")

  REVIEWER_CHECK_RUN_SUMMARY_LIMIT=1
  output=$(github_check_runs_summary sha123)
  assert_contains "check-run summary reports complete data when truncated" "Check-run data: complete (fetched 2 of 2 across 1 page(s))" <(printf '%s\n' "$output")
  assert_contains "check-run summary reports intentional truncation" "Showing first 1 of 2 check runs; summary intentionally truncated." <(printf '%s\n' "$output")

  # Invoked indirectly by github_check_runs_summary.
  # shellcheck disable=SC2317
  github_check_runs_json() {
    printf '%s\n' '{"total_count":3,"fetched_count":2,"pages_fetched":1,"complete":false,"check_runs":[{"name":"a","status":"completed","conclusion":"success"},{"name":"b","status":"completed","conclusion":"failure"}]}'
  }
  unset REVIEWER_CHECK_RUN_SUMMARY_LIMIT
  output=$(github_check_runs_summary sha123)
  assert_contains "check-run summary reports incomplete data" "Check-run data: incomplete (fetched 2 of 3 across 1 page(s))" <(printf '%s\n' "$output")
  assert_not_contains "check-run summary omits all-results plumbing for incomplete data" "Showing all 2 check runs." <(printf '%s\n' "$output")

  unset REVIEWER_CHECK_RUN_SUMMARY_LIMIT
  unset -f github_check_runs_json
}
