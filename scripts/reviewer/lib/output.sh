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
