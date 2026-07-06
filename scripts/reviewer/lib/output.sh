#!/usr/bin/env bash
# Antigravity CLI review-output parsing helpers. Keep the reviewer contract tiny:
# normal markdown review text, then one final GitHub review event line.

review_last_nonempty_line() {
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
      trimmed = line
      sub(/^[[:space:]]+/, "", trimmed)
      sub(/[[:space:]]+$/, "", trimmed)
      if (trimmed != "") last = trimmed
    }
    END { print last }
  '
}

review_verdict_event() {
  local verdict

  verdict=$(review_last_nonempty_line)
  case "$verdict" in
    APPROVE|REQUEST_CHANGES|COMMENT) printf '%s\n' "$verdict" ;;
    *) return 1 ;;
  esac
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

review_demote_oversized_suggestions() {
  local max_lines="${SUGGESTION_MAX_LINES:-12}"

  case "$max_lines" in
    ''|*[!0-9]*) max_lines=12 ;;
  esac

  awk -v max="$max_lines" '
    function flush_suggestion(    i) {
      if (body_n <= max) {
        print "```suggestion"
        for (i = 1; i <= body_n; i++) print body[i]
        print closing
      } else {
        print "```"
        for (i = 1; i <= body_n; i++) print body[i]
        print closing
        printf "[goobreview: suggestion of %d lines exceeds the %d-line cap; shown as a snippet, not an applicable suggestion.]\n", body_n, max
      }
      in_suggestion = 0
      body_n = 0
      delete body
      closing = ""
    }
    {
      line = $0
      check = line
      sub(/\r$/, "", check)
      if (!in_suggestion && check ~ /^```suggestion[[:space:]]*$/) {
        in_suggestion = 1
        body_n = 0
        next
      }
      if (in_suggestion && check ~ /^```[[:space:]]*$/) {
        closing = line
        flush_suggestion()
        next
      }
      if (in_suggestion) {
        body[++body_n] = line
        next
      }
      print line
    }
    END {
      if (in_suggestion) {
        print "```suggestion"
        for (i = 1; i <= body_n; i++) print body[i]
      }
    }
  '
}

# Extract source locations mentioned in ordinary Markdown review prose. The
# reviewer model remains free to write a conventional review; this parser
# merely discovers path:line references that can later be verified against the
# pull request diff and promoted to native GitHub review comments.
#
# Output is one unique path<TAB>start-line<TAB>end-line tuple per line. Single
# line citations repeat the same line in both numeric fields so callers can
# treat every location uniformly.
review_source_locations() {
  local snapshot_root="${1:-}"
  {
    if [ -n "$snapshot_root" ]; then
      local escaped_root
      escaped_root=$(printf '%s' "$snapshot_root" | sed 's/[\\&|]/\\&/g')
      sed -E \
        -e "s|\[[^]]*\]\(file://${escaped_root}/([^)#]*)#L([0-9]+)-L?([0-9]+)[^)]*\)|\1:\2-\3|g" \
        -e "s|\[[^]]*\]\(file://${escaped_root}/([^)#]*)#L([0-9]+)[^)]*\)|\1:\2|g" \
        -e "s|\(file://${escaped_root}/([^)#]*)#L([0-9]+)-L?([0-9]+)[^)]*\)|\1:\2-\3|g" \
        -e "s|\(file://${escaped_root}/([^)#]*)#L([0-9]+)[^)]*\)|\1:\2|g"
    else
      cat
    fi
  } |
    grep -oE '[[:alnum:]_.][[:alnum:]_.+/-]*\.[[:alnum:]_+-]+:[0-9]+(-[0-9]+)?' |
    sed -E 's/:([0-9]+)-([0-9]+)$/\t\1\t\2/; s/:([0-9]+)$/\t\1\t\1/' |
    awk -F '\t' '
      NF == 3 && $1 !~ /(^|\/)\.\.($|\/)/ {
        if ($3 < $2) $3 = $2
        key = $1 FS $2 FS $3
        if (!seen[key]++) print
      }'
}

# Source locations a single finding section anchors to. Explicit
# `Location: path:line` lines win outright: when a section declares any, only
# those are used and heading tokens are ignored (no mixing). As a recovery
# heuristic for reviews that put the citation in the finding heading instead of
# a Location line (e.g. `### Defaults to left in \`client/src/Foo.tsx:31\``), a
# section with no Location line falls back to the LAST path:line token in its
# heading (the section's first line). Prose path:line references inside the body
# are never anchored. Heading-derived locations are validated against the
# snapshot and the PR diff downstream exactly like explicit ones.
review_explicit_source_locations() {
  local snapshot_root="${1:-}"

  awk '
    NR == 1 { heading = $0; sub(/\r$/, "", heading) }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*[Ll]ocation:[[:space:]]*/) {
        sub(/^[[:space:]]*[Ll]ocation:[[:space:]]*/, "", line)
        print line
        have_location = 1
      }
    }
    END {
      if (!have_location && heading != "") {
        rest = heading
        token = ""
        while (match(rest, /[A-Za-z0-9_.\/-]+\.[A-Za-z0-9]+:[0-9]+(-[0-9]+)?/)) {
          token = substr(rest, RSTART, RLENGTH)
          rest = substr(rest, RSTART + RLENGTH)
        }
        if (token != "") print token
      }
    }
  ' | review_source_locations "$snapshot_root"
}

# Emit each Markdown finding section that declares at least one Location line.
# NUL separators preserve the review's original newlines without asking the
# model to serialize a second data format. The caller validates the locations
# against GitHub's diff before it treats a section as an inline comment.
review_markdown_finding_sections() {
  review_demote_oversized_suggestions |
    awk '
    function has_location_line(text,    n, lines, i, line) {
      n = split(text, lines, /\n/)
      for (i = 1; i <= n; i++) {
        line = lines[i]
        sub(/\r$/, "", line)
        if (line ~ /^[[:space:]]*[Ll]ocation:[[:space:]]*[^[:space:]]/) return 1
      }
      return 0
    }
    function heading_has_location(text,    nl, head) {
      nl = index(text, "\n")
      head = (nl > 0) ? substr(text, 1, nl - 1) : text
      sub(/\r$/, "", head)
      return head ~ /[A-Za-z0-9_.\/-]+\.[A-Za-z0-9]+:[0-9]+(-[0-9]+)?/
    }
    function suggestion_fences_balanced(text,    n, lines, i, line, in_suggestion) {
      n = split(text, lines, /\n/)
      in_suggestion = 0
      for (i = 1; i <= n; i++) {
        line = lines[i]
        sub(/\r$/, "", line)
        if (!in_suggestion && line ~ /^```suggestion[[:space:]]*$/) {
          in_suggestion = 1
          continue
        }
        if (in_suggestion && line ~ /^```[[:space:]]*$/) {
          in_suggestion = 0
        }
      }
      return !in_suggestion
    }
    function emit() {
      if (in_section &&
          (has_location_line(section) || heading_has_location(section)) &&
          suggestion_fences_balanced(section)) {
        printf "%s%c", section, 0
      }
    }
    /^#{1,6}[[:space:]]+/ {
      emit()
      section = $0 ORS
      in_section = 1
      next
    }
    in_section { section = section $0 ORS }
    END { emit() }
  '
}

# Strip finding sections from the review body that were promoted to native
# GitHub inline comments, so the same text does not appear twice in the posted
# review (once anchored and once in the top-level prose).
review_body_without_promoted_sections() {
  local inline_json="$1"
  local count promoted_headings_file

  count=$(printf '%s' "$inline_json" | jq 'length' 2>/dev/null) || count=0
  if [ "${count:-0}" -eq 0 ]; then
    cat
    return
  fi

  promoted_headings_file=$(mktemp)
  printf '%s' "$inline_json" | jq -r '.[].body | split("\n")[0]' >"$promoted_headings_file" 2>/dev/null || true

  awk -v hf="$promoted_headings_file" '
    BEGIN {
      while ((getline h < hf) > 0) skip[h] = 1
      close(hf)
      in_skip = 0
    }
    { sub(/\r$/, "") }
    /^#{1,6}[[:space:]]+/ {
      if ($0 in skip) { in_skip = 1; next }
      in_skip = 0
      print; next
    }
    !in_skip { print }
  '
  rm -f "$promoted_headings_file"
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

# Extract still-open thread replies from the review body. Returns one
# handle<TAB>reply-body pair per line for each bullet in the "Unresolved Prior
# Threads" section. The caller maps handles to thread IDs and posts the reply.
review_unresolved_thread_replies() {
  awk '
    function heading_level(line) {
      if (line ~ /^#{2,6}[[:space:]]+/) {
        match(line, /^#+/)
        return RLENGTH
      }
      return 0
    }
    {
      sub(/\r$/, "")
      level = heading_level($0)
      if (level > 0) {
        title = $0
        sub(/^#{2,6}[[:space:]]+/, "", title)
        lower = tolower(title)
        in_section = (lower ~ /(^|[^a-z])unresolved([^a-z]|$)/ && lower ~ /prior/ && lower ~ /thread/)
        section_level = level
        next
      }
      if (!in_section) next
      token = $0
      sub(/^[[:space:]>]*([-*+][[:space:]]+|[0-9]+[.)][[:space:]]+)?/, "", token)
      gsub(/`/, "", token)
      sub(/^[[:space:]]+/, "", token)
      if (match(token, /^[a-z0-9][a-z0-9-]*/)) {
        handle = substr(token, RSTART, RLENGTH)
        sub(/-+$/, "", handle)
        rest = substr(token, RSTART + RLENGTH)
        sub(/^[[:space:]]*[-—:][[:space:]]*/, "", rest)
        if (handle != "" && !seen[handle]++) printf "%s\t%s\n", handle, rest
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

  # The value must be a literal credential: reject assignments, but treat a
  # value beginning with '$' as a variable/expression reference, not a secret
  # (e.g. GitHub Actions `${{ secrets.GITHUB_TOKEN }}` or shell `$GH_TOKEN`),
  # which would otherwise false-positive on every workflow-touching diff.
  pattern_file=$(mktemp)
  cat >"$pattern_file" <<'EOF'
(^|[^A-Za-z0-9_])(GH_TOKEN|GITHUB_TOKEN|GITHUB_PAT|REVIEWER_APP_PRIVATE_KEY_PATH|GEMINI_API_KEY|GOOGLE_API_KEY|GOOGLE_APPLICATION_CREDENTIALS|GOOGLE_CLOUD_PROJECT|GCLOUD_PROJECT|CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|AZURE_CLIENT_SECRET)[[:space:]]*[:=][[:space:]]*['"]?[^[:space:]'",$][^[:space:]'",]{2,}
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

# Cap an assembled artifact at max_bytes (appending a legible truncation
# marker naming the artifact kind), then secret-scan and install it at dst
# with mode 0600. Consumes src: it is removed on success and failure alike.
install_bounded_scanned_artifact() {
  local src="$1"
  local dst="$2"
  local max_bytes="$3"
  local label="$4"
  local bytes marker marker_bytes body_bytes truncated status=0

  bytes=$(wc -c <"$src" | tr -d ' ')
  if [ "$bytes" -gt "$max_bytes" ]; then
    marker=$(printf '\n\n[goobreview: %s truncated after %s bytes]\n' "$label" "$max_bytes")
    marker_bytes=$(printf '%s' "$marker" | wc -c | tr -d ' ')
    body_bytes=$((max_bytes - marker_bytes))
    [ "$body_bytes" -gt 0 ] || body_bytes=0
    truncated="$src.truncated"
    head -c "$body_bytes" "$src" >"$truncated"
    printf '%s' "$marker" | head -c $((max_bytes - body_bytes)) >>"$truncated"
    install_secret_scanned_artifact "$truncated" "$dst" || status=1
    rm -f "$truncated"
  else
    install_secret_scanned_artifact "$src" "$dst" || status=1
  fi
  rm -f "$src"
  return "$status"
}

# Per-PR-head retry counters, one file family per kind ("review-failure" for
# expensive-step failures, "invalid-verdict" for unparseable model output).
# The on-disk names ($STATE_DIR/<kind>-<num>-<sha>.count) predate this helper,
# so deployed state directories keep counting across upgrades.
review_attempts_file() {
  local kind="$1"
  local num="$2"
  local head_sha="$3"

  case "$num" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$head_sha" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac

  printf '%s/%s-%s-%s.count\n' "$STATE_DIR" "$kind" "$num" "$head_sha"
}

review_attempts_count() {
  local file count

  if ! file=$(review_attempts_file "$1" "$2" "$3") || [ ! -f "$file" ]; then
    printf '0\n'
    return 0
  fi

  IFS= read -r count <"$file" || count=0
  case "$count" in
    ''|*[!0-9]*) count=0 ;;
  esac
  printf '%s\n' "$count"
}

review_attempts_record() {
  local file tmp count

  file=$(review_attempts_file "$1" "$2" "$3")
  count=$(review_attempts_count "$1" "$2" "$3")
  count=$((count + 1))

  mkdir -p "$STATE_DIR"
  tmp=$(mktemp "$STATE_DIR/attempt-counter.XXXXXX")
  printf '%s\n' "$count" >"$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$file"
  printf '%s\n' "$count"
}

review_attempts_clear() {
  local file

  file=$(review_attempts_file "$1" "$2" "$3") || return 0
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

review_trace_paths_to_links() {
  local head_sha="${1:-}"
  local repo="${2:-}"
  local worktree_dir="${3:-}"
  local path_index=""
  local has_idx=0

  if [ -n "$worktree_dir" ] && [ -d "$worktree_dir" ]; then
    path_index=$(mktemp)
    find "$worktree_dir" -type f | sed "s|^$worktree_dir/||" | sort > "$path_index"
    has_idx=1
  fi

  awk -v head_sha="$head_sha" -v repo="$repo" \
      -v path_idx="${path_index:-}" \
      -v has_idx="$has_idx" '
BEGIN {
  if (has_idx && path_idx != "") {
    while ((getline p < path_idx) > 0) paths[p] = 1
    close(path_idx)
  }
}
{
  print linkify($0)
}
function linkify(s,    result, rest, token, tok_start, tok_len, quoted, path, frag, url) {
  if (repo == "" || head_sha == "" || !has_idx) return s
  result = ""
  rest = s
  while (match(rest, /`[^`]+`/)) {
    tok_start = RSTART
    tok_len = RLENGTH
    token = substr(rest, tok_start, tok_len)
    quoted = substr(token, 2, length(token) - 2)
    path = quoted
    # Preserve the cited line (or range) as a GitHub blob fragment so links land
    # on the finding, not the top of the file. match() clobbers RSTART/RLENGTH,
    # so the enclosing token span is captured in tok_start/tok_len above.
    frag = ""
    if (match(quoted, /:[0-9]+-[0-9]+$/)) {
      frag = "#L" substr(quoted, RSTART + 1)
      sub(/-/, "-L", frag)
    } else if (match(quoted, /:[0-9]+$/)) {
      frag = "#L" substr(quoted, RSTART + 1)
    }
    gsub(/:[0-9]+(-[0-9]+)?$/, "", path)
    result = result substr(rest, 1, tok_start - 1)
    if (path in paths) {
      url = "https://github.com/" repo "/blob/" head_sha "/" path frag
      result = result "[" sprintf("`%s`", quoted) "](" url ")"
    } else {
      result = result token
    }
    rest = substr(rest, tok_start + tok_len)
  }
  return result rest
}
'

  if [ "$has_idx" -eq 1 ]; then
    rm -f "$path_index"
  fi
}

review_trace_details_block() {
  local trace_file="$1" head_sha="${2:-}" repo="${3:-}" worktree_dir="${4:-}"

  [ -s "$trace_file" ] || return 1
  printf '<details><summary>Review trace</summary>\n\n'
  review_trace_paths_to_links "$head_sha" "$repo" "$worktree_dir" <"$trace_file"
  printf '\n</details>\n\n---\n\n'
}

# Prefixes a rendered review_trace_details_block onto the review body.
# Callers capture that block via command substitution, which strips its
# trailing blank lines, so trace_block always arrives ending in a bare "---"
# with no newline after it -- concatenating it directly onto the body glues
# the horizontal rule to the body's first line. This reinserts the blank
# line the caller's command substitution ate.
review_body_with_trace_prefix() {
  local trace_block="$1" body="$2"
  printf '%s\n\n%s\n' "$trace_block" "$body"
}

# Detect a leading review-trace block — consecutive lines at the top of the
# body where the model narrates its file-inspection plan ("I will check ...",
# "I will view `path.ts` ...") — and wrap them in a <details> block with a
# horizontal-rule separator, so the actual review body begins cleanly.
#
# Optional: pass head_sha, repo, and worktree_dir to convert backtick-quoted
# paths that exist in the PR-head snapshot into clickable GitHub blob links.
#
# Reads stdin, writes stdout. Passes through unchanged if no trace detected.
review_trace_to_details() {
  local head_sha="${1:-}"
  local repo="${2:-}"
  local worktree_dir="${3:-}"
  local path_index=""
  local has_idx=0

  if [ -n "$worktree_dir" ] && [ -d "$worktree_dir" ]; then
    path_index=$(mktemp)
    find "$worktree_dir" -type f | sed "s|^$worktree_dir/||" | sort > "$path_index"
    has_idx=1
  fi

  awk -v head_sha="$head_sha" -v repo="$repo" \
      -v path_idx="${path_index:-}" \
      -v has_idx="$has_idx" '
BEGIN {
  if (has_idx && path_idx != "") {
    while ((getline p < path_idx) > 0) paths[p] = 1
    close(path_idx)
  }
  state = 0
  n = 0
  trace_n = 0
}
{
  gsub(/\r$/, "")
  if (state == 2) { print; next }

  trimmed = $0
  sub(/^[[:space:]]+/, "", trimmed)
  if (trimmed == "") {
    if (state == 1) lines[n++] = $0
    else print
    next
  }

  if (state == 0) {
    if (is_trace_line(trimmed)) {
      state = 1
      lines[n++] = $0
      trace_n++
    } else {
      state = 2
      print
    }
  } else {
    if (is_trace_line(trimmed)) {
      lines[n++] = $0
      trace_n++
    } else {
      emit_details()
      state = 2
      print
    }
  }
}
END {
  if (state == 1) emit_details()
}

function is_trace_line(s) {
  lower = tolower(s)

  if (lower ~ /^i (will|am going to)[[:space:]]/) return 1
  if (lower ~ /^i'\''(ll|m going to)[[:space:]]/) return 1
  if (lower ~ /^(i want to|i need to|i have to|i should |i can |i start|i begin|first,? i)[[:space:]]/) return 1
  if (lower ~ /^let me[[:space:]]/) return 1
  return 0
}

function linkify(s,    result, rest, token, tok_start, tok_len, quoted, path, frag, url) {
  if (repo == "" || head_sha == "" || !has_idx) return s
  result = ""
  rest = s
  while (match(rest, /`[^`]+`/)) {
    tok_start = RSTART
    tok_len = RLENGTH
    token = substr(rest, tok_start, tok_len)
    quoted = substr(token, 2, length(token) - 2)
    path = quoted
    # Preserve the cited line (or range) as a GitHub blob fragment so links land
    # on the finding, not the top of the file. match() clobbers RSTART/RLENGTH,
    # so the enclosing token span is captured in tok_start/tok_len above.
    frag = ""
    if (match(quoted, /:[0-9]+-[0-9]+$/)) {
      frag = "#L" substr(quoted, RSTART + 1)
      sub(/-/, "-L", frag)
    } else if (match(quoted, /:[0-9]+$/)) {
      frag = "#L" substr(quoted, RSTART + 1)
    }
    gsub(/:[0-9]+(-[0-9]+)?$/, "", path)
    result = result substr(rest, 1, tok_start - 1)
    if (path in paths) {
      url = "https://github.com/" repo "/blob/" head_sha "/" path frag
      result = result "[" sprintf("`%s`", quoted) "](" url ")"
    } else {
      result = result token
    }
    rest = substr(rest, tok_start + tok_len)
  }
  return result rest
}

function emit_details() {
  if (trace_n >= 2) {
    print "<details>"
    print "<summary>Review trace</summary>"
    print ""
    for (i = 0; i < n; i++) print linkify(lines[i])
    print ""
    print "</details>"
    print "---"
    print ""
  } else {
    for (i = 0; i < n; i++) print lines[i]
  }
}
'

  if [ "$has_idx" -eq 1 ]; then
    rm -f "$path_index"
  fi
}

# Compact human-readable duration for the review footer: "42s", "4m12s".
format_agy_duration() {
  local s="${1:-0}"
  case "$s" in
    ''|*[!0-9]*) s=0 ;;
  esac
  if [ "$s" -ge 60 ]; then
    printf '%dm%02ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}

# Provenance footer appended to every posted review body. The engine segment
# is omitted when the checkout SHA is unavailable (e.g. non-git test copies).
review_footer_note() {
  local model="$1" elapsed_s="$2" engine_sha="$3"
  local engine=""
  if [ -n "$engine_sha" ] && [ "$engine_sha" != "unknown" ]; then
    engine=" [\`$engine_sha\`](https://github.com/asavs/goobreview/commit/$engine_sha)"
  fi
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the footer.
  printf '*Drafted autonomously by %s in %s via goobreview antigravity-cli%s.*\n' \
    "$model" "$(format_agy_duration "$elapsed_s")" "$engine"
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
