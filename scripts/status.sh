#!/usr/bin/env bash
# Summarize the current GoobReview setup state by composing preflight sensors.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/ops.sh"
export OPS_LOG_PREFIX="status"

run_sensor() {
  local path="$1"
  if [ -f "$path" ]; then
    bash "$path"
  else
    ops_warn "Missing $path; skipping."
  fi
}

cat <<EOF
GoobReview status
=================

EOF

run_sensor "$SCRIPT_DIR/preflight/gcloud.sh"
printf '\n'
run_sensor "$SCRIPT_DIR/preflight/vm.sh"
printf '\n'
run_sensor "$SCRIPT_DIR/preflight/vm-discovery.sh"
printf '\n'
run_sensor "$SCRIPT_DIR/preflight/app.sh"
printf '\n'
run_sensor "$SCRIPT_DIR/preflight/config.sh"
printf '\n'
run_sensor "$SCRIPT_DIR/preflight/runtime.sh"
