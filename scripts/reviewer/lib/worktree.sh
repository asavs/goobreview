#!/usr/bin/env bash
# PR-head worktree helpers. The reviewer never executes code from this tree;
# it only gives Gemini filesystem context while it reads the diff.

review_worktree_slug() {
  printf '%s' "$REPO" | tr '/:' '__' | tr -c 'A-Za-z0-9._-' '_'
}

prepare_review_worktree() {
  local head_sha="$1"
  local slug dir parent stamp tmp archive extracted current_head

  slug=$(review_worktree_slug)
  parent="$STATE_DIR/worktrees/$slug"
  dir="$parent/current"
  stamp="$parent/current.head"

  current_head=$(cat "$stamp" 2>/dev/null || true)
  if [ -d "$dir" ] && [ "$current_head" = "$head_sha" ]; then
    printf '%s\n' "$dir"
    return 0
  fi

  mkdir -p "$parent"
  tmp=$(mktemp -d "$parent/tmp.XXXXXX")
  archive="$tmp/archive.tar.gz"
  extracted="$tmp/root"
  mkdir -p "$extracted"

  if ! gh api -H "Accept: application/vnd.github+json" "repos/$REPO/tarball/$head_sha" >"$archive" 2>>"$LOG_FILE"; then
    rm -rf "$tmp"
    return 1
  fi

  if ! tar -xzf "$archive" -C "$extracted" --strip-components=1 >>"$LOG_FILE" 2>&1; then
    rm -rf "$tmp"
    return 1
  fi

  rm -rf "$dir"
  if ! mv "$extracted" "$dir" 2>>"$LOG_FILE"; then
    rm -rf "$tmp"
    return 1
  fi

  printf '%s\n' "$head_sha" >"$stamp"
  rm -rf "$tmp"
  printf '%s\n' "$dir"
}
