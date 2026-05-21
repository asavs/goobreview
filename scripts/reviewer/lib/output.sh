#!/usr/bin/env bash
# Gemini review-output parsing helpers. These functions are intentionally
# side-effect-light so adversarial fixtures can exercise parser behavior.

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

review_meta_block_count() {
  awk '
    /^<!-- REVIEW_META[[:space:]]*$/ { count++ }
    END { print count + 0 }
  '
}

extract_review_meta() {
  awk '
    /^<!-- REVIEW_META[[:space:]]*$/ { in_meta = 1; next }
    /^REVIEW_META -->[[:space:]]*$/ { in_meta = 0; exit }
    in_meta && /^```(json|text)?[[:space:]]*$/ { next }
    in_meta { print }
  '
}

strip_review_meta() {
  awk '
    /^<!-- REVIEW_META[[:space:]]*$/ { in_meta = 1; next }
    /^REVIEW_META -->[[:space:]]*$/ { in_meta = 0; next }
    !in_meta { print }
  '
}

review_body_after_verdict() {
  awk '
    found { print }
    /^VERDICT: (APPROVE|REQUEST_CHANGES|COMMENT)$/ { found = 1 }
  '
}

review_meta_json_or_empty() {
  local log_prefix="$1"
  local review meta_count meta_json

  review=$(cat)
  meta_count=$(printf '%s' "$review" | review_meta_block_count)
  if [ "$meta_count" -eq 0 ]; then
    return 0
  fi
  if [ "$meta_count" -ne 1 ]; then
    log "$log_prefix: gemini emitted $meta_count REVIEW_META blocks, ignoring metadata"
    return 0
  fi

  meta_json=$(printf '%s' "$review" | extract_review_meta)
  if [ -n "${meta_json// }" ] && ! printf '%s' "$meta_json" | jq -e . >/dev/null 2>>"$LOG_FILE"; then
    log "$log_prefix: gemini emitted invalid REVIEW_META JSON, ignoring metadata"
    return 0
  fi

  printf '%s' "$meta_json"
}

review_inline_comments_json() {
  local meta_json="$1"
  local diff_paths_file="${2:-}"
  local diff_paths_json="null"

  if [ -n "$diff_paths_file" ] && [ -f "$diff_paths_file" ]; then
    diff_paths_json=$(jq -R -s 'split("\n") | map(select(length > 0))' "$diff_paths_file")
  fi

  if [ -n "${meta_json// }" ]; then
    printf '%s' "$meta_json" | jq -c --argjson diff_paths "$diff_paths_json" '
      [
        .findings[]?
        | select((.path // "") != "" and (.line | type) == "number")
        | (.path // "") as $path
        | select($diff_paths == null or ($diff_paths | index($path)))
        | {
            path: $path,
            line: .line,
            side: "RIGHT",
            body: (
              "### [" + (.severity // "P?") + "] " + (.title // "Finding") + "\n\n" +
              (.body // "") + "\n\n" +
              "`Finding-ID: " + (.id // "unknown") + "`"
            )
          }
      ]'
  else
    printf '[]\n'
  fi
}
