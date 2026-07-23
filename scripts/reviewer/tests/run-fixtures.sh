#!/usr/bin/env bash
# Fixture globals are intentionally consumed by sourced reviewer libraries.
# Mock functions (curl/timeout/github_api_*) shadow each other across tests and
# are only invoked indirectly by the code under test, so reachability lints
# (SC2317, and its SC2329 successor in newer ShellCheck) misfire file-wide.
# shellcheck disable=SC2034,SC2317,SC2329
set -euo pipefail

# Fail loud: a soft skip looked green on hosts without util-linux (e.g. Git
# Bash) and gave false confidence. Target is Ubuntu/WSL; see CONTRIBUTING.md
# and scripts/dev-env-check.sh.
if [ -n "${MSYSTEM:-}" ] || [ "${OSTYPE:-}" = "msys" ] || [ "${OSTYPE:-}" = "cygwin" ]; then
  printf 'FAIL: reviewer fixtures require GNU/Linux (Ubuntu or WSL), not MSYS/Cygwin/Git Bash.\n' >&2
  printf 'Run under WSL Ubuntu or a Linux host. Optional: bash scripts/dev-env-check.sh\n' >&2
  exit 1
fi
if ! command -v flock >/dev/null 2>&1; then
  printf 'FAIL: reviewer fixture suite needs flock (util-linux).\n' >&2
  printf 'Install util-linux (Ubuntu/WSL) or run on a Linux host. Optional: bash scripts/dev-env-check.sh\n' >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEWER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$REVIEWER_DIR/lib"

TMP_ROOT=$(mktemp -d)
# Snapshot fixtures leave chmod a-w trees (prepare_review_worktree enforces the
# read-only snapshot claim on disk), which a non-root rm -rf cannot unlink.
# Restore owner write before cleanup so the trap never fails the suite.
trap 'chmod -R u+w "$TMP_ROOT" 2>/dev/null; rm -rf "$TMP_ROOT"' EXIT

LOG_FILE="$TMP_ROOT/test.log"
: > "$LOG_FILE"

# shellcheck disable=SC1091
. "$LIB_DIR/ci.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/config.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/agy.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/github-api.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/github.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/output.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/prompt.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/worktree.sh"

pass_count=0

pass() {
  printf 'ok - %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local name="$1"
  local expected="$2"
  local actual="$3"

  if [ "$actual" != "$expected" ]; then
    printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
    fail "$name"
  fi
  pass "$name"
}

assert_contains() {
  local name="$1"
  local needle="$2"
  local file="$3"

  if ! grep -Fq -- "$needle" "$file"; then
    printf 'missing expected text: %s\n' "$needle" >&2
    printf '%s\n' "--- $file ---" >&2
    sed -n '1,220p' "$file" >&2
    fail "$name"
  fi
  pass "$name"
}

assert_not_contains() {
  local name="$1"
  local needle="$2"
  local file="$3"

  if grep -Fq -- "$needle" "$file"; then
    printf 'unexpected text: %s\n' "$needle" >&2
    printf '%s\n' "--- $file ---" >&2
    sed -n '1,220p' "$file" >&2
    fail "$name"
  fi
  pass "$name"
}

assert_order() {
  local name="$1"
  local file="$2"
  shift 2

  local marker line previous=0
  for marker in "$@"; do
    line=$(grep -nF -- "$marker" "$file" | head -n 1 | cut -d: -f1 || true)
    if [ -z "$line" ] || [ "$line" -le "$previous" ]; then
      printf 'marker out of order or missing: %s\n' "$marker" >&2
      printf '%s\n' "--- $file ---" >&2
      sed -n '1,220p' "$file" >&2
      fail "$name"
    fi
    previous="$line"
  done
  pass "$name"
}

assert_file_mode() {
  local name="$1"
  local expected="$2"
  local file="$3"
  local actual

  actual=$(stat -c '%a' "$file")
  assert_eq "$name" "$expected" "$actual"
}

# Test definitions live in fixtures/*.sh, one file per area; execution order
# is pinned by the registration list below, not by file order.
for fixture_file in "$SCRIPT_DIR"/fixtures/*.sh; do
  # shellcheck disable=SC1090 # Fixture files are enumerated at runtime.
  . "$fixture_file"
done

test_trace_to_details
test_review_footer_note
test_output_parser
test_heading_location_fallback
test_location_line_normalization
test_review_post_body_cleanup
test_prompt_assembly
test_prompt_failure_propagates
test_diff_per_file_assembly
test_prompt_context_budgets_truncate
test_symlink_snapshot_safety
test_worktree_cache_keeps_per_head_slots
test_prune_stale_review_worktrees
test_invalid_verdict_state
test_artifact_secret_safety
test_state_and_output_permissions
test_pr_queue_skip_reasons
test_reviewer_re_requested_review_bypasses_reviewed_sha_skip
test_agy_invocation_isolates_review_context
test_agy_records_actual_invocation
test_agy_invocation_closes_lock_fd
test_agy_invocation_denies_build_tools
test_agy_uses_structured_transcript_when_available
test_agy_records_resolved_model_label
test_agy_records_session_and_archives_transcript
test_probe_agy_cli_version
test_agy_quota_backoff_detection
test_agy_surfaces_quota_exhaustion_from_cli_log_on_empty_response
test_agy_reads_review_from_referenced_artifact
test_agy_warns_on_home_context_files
test_github_api_retries_and_logs
test_post_review_uses_rest_api
test_review_check_run_signal_helpers
test_inline_review_comments_follow_diff_anchors
test_suggestion_cap_demotes_oversized_blocks
test_review_thread_resolution_helpers
test_review_body_dedup_filter
test_unresolved_thread_replies_parser
test_still_open_thread_reply_posting
test_review_state_uses_github_reviews_only
test_check_ci_paginates_required_check_runs
test_check_runs_summary_reports_only_needed_plumbing
test_ci_states
test_config_file_resolution
test_dry_run_out_resolution
test_personality_config_resolution
test_private_key_permissions
test_log_rotation
test_run_once_sync_failure_fails_closed
test_reviewer_attempt_budget_stops_repeated_expensive_failures
test_reviewer_pending_ci_does_not_starve_queue
test_reviewer_pending_ci_opens_queued_check_run
test_reviewer_backoff_skips_recently_failed_pr
test_reviewer_invalid_output_backoff_skips_before_attempt_budget
test_reviewer_agy_quota_failure_reacts_and_skips_failure_cap
test_reviewer_failure_backoff_escalates_and_never_blocks_success
test_reviewer_research_capture_posts_selected_review_only

# Assertion-count tripwire. Each assert_* and bare pass increments pass_count,
# so a dropped assertion (e.g. two calls collapsed onto one physical line, where
# only the first runs and the rest become ignored arguments) lowers the total
# without ever turning the run red. Pin the count and bump it deliberately when
# you add or remove assertions.
# 602 after #157 helpers; research e2e: -2 shape-only +9 strong archive/session;
# +8 stdout_fallback null-archive path → 617 (includes footer shape A +3).
EXPECTED_ASSERTIONS=619
if [ "$pass_count" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf 'not ok - assertion-count tripwire: expected %s, ran %s\n' "$EXPECTED_ASSERTIONS" "$pass_count" >&2
  printf 'If you intentionally changed the number of assertions, update EXPECTED_ASSERTIONS.\n' >&2
  exit 1
fi

printf 'passed %s fixture assertions (matches pinned EXPECTED_ASSERTIONS)\n' "$pass_count"
