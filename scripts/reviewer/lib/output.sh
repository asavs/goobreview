#!/usr/bin/env bash
# Antigravity CLI review-output parsing helpers. Keep the reviewer contract tiny:
# normal markdown review text, then one final GitHub review event line.

review_verdict_event() {
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
      trimmed = line
      sub(/^[[:space:]]+/, "", trimmed)
      sub(/[[:space:]]+$/, "", trimmed)
      if (trimmed != "") verdict = trimmed
    }
    END {
      if (verdict == "APPROVE" || verdict == "REQUEST_CHANGES" || verdict == "COMMENT") {
        print verdict
        exit 0
      }
      exit 1
    }
  '
}

review_body_before_verdict() {
  awk '
    {
      lines[NR] = $0
      line = $0
      sub(/\r$/, "", line)
      trimmed = line
      sub(/^[[:space:]]+/, "", trimmed)
      sub(/[[:space:]]+$/, "", trimmed)
      if (trimmed != "") {
        last_nonempty = NR
        verdict = trimmed
      }
    }
    END {
      if (verdict != "APPROVE" && verdict != "REQUEST_CHANGES" && verdict != "COMMENT") exit 1
      for (i = 1; i < last_nonempty; i++) print lines[i]
    }
  '
}

# Extract source locations mentioned in ordinary Markdown review prose. The
# reviewer model remains free to write a conventional review; this parser
# merely discovers path:line references that can later be verified against the
# pull request diff and promoted to native GitHub review comments.
#
# Output is one unique path<TAB>line pair per line. A range such as
# src/app.ts:42-45 resolves to its first line because a later validation step
# decides whether a single-line or multi-line GitHub anchor is possible.
review_source_locations() {
  grep -oE '[[:alnum:]_.][[:alnum:]_.+/-]*\.[[:alnum:]_+-]+:[0-9]+(-[0-9]+)?' |
    sed -E 's/:([0-9]+)-[0-9]+$/\t\1/; s/:/\t/' |
    awk -F '\t' 'NF == 2 && $1 !~ /(^|\/)\.\.($|\/)/ { key = $1 FS $2; if (!seen[key]++) print }'
}

# Emit each Markdown finding section that cites at least one source location.
# NUL separators preserve the review's original newlines without asking the
# model to serialize a second data format. The caller validates the locations
# against GitHub's diff before it treats a section as an inline comment.
review_markdown_finding_sections() {
  awk '
    function emit() {
      if (in_section && section ~ /[[:alnum:]_.][[:alnum:]_.+\/-]*\.[[:alnum:]_+-]+:[0-9]+/) {
        printf "%s%c", section, 0
      }
    }
    /^#{2,6}[[:space:]]+/ {
      emit()
      section = $0 ORS
      in_section = 1
      next
    }
    in_section { section = section $0 ORS }
    END { emit() }
  '
}

review_resolved_thread_handles() {
  awk '
    function heading_level(line) {
      if (line ~ /^#{2,6}[[:space:]]+/) {
        match(line, /^#+/)
        return RLENGTH
      }
      return 0
    }
    {
      line = $0
      sub(/\r$/, "", line)
      level = heading_level(line)
      if (level > 0) {
        title = line
        sub(/^#{2,6}[[:space:]]+/, "", title)
        lower = tolower(title)
        if (lower ~ /(^|[^a-z])resolved([^a-z]|$)/ && lower ~ /prior/ && lower ~ /thread/) {
          in_section = 1
          section_level = level
          next
        }
        if (in_section && level <= section_level) {
          in_section = 0
        }
      }
      if (!in_section) next
      # One handle per bullet: strip any list marker, blockquote, and backticks,
      # then take the leading slug token. Over-extracted prose words are harmless
      # because github_resolvable_review_thread_ids_for_handles validates every
      # token against the live thread-handle map before resolving anything.
      token = line
      sub(/^[[:space:]>]*([-*+][[:space:]]+|[0-9]+[.)][[:space:]]+)?/, "", token)
      gsub(/`/, "", token)
      sub(/^[[:space:]]+/, "", token)
      if (match(token, /^[a-z0-9][a-z0-9-]*/)) {
        handle = substr(token, RSTART, RLENGTH)
        sub(/-+$/, "", handle)
        if (handle != "" && !seen[handle]++) print handle
      }
    }
  '
}

secure_install_file() {
  local src="$1"
  local dst="$2"

  mkdir -p "$(dirname "$dst")"
  install -m 600 "$src" "$dst" 2>/dev/null || {
    rm -f "$dst"
    return 1
  }
}

artifact_secret_scan() {
  local file="$1"
  local pattern_file

  if grep -Eq -- '-----BEGIN (RSA |EC |OPENSSH |DSA |)PRIVATE KEY-----' "$file"; then
    printf 'private key material\n'
    return 1
  fi

  pattern_file=$(mktemp)
  cat >"$pattern_file" <<'EOF'
(^|[^A-Za-z0-9_])(GH_TOKEN|GITHUB_TOKEN|GITHUB_PAT|REVIEWER_APP_PRIVATE_KEY_PATH|GEMINI_API_KEY|GOOGLE_API_KEY|GOOGLE_APPLICATION_CREDENTIALS|GOOGLE_CLOUD_PROJECT|GCLOUD_PROJECT|CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|AZURE_CLIENT_SECRET)[[:space:]]*[:=][[:space:]]*['"]?[^[:space:]'",]{3,}
EOF

  if awk '/[[:space:]]*[:=][[:space:]]*['\''"]?\$\{\{/ { next } { print }' "$file" | grep -Eiq -f "$pattern_file"; then
    rm -f "$pattern_file"
    printf 'sensitive credential assignment\n'
    return 1
  fi
  rm -f "$pattern_file"
}

install_secret_scanned_artifact() {
  local src="$1"
  local dst="$2"
  local reason

  if ! reason=$(artifact_secret_scan "$src"); then
    rm -f "$dst"
    log "Refusing to write artifact containing high-confidence secret material: $reason"
    return 1
  fi
  secure_install_file "$src" "$dst" || return 1
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

review_failure_attempts_file() {
  local num="$1"
  local head_sha="$2"

  case "$num" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$head_sha" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac

  printf '%s/review-failure-%s-%s.count\n' "$STATE_DIR" "$num" "$head_sha"
}

review_failure_attempt_count() {
  local file count

  if ! file=$(review_failure_attempts_file "$1" "$2"); then
    printf '0\n'
    return 0
  fi
  if [ ! -f "$file" ]; then
    printf '0\n'
    return 0
  fi
  count=$(cat "$file" 2>/dev/null || printf 0)
  case "$count" in
    ''|*[!0-9]*) count=0 ;;
  esac
  printf '%s\n' "$count"
}

record_review_failure_attempt() {
  local file tmp count

  file=$(review_failure_attempts_file "$1" "$2")
  count=$(review_failure_attempt_count "$1" "$2")
  count=$((count + 1))

  mkdir -p "$STATE_DIR"
  tmp=$(mktemp "$STATE_DIR/review-failure-attempts.XXXXXX")
  printf '%s\n' "$count" >"$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$file"
  printf '%s\n' "$count"
}

clear_review_failure_attempts() {
  local file

  file=$(review_failure_attempts_file "$1" "$2") || return 0
  rm -f "$file"
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
    printf 'GoobReview invalid Antigravity CLI output\n'
    printf 'PR: #%s\n' "$num"
    printf 'Head SHA: %s\n' "$head_sha"
    printf 'Reason: %s\n' "$reason"
    printf 'Captured at: %s\n' "$(date -Is)"
    printf '\n===== REJECTED AGY OUTPUT START =====\n'
    printf '%s\n' "$rejected_output"
    printf '===== REJECTED AGY OUTPUT END =====\n'
  } >"$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$artifact"
  printf '%s\n' "$artifact"
}

# Convert GitHub pull request JSON objects into tab-separated queue rows.
# Keep draft state in-band so the main loop can log draft skips instead of
# filtering them silently in jq.
pull_request_queue_rows() {
  jq -r '[.number, .user.login, .head.sha, (.draft // false), (. | @base64)] | @tsv'
}

pr_has_requested_reviewer() {
  local pr_json="$1"
  local bot_login="$2"
  local bot_author="${3:-}"

  [ -n "$pr_json" ] || return 1
  printf '%s\n' "$pr_json" |
    jq -e --arg bot "$bot_login" --arg bot_author "$bot_author" '
      [
        .requested_reviewers[]? | .login // empty
      ] | any(. == $bot or (. == $bot_author and $bot_author != ""))
    ' >/dev/null
}

reviewer_pr_skip_reason() {
  local num="$1"
  local author="$2"
  local head_sha="$3"
  local draft="$4"
  local bot_login="$5"
  local extra_skip_user="$6"
  local only_pr="$7"
  local bot_author="${8:-}"

  if [ -z "${head_sha:-}" ]; then
    printf 'PR #%s has no head SHA, skipping\n' "$num"
    return 0
  fi
  if [ -n "$only_pr" ] && [ "$num" != "$only_pr" ]; then
    printf 'PR #%s does not match REVIEWER_ONLY_PR=%s, skipping\n' "$num" "$only_pr"
    return 0
  fi
  if [ "$draft" = "true" ]; then
    printf 'PR #%s@%s is a draft, skipping until it is marked ready for review\n' "$num" "$head_sha"
    return 0
  fi
  if [ "$author" = "$bot_login" ] || { [ -n "$bot_author" ] && [ "$author" = "$bot_author" ]; }; then
    printf 'PR #%s@%s is authored by %s, skipping self-review\n' "$num" "$head_sha" "$bot_login"
    return 0
  fi
  if [ -n "$extra_skip_user" ] && [ "$author" = "$extra_skip_user" ]; then
    printf 'PR #%s@%s is authored by REVIEWER_USER=%s, skipping configured reviewer identity\n' "$num" "$head_sha" "$extra_skip_user"
    return 0
  fi

  return 1
}
