#!/usr/bin/env bash
# Install the GoobReview cron entry for the current user. Idempotent — safe
# to re-run; refuses to add a duplicate.
#
# Pauses: edit your crontab (`crontab -e`) and comment out the line marked
# `# GoobReview reviewer (managed by scripts/enable-cron.sh)`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${REVIEWER_ENV_FILE:-$REPO_ROOT/config/reviewer.env}"
RUN_ONCE="$SCRIPT_DIR/reviewer/run-once.sh"
ROTATE_LOG="$SCRIPT_DIR/reviewer/rotate-log.sh"
LAUNCH_CHECK="$SCRIPT_DIR/launch-check.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/ops.sh"
export OPS_LOG_PREFIX="enable-cron"

ops_require_command crontab "Install cron before enabling the scheduler."
ops_require_file "$ENV_FILE" "Run scripts/configure.sh first."
ops_require_executable "$RUN_ONCE" "This checkout looks incomplete."
ops_require_executable "$ROTATE_LOG" "This checkout looks incomplete."
ops_require_executable "$LAUNCH_CHECK" "This checkout looks incomplete."
if [ ! -x /usr/bin/bash ]; then
  ops_die "Missing /usr/bin/bash; cron line would not be runnable."
fi
bash "$SCRIPT_DIR/preflight/checkout.sh" --strict --allow-setup-ref-mismatch

ops_source_env "$ENV_FILE"
ops_require_envs REVIEWER_REPO REVIEWER_APP_ID REVIEWER_APP_INSTALLATION_ID REVIEWER_APP_PRIVATE_KEY_PATH
ops_validate_owner_repo "$REVIEWER_REPO" REVIEWER_REPO
ops_validate_uint REVIEWER_APP_ID "$REVIEWER_APP_ID"
ops_validate_uint REVIEWER_APP_INSTALLATION_ID "$REVIEWER_APP_INSTALLATION_ID"
ops_require_private_key "$REVIEWER_APP_PRIVATE_KEY_PATH"

STATE_DIR="${REVIEWER_STATE:-/var/lib/goobreview/example}"
mkdir -p "$STATE_DIR"
CRON_LOG="$STATE_DIR/cron.log"
MARKER="# GoobReview reviewer (managed by scripts/enable-cron.sh)"
LINE="* * * * * cd $(ops_shell_quote "$REPO_ROOT") && REVIEWER_ENV_FILE=$(ops_shell_quote "$ENV_FILE") /usr/bin/bash $(ops_shell_quote "$ROTATE_LOG") $(ops_shell_quote "$CRON_LOG") && REVIEWER_ENV_FILE=$(ops_shell_quote "$ENV_FILE") /usr/bin/bash $(ops_shell_quote "$RUN_ONCE") >> $(ops_shell_quote "$CRON_LOG") 2>&1"
PATH_LINE="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [ "${REVIEWER_ALLOW_ENABLE_CRON_WITHOUT_LAUNCH_CHECK:-0}" = "1" ]; then
  ops_warn "Skipping launch validation because REVIEWER_ALLOW_ENABLE_CRON_WITHOUT_LAUNCH_CHECK=1."
else
  "$LAUNCH_CHECK"
fi

current="$(crontab -l 2>/dev/null || true)"

if printf '%s\n' "$current" | grep -Fq "$MARKER"; then
  echo "GoobReview cron entry already installed for $(whoami); nothing to do."
  echo "Inspect:  crontab -l | grep -F -A1 '$MARKER'"
  exit 0
fi

{
  if [ -n "$current" ]; then
    printf '%s\n' "$current"
    if ! printf '%s\n' "$current" | grep -Fq "$PATH_LINE"; then
      printf '%s\n' "$PATH_LINE"
    fi
  else
    printf '%s\n' "$PATH_LINE"
  fi
  printf '%s\n' "$MARKER"
  printf '%s\n' "$LINE"
} | crontab -

cat <<EOF
Installed cron entry for $(whoami):
  $LINE

Watch the next tick (cron fires every minute):
  tail -f $CRON_LOG
  tail -f $STATE_DIR/log.txt

To pause:
  crontab -e   # then comment out the line marked: $MARKER
EOF
