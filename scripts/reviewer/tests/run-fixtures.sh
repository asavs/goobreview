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
. "$LIB_DIR/config.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/ci.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/gemini.sh"
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
}

test_prompt_assembly() {
  local prompt_file

  prompt_file="$TMP_ROOT/prompt.md"

  PERSONALITY_FILE="$TMP_ROOT/personality.md"
  PROMPT_FILE="$TMP_ROOT/engine.md"
  printf '## Role\nBe sharp.\n' > "$PERSONALITY_FILE"
  printf '# GitHub Review Format\nFirst line: APPROVE, REQUEST_CHANGES, or COMMENT.\nUse REQUEST_CHANGES only for concrete issues that should block merge.\nUse COMMENT when the review is informational.\nUse file references such as `path/to/file.ext:123`.\n' > "$PROMPT_FILE"

  REPO="example/repo"

  gh() {
    if [ "${1:-}" = "pr" ] && [ "${2:-}" = "diff" ]; then
      printf 'diff --git a/src/auth.py b/src/auth.py\n+++ b/src/auth.py\n@@ -1,0 +1,1 @@\n+def get_user_from_request(request): pass\n'
      return 0
    fi

    return 1
  }

  build_review_prompt 999 "$prompt_file"

  assert_order "prompt uses compressed canonical section order" "$prompt_file" \
    "## Role" \
    "diff --git a/src/auth.py b/src/auth.py" \
    "# GitHub Review Format"
  assert_contains "prompt includes PR diff" "diff --git a/src/auth.py b/src/auth.py" "$prompt_file"
  assert_contains "prompt includes GitHub formatting rules last" "First line: APPROVE, REQUEST_CHANGES, or COMMENT." "$prompt_file"
  assert_contains "prompt includes request-changes policy" "Use REQUEST_CHANGES only for concrete issues that should block merge." "$prompt_file"
  assert_contains "prompt includes comment policy" "Use COMMENT when the review is informational." "$prompt_file"
  assert_contains "prompt includes GitHub file references" 'Use file references such as `path/to/file.ext:123`.' "$prompt_file"
  assert_not_contains "prompt omits CI gate" "CI Gate" "$prompt_file"
  assert_not_contains "prompt omits file tree" "File Tree" "$prompt_file"
  assert_not_contains "prompt omits project docs" "Project Docs" "$prompt_file"
  assert_not_contains "prompt omits selected context" "Selected Context" "$prompt_file"
  assert_not_contains "prompt omits PR metadata JSON" "metadata (JSON)" "$prompt_file"
  assert_not_contains "prompt omits all-check summary" "all-check summary" "$prompt_file"
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
    printf 'settings=%s\n' "$GEMINI_CLI_SYSTEM_SETTINGS_PATH"
  }

  output=$(run_gemini_review "$prompt_file" "$err_file" "$worktree_dir")
  settings_path=$(printf '%s\n' "$output" | sed -n 's/^settings=//p')

  assert_contains "gemini runs outside PR snapshot" "cwd=$STATE_DIR/gemini-runtime" <(printf '%s\n' "$output")
  assert_contains "gemini child gets no gh token" "gh_token=unset" <(printf '%s\n' "$output")
  assert_contains "gemini child gets no github token" "github_token=unset" <(printf '%s\n' "$output")
  assert_contains "gemini child gets no app key path" "key_path=unset" <(printf '%s\n' "$output")
  assert_eq "gemini settings disables context filename" ".goobreview-gemini-context-disabled.md" "$(jq -r '.context.fileName' "$settings_path")"
  assert_eq "gemini settings attaches PR snapshot" "$worktree_dir" "$(jq -r '.context.includeDirectories[0]' "$settings_path")"
  assert_eq "gemini settings disables local env" "true" "$(jq -r '.advanced.ignoreLocalEnv' "$settings_path")"
  assert_eq "gemini settings excludes shell tool" "false" "$(jq '.tools.core | index("run_shell_command") != null' "$settings_path")"
  assert_eq "gemini settings excludes mcp servers" "0" "$(jq '.mcp.allowed | length' "$settings_path")"
}

test_output_parser
test_prompt_assembly
test_gemini_invocation_isolates_review_context
test_ci_states

printf 'passed %s fixture assertions\n' "$pass_count"
