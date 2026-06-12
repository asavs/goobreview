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

secure_install_file() {
  local src="$1"
  local dst="$2"

  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst" || return 1
  chmod 600 "$dst" 2>/dev/null || {
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

  if grep -Eiq -f "$pattern_file" "$file"; then
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

# Convert GitHub pull request JSON objects into tab-separated queue rows.
# Keep draft state in-band so the main loop can log draft skips instead of
# filtering them silently in jq.
pull_request_queue_rows() {
  jq -r '[.number, .user.login, .head.sha, (.draft // false)] | @tsv'
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
