#!/usr/bin/env bash
# GitHub REST helpers authenticated with the GitHub App installation token.

GITHUB_API_CONNECT_TIMEOUT_DEFAULT=10
GITHUB_API_MAX_TIME_DEFAULT=60
GITHUB_API_RETRIES_DEFAULT=2
GITHUB_API_RETRY_SLEEP_DEFAULT=1

github_api_url() {
  printf 'https://api.github.com/%s' "$1"
}

github_api_log_snippet() {
  local file="$1"
  local snippet

  if [ ! -s "$file" ]; then
    printf '<empty>'
    return 0
  fi

  snippet=$(LC_ALL=C tr '\r\n' '  ' <"$file" | cut -c 1-500)
  if [ -n "${GH_TOKEN:-}" ]; then
    snippet=${snippet//${GH_TOKEN}/[REDACTED]}
  fi
  printf '%s' "$snippet"
}

github_api_retryable_method() {
  case "$1" in
    GET|HEAD|OPTIONS) return 0 ;;
    *) return 1 ;;
  esac
}

github_api_retryable_status() {
  case "$1" in
    403|429|500|502|503|504) return 0 ;;
    *) return 1 ;;
  esac
}

github_api_request() {
  local method="$1"
  local path="$2"
  local accept="${3:-application/vnd.github+json}"
  local data="${4:-}"
  local connect_timeout="${REVIEWER_GITHUB_CONNECT_TIMEOUT:-$GITHUB_API_CONNECT_TIMEOUT_DEFAULT}"
  local max_time="${REVIEWER_GITHUB_MAX_TIME:-$GITHUB_API_MAX_TIME_DEFAULT}"
  local retries="${REVIEWER_GITHUB_RETRIES:-$GITHUB_API_RETRIES_DEFAULT}"
  local retry_sleep="${REVIEWER_GITHUB_RETRY_SLEEP:-$GITHUB_API_RETRY_SLEEP_DEFAULT}"
  local args=(-sS -L -X "$method")
  local url attempt max_attempts body_file err_file headers_file http_status curl_status snippet err_snippet errexit_was_set

  if [ -z "${GH_TOKEN:-}" ]; then
    printf 'missing GH_TOKEN for GitHub API request\n' >&2
    return 1
  fi

  args+=(
    --connect-timeout "$connect_timeout"
    --max-time "$max_time"
    -H "Authorization: Bearer $GH_TOKEN"
    -H "Accept: $accept"
    -H "X-GitHub-Api-Version: 2022-11-28"
    -H "User-Agent: goobreview"
  )
  if [ -n "$data" ]; then
    args+=(-H "Content-Type: application/json" --data "$data")
  fi

  url="$(github_api_url "$path")"
  max_attempts=$((retries + 1))
  attempt=1

  while [ "$attempt" -le "$max_attempts" ]; do
    body_file=$(mktemp)
    err_file=$(mktemp)
    headers_file=$(mktemp)
    case $- in *e*) errexit_was_set=1 ;; *) errexit_was_set=0 ;; esac
    set +e
    http_status=$(curl "${args[@]}" -D "$headers_file" -o "$body_file" -w '%{http_code}' "$url" 2>"$err_file")
    curl_status=$?
    if [ "$errexit_was_set" -eq 1 ]; then set -e; fi

    case "$http_status" in
      [0-9][0-9][0-9]) ;;
      *) http_status="000" ;;
    esac

    if [ "$curl_status" -eq 0 ] && [ "$http_status" -ge 200 ] && [ "$http_status" -lt 300 ]; then
      cat "$body_file"
      rm -f "$body_file" "$err_file" "$headers_file"
      return 0
    fi

    snippet=$(github_api_log_snippet "$body_file")
    err_snippet=$(github_api_log_snippet "$err_file")
    printf 'GitHub API %s %s failed (attempt %s/%s, curl=%s, http=%s): %s; response: %s\n' \
      "$method" "$path" "$attempt" "$max_attempts" "$curl_status" "${http_status:-000}" "$err_snippet" "$snippet" >&2

    rm -f "$body_file" "$err_file" "$headers_file"

    if [ "$attempt" -ge "$max_attempts" ]; then
      return 1
    fi
    if [ "$curl_status" -ne 0 ]; then
      github_api_retryable_method "$method" || return 1
    elif ! github_api_retryable_method "$method" || ! github_api_retryable_status "$http_status"; then
      return 1
    fi

    sleep "$retry_sleep"
    attempt=$((attempt + 1))
  done

  return 1
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

github_check_runs_json() {
  local head_sha="$1"
  local page=1 body count total_count=-1 fetched=0 complete=0 pages_file

  pages_file=$(mktemp)
  while :; do
    if ! body=$(github_api_get "repos/$REPO/commits/$head_sha/check-runs?filter=latest&per_page=100&page=$page"); then
      printf 'GitHub check-runs pagination failed for %s after %s complete page(s); required-check data is incomplete\n' "$head_sha" $((page - 1)) >&2
      rm -f "$pages_file"
      return 1
    fi

    if ! count=$(printf '%s' "$body" | jq -e '.check_runs | length'); then
      printf 'GitHub check-runs response for %s page %s did not contain a check_runs array\n' "$head_sha" "$page" >&2
      rm -f "$pages_file"
      return 1
    fi

    printf '%s\n' "$body" >>"$pages_file"
    fetched=$((fetched + count))
    if [ "$total_count" -lt 0 ]; then
      total_count=$(printf '%s' "$body" | jq -r '.total_count // -1')
      case "$total_count" in
        ''|*[!0-9-]*) total_count=-1 ;;
      esac
    fi

    if [ "$total_count" -ge 0 ] && [ "$fetched" -ge "$total_count" ]; then
      complete=1
      break
    fi
    if [ "$count" -lt 100 ]; then
      complete=1
      break
    fi
    page=$((page + 1))
  done

  jq -s --argjson complete "$complete" --argjson fetched "$fetched" --argjson pages "$page" '
    {
      total_count: ((.[0].total_count // $fetched) | tonumber),
      fetched_count: $fetched,
      pages_fetched: $pages,
      complete: ($complete == 1),
      check_runs: [.[].check_runs[]]
    }
  ' "$pages_file"
  rm -f "$pages_file"
}

github_check_runs_summary() {
  local head_sha="$1"
  local limit="${REVIEWER_CHECK_RUN_SUMMARY_LIMIT:-200}"

  github_check_runs_json "$head_sha" |
    jq -r --argjson limit "$limit" '
      . as $root
      | ($root.check_runs | sort_by(.name, .started_at // .completed_at // "")) as $runs
      | ($runs | length) as $count
      | "Check-run data: " + (if $root.complete then "complete" else "incomplete" end) + " (fetched " + ($root.fetched_count|tostring) + " of " + ($root.total_count|tostring) + " across " + ($root.pages_fetched|tostring) + " page(s))"
      , if $count > $limit then
          "Showing first " + ($limit|tostring) + " of " + ($count|tostring) + " check runs; summary intentionally truncated."
        else
          "Showing all " + ($count|tostring) + " check runs."
        end
      , ($runs[:$limit][] | [.name, .status, (.conclusion // "-")] | @tsv)
    '
}
