#!/usr/bin/env bash
# GitHub REST helpers authenticated with the GitHub App installation token.

github_api_url() {
  printf 'https://api.github.com/%s' "$1"
}

github_api_request() {
  local method="$1"
  local path="$2"
  local accept="${3:-application/vnd.github+json}"
  local data="${4:-}"
  local args=(-fsSL -X "$method")

  if [ -z "${GH_TOKEN:-}" ]; then
    printf 'missing GH_TOKEN for GitHub API request\n' >&2
    return 1
  fi

  args+=(
    -H "Authorization: Bearer $GH_TOKEN"
    -H "Accept: $accept"
    -H "X-GitHub-Api-Version: 2022-11-28"
    -H "User-Agent: goobreview"
  )
  if [ -n "$data" ]; then
    args+=(-H "Content-Type: application/json" --data "$data")
  fi

  curl "${args[@]}" "$(github_api_url "$path")"
}

github_api_get() {
  github_api_request GET "$1" "${2:-application/vnd.github+json}"
}

github_api_post_json() {
  github_api_request POST "$1" "application/vnd.github+json" "$2"
}

github_api_patch_json() {
  github_api_request PATCH "$1" "application/vnd.github+json" "$2"
}

github_api_paginate_array() {
  local path="$1"
  local page=1 sep body count

  while :; do
    case "$path" in
      *\?*) sep="&" ;;
      *) sep="?" ;;
    esac
    body="$(github_api_get "${path}${sep}per_page=100&page=${page}")" || return 1
    count="$(printf '%s' "$body" | jq 'length')"
    [ "$count" -gt 0 ] || break
    printf '%s' "$body" | jq -c '.[]'
    [ "$count" -lt 100 ] && break
    page=$((page + 1))
  done
}

github_check_runs_summary() {
  local head_sha="$1"

  github_api_get "repos/$REPO/commits/$head_sha/check-runs?filter=latest&per_page=100" |
    jq -r '
      .check_runs
      | sort_by(.name, .started_at // .completed_at // "")
      | .[]
      | [.name, .status, (.conclusion // "-")] | @tsv
    '
}
