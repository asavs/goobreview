#!/usr/bin/env bash
# Small interactive loop for tuning personality/prompt and running a dry run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${REVIEWER_ENV_FILE:-$REPO_ROOT/config/reviewer.env}"
DRY_RUN_SH="$SCRIPT_DIR/dry-run.sh"
EDITOR_CMD="${EDITOR:-nano}"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/ops.sh"
export OPS_LOG_PREFIX="tune"

pr_number="${1:-}"
if [ -n "$pr_number" ]; then
  ops_validate_uint PR_NUMBER "$pr_number"
fi

ops_require_file "$ENV_FILE" "Run scripts/configure.sh first."
ops_require_executable "$DRY_RUN_SH" "This checkout looks incomplete."
ops_source_env "$ENV_FILE"
ops_require_envs REVIEWER_REPO

case "${REVIEWER_POSTED_PERSONALITY:-}" in
  linus) personality_file="config/personalities/linus.md" ;;
  none|'') personality_file="${REVIEWER_PERSONALITY_FILE:-config/personalities/control.md}" ;;
  *) personality_file="${REVIEWER_PERSONALITY_FILE:-config/personalities/control.md}" ;;
esac
case "$personality_file" in
  /*) personality_path="$personality_file" ;;
  *) personality_path="$REPO_ROOT/$personality_file" ;;
esac

cat <<EOF
GoobReview tuning
=================

Target repo:       $REVIEWER_REPO
Personality file:  $personality_path
Blinding policy:   edit REVIEWER_INCLUDE_AUTHOR / REVIEWER_INCLUDE_DESCRIPTION / REVIEWER_INCLUDE_COMMIT_SUBJECTS in $ENV_FILE

EOF

if [ -f "$personality_path" ] && ops_confirm "Edit personality file in $EDITOR_CMD?"; then
  "$EDITOR_CMD" "$personality_path"
elif [ ! -f "$personality_path" ]; then
  ops_warn "Personality file not found: $personality_path"
fi

if ops_confirm "Edit reviewer.env (blinding policy, budgets) in $EDITOR_CMD?"; then
  "$EDITOR_CMD" "$ENV_FILE"
fi

if ops_confirm "Run a dry-run review now?"; then
  if [ -n "$pr_number" ]; then
    "$DRY_RUN_SH" "$pr_number"
  else
    "$DRY_RUN_SH"
  fi
else
  cat <<EOF

Dry run skipped. When ready:
  scripts/dry-run.sh${pr_number:+ $pr_number}

Then inspect the artifact under \$REVIEWER_STATE and re-run scripts/tune.sh.
EOF
fi
