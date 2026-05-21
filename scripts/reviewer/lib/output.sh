#!/usr/bin/env bash
# Gemini review-output parsing helpers. Keep the reviewer contract tiny:
# one verdict line, then normal markdown review text.

review_verdict_event() {
  local verdict_line

  verdict_line=$(grep -m 1 '^VERDICT: ' || true)
  case "$verdict_line" in
    "VERDICT: APPROVE")          printf 'APPROVE\n' ;;
    "VERDICT: REQUEST_CHANGES")  printf 'REQUEST_CHANGES\n' ;;
    "VERDICT: COMMENT")          printf 'COMMENT\n' ;;
    *)                           return 1 ;;
  esac
}

review_body_after_verdict() {
  awk '
    found { print }
    /^VERDICT: (APPROVE|REQUEST_CHANGES|COMMENT)$/ { found = 1 }
  '
}
