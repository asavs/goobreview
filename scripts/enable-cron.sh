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

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE. Run scripts/configure.sh first." >&2
  exit 1
fi
if [ ! -x "$RUN_ONCE" ]; then
  echo "Missing $RUN_ONCE (or not executable)." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

CRON_LOG="${REVIEWER_STATE:-/var/lib/goobreview/example}/cron.log"
MARKER="# GoobReview reviewer (managed by scripts/enable-cron.sh)"
LINE="* * * * * cd $REPO_ROOT && REVIEWER_ENV_FILE=$ENV_FILE /usr/bin/bash $RUN_ONCE >> $CRON_LOG 2>&1"
PATH_LINE="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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
  tail -f ${REVIEWER_STATE:-/var/lib/goobreview/example}/log.txt

To pause:
  crontab -e   # then comment out the line marked: $MARKER
EOF
