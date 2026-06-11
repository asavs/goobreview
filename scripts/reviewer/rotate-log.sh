#!/usr/bin/env bash
set -euo pipefail

log_file="${1:-}"
max_bytes="${REVIEWER_LOG_MAX_BYTES:-1048576}"
keep="${REVIEWER_LOG_ROTATE_KEEP:-5}"

case "$log_file" in
  '') exit 0 ;;
esac
case "$max_bytes" in
  ''|*[!0-9]*) max_bytes=1048576 ;;
esac
case "$keep" in
  ''|*[!0-9]*) keep=5 ;;
esac

[ "$keep" -gt 0 ] || exit 0
[ -f "$log_file" ] || exit 0

size=$(stat -c '%s' "$log_file" 2>/dev/null || printf 0)
[ "$size" -ge "$max_bytes" ] || exit 0

i="$keep"
while [ "$i" -gt 1 ]; do
  prev=$((i - 1))
  if [ -f "$log_file.$prev" ]; then
    mv -f "$log_file.$prev" "$log_file.$i"
  fi
  i="$prev"
done

mv -f "$log_file" "$log_file.1"
: >"$log_file"
