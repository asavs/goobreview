#!/usr/bin/env bash
# Report GoobReview runtime readiness: state dir, dry runs, cron, and logs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${REVIEWER_ENV_FILE:-$REPO_ROOT/config/reviewer.env}"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/ops.sh"
export OPS_LOG_PREFIX="preflight-runtime"

report=0

usage() {
  cat <<EOF
Usage: bash scripts/preflight/runtime.sh [--report]

Checks runtime state, dry-run artifacts, cron installation, and recent log files.

Options:
  --report   Emit machine-readable key=value output.
  -h, --help Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --report)
      report=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      ops_die "Unknown option: $1"
      ;;
  esac
  shift
done

bool() {
  case "$1" in
    1|true|True|TRUE|yes) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

shell_value() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

print_field() {
  local key="$1" value="$2"
  printf '%s=%s\n' "$key" "$(shell_value "$value")"
}

file_mtime() {
  local path="$1"
  if [ ! -f "$path" ]; then
    printf ''
    return
  fi
  if stat -c '%y' "$path" >/dev/null 2>&1; then
    stat -c '%y' "$path" 2>/dev/null
  elif stat -f '%Sm' "$path" >/dev/null 2>&1; then
    stat -f '%Sm' "$path" 2>/dev/null
  else
    printf 'unknown'
  fi
}

count_dry_runs() {
  local state_dir="$1"
  if [ -z "$state_dir" ] || [ ! -d "$state_dir" ]; then
    printf '0'
    return
  fi
  find "$state_dir" -maxdepth 1 -type f \( -name 'dry-run-*.txt' -o -name 'dry-pr-*.txt' \) \
    2>/dev/null | wc -l | tr -d ' '
}

latest_dry_run() {
  local state_dir="$1"
  if [ -z "$state_dir" ] || [ ! -d "$state_dir" ]; then
    printf ''
    return
  fi
  find "$state_dir" -maxdepth 1 -type f \( -name 'dry-run-*.txt' -o -name 'dry-pr-*.txt' \) \
    2>/dev/null | sort | tail -n 1
}

latest_launch_metadata() {
  local state_dir="$1"
  if [ -z "$state_dir" ] || [ ! -d "$state_dir" ]; then
    printf ''
    return
  fi
  find "$state_dir" -maxdepth 1 -type f \( -name 'dry-run-*.txt.launch.json' -o -name 'dry-pr-*.txt.launch.json' \) \
    2>/dev/null | sort | tail -n 1
}

cron_installed() {
  local current marker
  marker="# GoobReview reviewer (managed by scripts/enable-cron.sh)"
  if ! command -v crontab >/dev/null 2>&1; then
    printf 'unknown'
    return
  fi
  current="$(crontab -l 2>/dev/null || true)"
  if printf '%s\n' "$current" | grep -Fq "$marker"; then
    printf 'true'
  else
    printf 'false'
  fi
}

state_dir="/var/lib/goobreview/example"
if [ -f "$ENV_FILE" ]; then
  state_from_env="$(ops_env_get "$ENV_FILE" REVIEWER_STATE)"
  [ -z "$state_from_env" ] || state_dir="$state_from_env"
fi

state_present=0
if [ -d "$state_dir" ]; then
  state_present=1
fi

dry_run_count="$(count_dry_runs "$state_dir")"
latest_dry_run_path="$(latest_dry_run "$state_dir")"
latest_launch_metadata_path="$(latest_launch_metadata "$state_dir")"
latest_dry_run_mtime="$(file_mtime "$latest_dry_run_path")"
latest_launch_metadata_mtime="$(file_mtime "$latest_launch_metadata_path")"
cron_state="$(cron_installed)"
log_file="$state_dir/log.txt"
cron_log="$state_dir/cron.log"
sync_log="$state_dir/sync.log"
log_mtime="$(file_mtime "$log_file")"
cron_log_mtime="$(file_mtime "$cron_log")"
sync_log_mtime="$(file_mtime "$sync_log")"

recommendation="Run scripts/dry-run.sh and inspect the generated artifact before launching."
if [ "$state_present" -ne 1 ]; then
  recommendation="Run scripts/configure.sh and scripts/dry-run.sh to create runtime state."
elif [ -z "$latest_launch_metadata_path" ]; then
  recommendation="Run REVIEWER_DRY_RUN_BYPASS_CI=0 scripts/dry-run.sh and inspect the generated artifact before enabling cron."
elif [ "$cron_state" = "true" ]; then
  recommendation="Scheduler appears installed; inspect logs under $state_dir."
else
  recommendation="Launch metadata exists; run scripts/launch-check.sh, then scripts/enable-cron.sh when ready."
fi

if [ "$report" -eq 1 ]; then
  print_field "state_dir" "$state_dir"
  print_field "state_dir_present" "$(bool "$state_present")"
  print_field "dry_run_count" "$dry_run_count"
  print_field "latest_dry_run" "$latest_dry_run_path"
  print_field "latest_dry_run_mtime" "$latest_dry_run_mtime"
  print_field "latest_launch_metadata" "$latest_launch_metadata_path"
  print_field "latest_launch_metadata_mtime" "$latest_launch_metadata_mtime"
  print_field "cron_installed" "$cron_state"
  print_field "log_file" "$log_file"
  print_field "log_mtime" "$log_mtime"
  print_field "cron_log" "$cron_log"
  print_field "cron_log_mtime" "$cron_log_mtime"
  print_field "sync_log" "$sync_log"
  print_field "sync_log_mtime" "$sync_log_mtime"
  print_field "recommendation" "$recommendation"
  exit 0
fi

cat <<EOF
Runtime preflight
-----------------
state dir:              $(bool "$state_present") ($state_dir)
dry-run artifacts:      $dry_run_count
latest dry-run:         ${latest_dry_run_path:-none}
latest dry-run mtime:   ${latest_dry_run_mtime:-none}
launch metadata:        ${latest_launch_metadata_path:-none}
launch metadata mtime:  ${latest_launch_metadata_mtime:-none}
cron installed:         $cron_state
reviewer log mtime:     ${log_mtime:-none} ($log_file)
cron log mtime:         ${cron_log_mtime:-none} ($cron_log)
sync log mtime:         ${sync_log_mtime:-none} ($sync_log)

Next: $recommendation
EOF
