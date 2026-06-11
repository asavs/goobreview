#!/usr/bin/env bash
# Gemini review-output parsing helpers. Keep the reviewer contract tiny:
# one GitHub review event line, then normal markdown review text.

review_verdict_event() {
  local verdict_line

  IFS= read -r verdict_line || true
  # Accept CRLF and accidental surrounding whitespace, then enforce a strict token.
  verdict_line=${verdict_line//$'\r'/}
  verdict_line=${verdict_line#"${verdict_line%%[![:space:]]*}"}
  verdict_line=${verdict_line%"${verdict_line##*[![:space:]]}"}

  case "$verdict_line" in
    APPROVE|REQUEST_CHANGES|COMMENT) printf '%s\n' "$verdict_line" ;;
    *)                               return 1 ;;
  esac
}

review_body_after_verdict() {
  sed '1d'
}

invalid_verdict_attempts_file() {
  local num="$1"
  local head_sha="$2"

  case "$num" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$head_sha" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac

  printf '%s/invalid-verdict-%s-%s.count\n' "$STATE_DIR" "$num" "$head_sha"
}

invalid_verdict_attempt_count() {
  local file count

  if ! file=$(invalid_verdict_attempts_file "$1" "$2"); then
    printf '0\n'
    return 0
  fi
  if [ ! -f "$file" ]; then
    printf '0\n'
    return 0
  fi

  IFS= read -r count <"$file" || count=0
  case "$count" in
    ''|*[!0-9]*) count=0 ;;
  esac
  printf '%s\n' "$count"
}

record_invalid_verdict_attempt() {
  local file tmp count

  file=$(invalid_verdict_attempts_file "$1" "$2")
  count=$(invalid_verdict_attempt_count "$1" "$2")
  count=$((count + 1))

  mkdir -p "$STATE_DIR"
  tmp=$(mktemp "$STATE_DIR/invalid-verdict-attempts.XXXXXX")
  printf '%s\n' "$count" >"$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$file"
  printf '%s\n' "$count"
}

clear_invalid_verdict_attempts() {
  local file

  file=$(invalid_verdict_attempts_file "$1" "$2") || return 0
  rm -f "$file"
}

invalid_verdict_artifact_path() {
  local num="$1"

  case "$num" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s/last-invalid-%s.txt\n' "$STATE_DIR" "$num"
}

write_invalid_verdict_artifact() {
  local num="$1"
  local head_sha="$2"
  local reason="$3"
  local rejected_output="$4"
  local artifact tmp

  artifact=$(invalid_verdict_artifact_path "$num")
  mkdir -p "$STATE_DIR"
  tmp=$(mktemp "$STATE_DIR/last-invalid-$num.XXXXXX")
  {
    printf 'GoobReview invalid Gemini output\n'
    printf 'PR: #%s\n' "$num"
    printf 'Head SHA: %s\n' "$head_sha"
    printf 'Reason: %s\n' "$reason"
    printf 'Captured at: %s\n' "$(date -Is)"
    printf '\n===== REJECTED GEMINI OUTPUT START =====\n'
    printf '%s\n' "$rejected_output"
    printf '===== REJECTED GEMINI OUTPUT END =====\n'
  } >"$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$artifact"
  printf '%s\n' "$artifact"
}
