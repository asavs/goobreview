#!/usr/bin/env bash
set -euo pipefail

# REPO is consumed by github_check_runs_json in the sourced GitHub API helper.
# shellcheck disable=SC2034
REPO="${1:?usage: check-ci.sh <owner/repo> <head-sha> [required-checks-file]}"
HEAD_SHA="${2:?usage: check-ci.sh <owner/repo> <head-sha> [required-checks-file]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck disable=SC1091
. "$LIB_DIR/ci.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/github-api.sh"
REQUIRED_CHECKS_FILE="${3:-$SCRIPT_DIR/../../config/required-checks.json}"
if [ ! -f "$REQUIRED_CHECKS_FILE" ] && [ -f "$SCRIPT_DIR/../../config/required-checks.example.json" ]; then
  REQUIRED_CHECKS_FILE="$SCRIPT_DIR/../../config/required-checks.example.json"
fi

required_checks_json=$(reviewer_required_checks_json "$REQUIRED_CHECKS_FILE")

if [ "$(printf '%s' "$required_checks_json" | jq 'length')" -eq 0 ]; then
  printf 'success\n'
  exit 0
fi

if [ -n "${CHECK_RUNS_JSON:-}" ]; then
  printf '%s' "$CHECK_RUNS_JSON"
else
  github_check_runs_json "$HEAD_SHA"
fi | reviewer_ci_state_from_json "$required_checks_json"
