#!/usr/bin/env bash
# Prompt assembly helpers for the reviewer daemon.

build_review_prompt() {
  local num="$1"
  local output_prompt_file="$2"

  {
    cat "$PERSONALITY_FILE"
    printf '\n---\nDiff\n'
    gh pr diff "$num" --repo "$REPO"
    printf '\n---\n'
    cat "$PROMPT_FILE"
  } >"$output_prompt_file"
}
