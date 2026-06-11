#!/usr/bin/env bash
# Fixture globals are intentionally consumed by sourced reviewer libraries.
# shellcheck disable=SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEWER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$REVIEWER_DIR/lib"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

LOG_FILE="$TMP_ROOT/test.log"
: > "$LOG_FILE"

# shellcheck disable=SC1091
. "$LIB_DIR/ci.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/config.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/gemini.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/github-api.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/output.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/prompt.sh"

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

  if ! grep -Fq "$needle" "$file"; then
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

  if grep -Fq "$needle" "$file"; then
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

test_output_parser() {
  local valid approve expected_body

  # shellcheck disable=SC2016
  valid='REQUEST_CHANGES
## Summary
This helper lets callers spoof users.

## Blocking Findings
### [P1] User spoofing
**File:** `src/auth.py:42`
**What can break:** Anyone can select a different user by query string.
**Suggested fix:** Use the authenticated session user instead.'
  expected_body=$(printf '%s' "$valid" | sed '1d')

  assert_eq "valid verdict maps to event" "REQUEST_CHANGES" "$(printf '%s' "$valid" | review_verdict_event)"
  assert_eq "review body strips only verdict line" "$expected_body" "$(printf '%s' "$valid" | review_body_after_verdict)"
  assert_eq "file and line references stay in body" "1" "$(printf '%s' "$valid" | review_body_after_verdict | grep -c 'src/auth.py:42')"

  if printf 'NOPE\n' | review_verdict_event >/dev/null; then
    fail "malformed verdict is rejected"
  fi
  pass "malformed verdict is rejected"

  if printf 'intro\nAPPROVE\n' | review_verdict_event >/dev/null; then
    fail "verdict must be first line"
  fi
  pass "verdict must be first line"

  approve='APPROVE
## Summary
No findings.'
  assert_eq "approve output remains parseable without metadata" "APPROVE" "$(printf '%s' "$approve" | review_verdict_event)"

  assert_eq "verdict line tolerates CRLF and whitespace" "APPROVE" "$(printf '%s\r\n' '  APPROVE' | review_verdict_event)"
  if printf '%s\n' 'approve' | review_verdict_event >/dev/null; then
    fail "verdict remains case-sensitive"
  fi
  pass "verdict remains case-sensitive"
}

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

test_prompt_assembly() {
  local prompt_file worktree_dir

  prompt_file="$TMP_ROOT/prompt.md"
  worktree_dir="$TMP_ROOT/worktree"

  PERSONALITY_FILE="$TMP_ROOT/personality.md"
  PROMPT_FILE="$TMP_ROOT/engine.md"
  PROMPT_PAYLOAD_FILE="$TMP_ROOT/prompt-payload.json"
  printf '## Role\nBe sharp.\n' > "$PERSONALITY_FILE"
  {
    printf '%s\n' '# GitHub Review Format'
    printf '%s\n' 'First line: APPROVE, REQUEST_CHANGES, or COMMENT.'
    printf '%s\n' 'Use REQUEST_CHANGES only for concrete issues that should block merge.'
    printf '%s\n' 'Use COMMENT when the review is informational.'
    printf '%s\n' "Use file references such as \`path/to/file.ext:123\`."
  } > "$PROMPT_FILE"
  cat > "$PROMPT_PAYLOAD_FILE" <<'JSON'
{
  "segments": {
    "personality": {"enabled": true},
    "pr_metadata": {
      "enabled": true,
      "include_title": true,
      "include_author": true,
      "include_url": true,
      "include_base_branch": true,
      "include_head_branch": true,
      "include_head_sha": true,
      "include_description": false
    },
    "ci_status": {"enabled": true, "mode": "one_line"},
    "changed_paths": {"enabled": true},
    "relevant_guidance": {
      "enabled": true,
      "mode": "paths_only",
      "rules": [
        {
          "when_changed_path_matches": ["client/**"],
          "guidance_paths": ["client/GUIDELINES.md"]
        }
      ]
    },
    "source_snapshot_hint": {"enabled": true},
    "all_check_summary": {"enabled": false},
    "full_file_tree": {"enabled": false},
    "selected_file_contents": {"enabled": false},
    "diff": {"enabled": true},
    "response_format": {"enabled": true}
  }
}
JSON
  mkdir -p "$worktree_dir/client"
  printf 'Client guidance.\n' > "$worktree_dir/client/GUIDELINES.md"

  REPO="example/repo"

  # shellcheck disable=SC2317 # Mocked API helper is invoked indirectly by build_review_prompt.
  github_api_get() {
    if [ "${1:-}" = "repos/example/repo/pulls/999" ] && [ "${2:-}" = "application/vnd.github.diff" ]; then
      printf 'diff --git a/src/auth.py b/src/auth.py\n+++ b/src/auth.py\n@@ -1,0 +1,1 @@\n+def get_user_from_request(request): pass\n'
      return 0
    fi
    if [ "${1:-}" = "repos/example/repo/pulls/999" ]; then
      printf '%s\n' '{"title":"Test auth change","body":"Author body","user":{"login":"alice"},"html_url":"https://github.com/example/repo/pull/999","base":{"ref":"main"},"head":{"ref":"feature/auth","sha":"abc123"}}'
      return 0
    fi

    return 1
  }

  # shellcheck disable=SC2317 # Mocked API helper is invoked indirectly by build_review_prompt.
  github_api_paginate_array() {
    if [ "${1:-}" = "repos/example/repo/pulls/999/files" ]; then
      printf '%s\n' '{"filename":"client/src/auth.py"}'
      return 0
    fi

    return 1
  }

  build_review_prompt 999 "$prompt_file" success abc123 "$worktree_dir"

  assert_order "prompt uses compressed canonical section order" "$prompt_file" \
    "## Role" \
    "PR Metadata" \
    "CI Status" \
    "Changed Paths" \
    "Relevant Guidance" \
    "Read-Only Source Snapshot" \
    "diff --git a/src/auth.py b/src/auth.py" \
    "# GitHub Review Format"
  assert_contains "prompt includes PR metadata" "Title: Test auth change" "$prompt_file"
  assert_contains "prompt includes CI one-liner" "CI: required GitHub Actions checks passed" "$prompt_file"
  assert_contains "prompt includes changed paths" "client/src/auth.py" "$prompt_file"
  assert_contains "prompt includes relevant guidance path" "client/GUIDELINES.md" "$prompt_file"
  assert_contains "prompt includes source snapshot hint" "read-only PR-head source tree" "$prompt_file"
  assert_contains "prompt includes PR diff" "diff --git a/src/auth.py b/src/auth.py" "$prompt_file"
  assert_contains "prompt includes GitHub formatting rules last" "First line: APPROVE, REQUEST_CHANGES, or COMMENT." "$prompt_file"
  assert_contains "prompt includes request-changes policy" "Use REQUEST_CHANGES only for concrete issues that should block merge." "$prompt_file"
  assert_contains "prompt includes comment policy" "Use COMMENT when the review is informational." "$prompt_file"
  assert_contains "prompt includes GitHub file references" "Use file references such as \`path/to/file.ext:123\`." "$prompt_file"
  assert_not_contains "prompt omits full file tree" "Full PR-Head File Tree" "$prompt_file"
  assert_not_contains "prompt omits selected file contents" "Selected PR-Head File Contents" "$prompt_file"
  assert_not_contains "prompt omits all-check summary" "All Check Summary" "$prompt_file"
}

test_prompt_failure_propagates() {
  local prompt_file worktree_dir

  prompt_file="$TMP_ROOT/prompt-failure.md"
  worktree_dir="$TMP_ROOT/worktree-failure"

  PERSONALITY_FILE="$TMP_ROOT/personality-failure.md"
  PROMPT_FILE="$TMP_ROOT/engine-failure.md"
  PROMPT_PAYLOAD_FILE="$TMP_ROOT/prompt-payload-failure.json"
  printf '## Role\nBe sharp.\n' > "$PERSONALITY_FILE"
  printf 'First line: APPROVE, REQUEST_CHANGES, or COMMENT.\n' > "$PROMPT_FILE"
  cat > "$PROMPT_PAYLOAD_FILE" <<'JSON'
{
  "segments": {
    "personality": {"enabled": true},
    "pr_metadata": {"enabled": false},
    "ci_status": {"enabled": false},
    "changed_paths": {"enabled": true},
    "relevant_guidance": {"enabled": false},
    "source_snapshot_hint": {"enabled": false},
    "all_check_summary": {"enabled": false},
    "full_file_tree": {"enabled": false},
    "selected_file_contents": {"enabled": false},
    "diff": {"enabled": true},
    "response_format": {"enabled": true}
  }
}
JSON
  mkdir -p "$worktree_dir"
  REPO="example/repo"

  # shellcheck disable=SC2317 # Mocked API helper is invoked indirectly by build_review_prompt.
  github_api_get() {
    if [ "${1:-}" = "repos/example/repo/pulls/999" ] && [ "${2:-}" = "application/vnd.github.diff" ]; then
      return 1
    fi

    return 1
  }

  # shellcheck disable=SC2317 # Mocked API helper is invoked indirectly by build_review_prompt.
  github_api_paginate_array() {
    if [ "${1:-}" = "repos/example/repo/pulls/999/files" ]; then
      printf '%s\n' '{"filename":"client/src/auth.py"}'
      return 0
    fi

    return 1
  }

  if build_review_prompt 999 "$prompt_file" success abc123 "$worktree_dir"; then
    fail "prompt build failure is propagated"
  fi
  pass "prompt build failure is propagated"
}

test_invalid_verdict_state() {
  local artifact count

  STATE_DIR="$TMP_ROOT/invalid-state"
  mkdir -p "$STATE_DIR"

  assert_eq "missing invalid verdict count is zero" "0" "$(invalid_verdict_attempt_count 17 abc123)"
  count=$(record_invalid_verdict_attempt 17 abc123)
  assert_eq "invalid verdict first attempt is recorded" "1" "$count"
  count=$(record_invalid_verdict_attempt 17 abc123)
  assert_eq "invalid verdict attempts increment per head" "2" "$count"
  assert_eq "different head has separate invalid verdict count" "0" "$(invalid_verdict_attempt_count 17 def456)"

  artifact=$(write_invalid_verdict_artifact 17 abc123 INVALID_VERDICT $'NOPE\nbody')
  assert_contains "invalid artifact records PR" "PR: #17" "$artifact"
  assert_contains "invalid artifact records head SHA" "Head SHA: abc123" "$artifact"
  assert_contains "invalid artifact persists rejected output" "NOPE" "$artifact"

  clear_invalid_verdict_attempts 17 abc123
  assert_eq "invalid verdict attempts clear after valid output" "0" "$(invalid_verdict_attempt_count 17 abc123)"
}

test_gemini_invocation_isolates_review_context() {
  local prompt_file err_file output worktree_dir settings_path

  STATE_DIR="$TMP_ROOT/state"
  GEMINI_TIMEOUT=60
  GEMINI_MODEL=auto
  mkdir -p "$STATE_DIR"
  worktree_dir="$TMP_ROOT/worktree"
  mkdir -p "$worktree_dir"
  prompt_file="$TMP_ROOT/prompt-for-gemini.md"
  err_file="$TMP_ROOT/gemini.err"
  printf 'APPROVE\n' > "$prompt_file"

  GH_TOKEN=secret-token
  GITHUB_TOKEN=secret-github-token
  REVIEWER_APP_PRIVATE_KEY_PATH=/private/key.pem
  export GH_TOKEN GITHUB_TOKEN REVIEWER_APP_PRIVATE_KEY_PATH

  timeout() {
    printf 'cwd=%s\n' "$PWD"
    printf 'gh_token=%s\n' "${GH_TOKEN:-unset}"
    printf 'github_token=%s\n' "${GITHUB_TOKEN:-unset}"
    printf 'key_path=%s\n' "${REVIEWER_APP_PRIVATE_KEY_PATH:-unset}"
    printf 'trust_workspace=%s\n' "${GEMINI_CLI_TRUST_WORKSPACE:-unset}"
    printf 'settings=%s\n' "$GEMINI_CLI_SYSTEM_SETTINGS_PATH"
  }

  output=$(run_gemini_review "$prompt_file" "$err_file" "$worktree_dir")
  settings_path=$(printf '%s\n' "$output" | sed -n 's/^settings=//p')

  assert_contains "gemini runs outside PR snapshot" "cwd=$STATE_DIR/gemini-runtime" <(printf '%s\n' "$output")
  assert_contains "gemini child gets no gh token" "gh_token=unset" <(printf '%s\n' "$output")
  assert_contains "gemini child gets no github token" "github_token=unset" <(printf '%s\n' "$output")
  assert_contains "gemini child gets no app key path" "key_path=unset" <(printf '%s\n' "$output")
  assert_contains "gemini trusts isolated runtime workspace" "trust_workspace=true" <(printf '%s\n' "$output")
  assert_eq "gemini settings disables context filename" ".goobreview-gemini-context-disabled.md" "$(jq -r '.context.fileName' "$settings_path")"
  assert_eq "gemini settings attaches PR snapshot" "$worktree_dir" "$(jq -r '.context.includeDirectories[0]' "$settings_path")"
  assert_eq "gemini settings disables local env" "true" "$(jq -r '.advanced.ignoreLocalEnv' "$settings_path")"
  assert_eq "gemini settings excludes shell tool" "false" "$(jq '.tools.core | index("run_shell_command") != null' "$settings_path")"
  assert_eq "gemini settings excludes mcp servers" "0" "$(jq '.mcp.allowed | length' "$settings_path")"
}


test_pr_queue_skip_reasons() {
  local pulls rows reason

  pulls='[{"number":1,"draft":true,"user":{"login":"alice"},"head":{"sha":"sha1"}},
    {"number":2,"draft":false,"user":{"login":"goobreview[bot]"},"head":{"sha":"sha2"}},
    {"number":3,"user":{"login":"maintainer"},"head":{"sha":"sha3"}},
    {"number":4,"draft":false,"user":{"login":"reviewer"},"head":{"sha":"sha4"}}]'
  rows=$(printf '%s\n' "$pulls" | jq -c '.[]' | pull_request_queue_rows)

  assert_contains "PR queue preserves draft rows" $'1\talice\tsha1\ttrue' <(printf '%s\n' "$rows")
  assert_contains "PR queue defaults missing draft to false" $'3\tmaintainer\tsha3\tfalse' <(printf '%s\n' "$rows")

  reason=$(reviewer_pr_skip_reason 1 alice sha1 true 'goobreview[bot]' '' '')
  assert_eq "draft skip reason is explicit" "PR #1@sha1 is a draft, skipping until it is marked ready for review" "$reason"

  reason=$(reviewer_pr_skip_reason 2 'goobreview[bot]' sha2 false 'goobreview[bot]' '' '')
  assert_eq "bot author skip reason is explicit" "PR #2@sha2 is authored by goobreview[bot], skipping self-review" "$reason"

  reason=$(reviewer_pr_skip_reason 4 reviewer sha4 false 'goobreview[bot]' reviewer '')
  assert_eq "reviewer user skip reason is explicit" "PR #4@sha4 is authored by REVIEWER_USER=reviewer, skipping configured reviewer identity" "$reason"

  if reviewer_pr_skip_reason 3 maintainer sha3 false 'goobreview[bot]' reviewer '' >/dev/null; then
    fail "reviewable PR has no skip reason"
  fi
  pass "reviewable PR has no skip reason"
}

test_output_parser
test_prompt_assembly
test_prompt_failure_propagates
test_invalid_verdict_state
test_pr_queue_skip_reasons
test_gemini_invocation_isolates_review_context
test_ci_states

printf 'passed %s fixture assertions\n' "$pass_count"
