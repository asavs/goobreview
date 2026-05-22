#!/usr/bin/env bash
# Required-check state helpers. Keep this logic data-driven so it can be
# tested without GitHub network calls.

reviewer_validate_required_checks_json() {
  local required_checks_json="$1"

  printf '%s' "$required_checks_json" |
    jq -e 'type == "array" and all(.[]; type == "string" and length > 0)' >/dev/null
}

reviewer_required_checks_json() {
  local file="$1"
  local required_checks_json

  if [ -n "${REQUIRED_CHECKS_JSON:-}" ]; then
    required_checks_json="$REQUIRED_CHECKS_JSON"
  else
    required_checks_json=$(jq -c . "$file") || return 1
  fi

  reviewer_validate_required_checks_json "$required_checks_json" || return 1
  printf '%s' "$required_checks_json" | jq -c .
}

reviewer_ci_state_from_json() {
  local required_checks_json="$1"

  jq -r --argjson required "$required_checks_json" '
    def required_check($name):
      [.check_runs[] | select(.name == $name)]
      | sort_by(.started_at // .completed_at // "")
      | last;

    [$required[] as $name | {name: $name, check: required_check($name)}] as $checks
    | if any($checks[]; .check == null) then "incomplete"
      elif any($checks[]; .check.status != "completed") then "pending"
      elif all($checks[]; .check.conclusion == "success") then "success"
      else "failing" end
  '
}
