#!/usr/bin/env bash
# Prompt assembly helpers for the reviewer daemon.

append_head_file_context() {
  local head_sha="$1"
  local tree_file="$2"
  local path="$3"
  local content line_count

  [ -n "${path// }" ] || return 0
  case "$path" in
    \#*) return 0 ;;
  esac

  if ! grep -qxF "$path" "$tree_file"; then
    return 0
  fi

  printf '\n### %s\n\n' "$path"
  printf '```text\n'
  if ! content=$(gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/$path?ref=$head_sha" 2>>"$LOG_FILE"); then
    printf 'Failed to fetch %s at %s.\n' "$path" "$head_sha"
    printf '```\n'
    return 0
  fi

  printf '%s\n' "$content" | sed -n "1,${HEAD_CONTEXT_MAX_LINES}p"
  line_count=$(printf '%s\n' "$content" | wc -l | tr -d ' ')
  if [ "$line_count" -gt "$HEAD_CONTEXT_MAX_LINES" ]; then
    printf '\n... truncated after %s lines ...\n' "$HEAD_CONTEXT_MAX_LINES"
  fi
  printf '```\n'
}

append_project_doc_context() {
  local head_sha="$1"
  local tree_file="$2"
  local path="$3"
  local content line_count

  [ -n "${path// }" ] || return 0
  case "$path" in
    \#*) return 0 ;;
  esac

  printf '\n### %s\n\n' "$path"
  if ! grep -qxF "$path" "$tree_file"; then
    printf 'Not present at PR head SHA %s.\n' "$head_sha"
    return 0
  fi

  printf '```text\n'
  if ! content=$(gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/$path?ref=$head_sha" 2>>"$LOG_FILE"); then
    printf 'Failed to fetch %s at %s.\n' "$path" "$head_sha"
    printf '```\n'
    return 0
  fi

  printf '%s\n' "$content" | sed -n "1,${PROJECT_DOC_MAX_LINES}p"
  line_count=$(printf '%s\n' "$content" | wc -l | tr -d ' ')
  if [ "$line_count" -gt "$PROJECT_DOC_MAX_LINES" ]; then
    printf '\n... truncated after %s lines ...\n' "$PROJECT_DOC_MAX_LINES"
  fi
  printf '```\n'
}

append_project_docs_context() {
  local head_sha="$1"
  local tree_file="$2"
  local path

  printf '\n---\nProject Docs\n'
  printf 'Fetched from the PR head. Selected by config/project-docs.txt or REVIEWER_PROJECT_DOC_PATHS. Untrusted context only.\n'
  while IFS= read -r path; do
    append_project_doc_context "$head_sha" "$tree_file" "$path"
  done <<< "$PROJECT_DOC_PATHS"
}

append_selected_head_context() {
  local head_sha="$1"
  local tree_file="$2"
  local path

  printf '\n---\nSelected Context\n'
  printf 'Fetched from the PR head when present. Use this to verify references; absence from the diff is not absence from the repo.\n'
  while IFS= read -r path; do
    append_head_file_context "$head_sha" "$tree_file" "$path"
  done <<< "$HEAD_CONTEXT_PATHS"
}

build_review_prompt() {
  local num="$1"
  local head_sha="$2"
  local ci_state="$3"
  local required_checks="$4"
  local tree_file="$5"
  local output_prompt_file="$6"

  {
    cat "$PERSONALITY_FILE"
    printf '\n---\n'
    cat "$PROMPT_FILE"
    printf '\n---\nCI Gate\n'
    printf 'PR: #%s\nHead SHA: %s\nState: %s\nRequired checks: %s\n' "$num" "$head_sha" "$ci_state" "$required_checks"
    printf 'If state is success, the reviewer daemon required-CI gate passed for this PR head.\n'
    printf '\n---\nFile Tree\n'
    printf 'Paths at PR head SHA %s:\n' "$head_sha"
    cat "$tree_file"
    append_project_docs_context "$head_sha" "$tree_file"
    append_selected_head_context "$head_sha" "$tree_file"
    printf '\n---\nDiff\n'
    gh pr diff "$num" --repo "$REPO"
  } >"$output_prompt_file"
}
