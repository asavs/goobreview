#!/usr/bin/env bash
# PR-head worktree helpers. The reviewer never executes code from this tree;
# it only gives Gemini filesystem context while it reads the diff.

review_worktree_slug() {
  printf '%s' "$REPO" | tr '/:' '__' | tr -c 'A-Za-z0-9._-' '_'
}

sanitize_review_worktree_symlinks() {
  local dir="$1"
  local link target rel tmp

  [ -d "$dir" ] || return 0
  while IFS= read -r -d '' link; do
    rel="${link#"$dir"/}"
    target=$(readlink "$link" 2>/dev/null || printf 'unreadable')
    log "Neutralizing symlink in PR-head snapshot: $rel -> $target"
    tmp=$(mktemp "$dir/.goobreview-symlink.XXXXXX")
    {
      printf 'goobreview: symlink metadata only; target content was not read.\n'
      printf 'path: %s\n' "$rel"
      printf 'target: %s\n' "$target"
    } >"$tmp"
    rm -f "$link"
    mv "$tmp" "$link"
  done < <(find "$dir" -type l -print0)
}

prepare_review_worktree() {
  local head_sha="$1"
  local slug dir parent tmp archive extracted

  slug=$(review_worktree_slug)
  parent="${RUNTIME_STATE_DIR:-$STATE_DIR/runtime}/worktrees/$slug"
  case "$head_sha" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  dir="$parent/heads/$head_sha"

  if [ -d "$dir" ]; then
    printf '%s\n' "$dir"
    return 0
  fi

  mkdir -p "$parent/heads"
  tmp=$(mktemp -d "$parent/tmp.XXXXXX")
  archive="$tmp/archive.tar.gz"
  extracted="$tmp/root"
  mkdir -p "$extracted"

  if ! github_api_get "repos/$REPO/tarball/$head_sha" >"$archive" 2>>"$LOG_FILE"; then
    rm -rf "$tmp"
    return 1
  fi

  if ! tar -xzf "$archive" -C "$extracted" --strip-components=1 >>"$LOG_FILE" 2>&1; then
    rm -rf "$tmp"
    return 1
  fi

  sanitize_review_worktree_symlinks "$extracted"

  if ! mv "$extracted" "$dir" 2>>"$LOG_FILE"; then
    rm -rf "$tmp"
    return 1
  fi

  rm -rf "$tmp"
  printf '%s\n' "$dir"
}
