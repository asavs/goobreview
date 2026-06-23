#!/usr/bin/env bash
# Mint a GitHub App installation access token and fetch the App's slug, caching
# both on disk until shortly before expiry. Prints the requested field to stdout
# based on argv[1]:
#   token (default)   installation access token
#   slug              the App's slug
#   discover OWNER/REPO   installation ID for that repo
#   discover-target       JSON {repo, installation_id} for the single installed repo
#
# token/slug are cached in $REVIEWER_STATE/app_token.json and refreshed when
# fewer than 5 minutes remain. Inputs come from REVIEWER_* environment vars:
#   REVIEWER_APP_ID, REVIEWER_APP_INSTALLATION_ID, REVIEWER_APP_PRIVATE_KEY_PATH,
#   REVIEWER_STATE, REVIEWER_GITHUB_FETCH_TIMEOUT (seconds, default 60).
#
# Pure shell: openssl signs the RS256 JWT, curl talks to the API, jq parses.
# No Node runtime required on the VM.
set -euo pipefail

REFRESH_BEFORE_EXPIRY=300
TIMEOUT="${REVIEWER_GITHUB_FETCH_TIMEOUT:-60}"
API="https://api.github.com"
UA="goobreview-app-token"

die() { printf '[app-token] %s\n' "$1" >&2; exit 1; }

# base64url: single line, +/ -> -_, strip padding.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Sign an RS256 JWT (iat-30s for clock skew, 9-min expiry, iss=App ID).
make_jwt() {
  local now header payload signing_input signature
  now=$(date +%s)
  header='{"alg":"RS256","typ":"JWT"}'
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 30))" "$((now + 540))" "$APP_ID")
  signing_input="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
  signature=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$KEY_PATH" -binary | b64url)
  printf '%s.%s' "$signing_input" "$signature"
}

http_guidance() { # $1=status $2=operation
  case "$1" in
    401) printf '\nNext action: verify REVIEWER_APP_ID belongs to the downloaded private key, then re-upload or re-paste the matching .pem.' ;;
    404)
      if [ "$2" = "mint-installation-token" ]; then
        printf '\nNext action: verify REVIEWER_APP_INSTALLATION_ID is the installation for this App and target repository, then re-run scripts/configure.sh.'
      else
        printf '\nNext action: verify the App is installed on the target repository and re-run scripts/configure.sh to rediscover the installation ID.'
      fi
      ;;
  esac
}

# gh_request METHOD PATH AUTH OPERATION -> response body on stdout, or die.
gh_request() {
  local method="$1" path="$2" auth="$3" operation="$4" tmp status body
  tmp=$(mktemp)
  status=$(curl -sS --max-time "$TIMEOUT" -X "$method" -o "$tmp" -w '%{http_code}' \
    -H "Authorization: $auth" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "User-Agent: $UA" \
    "$API$path") || { rm -f "$tmp"; die "$operation: request to $path failed (network or ${TIMEOUT}s timeout)"; }
  body=$(cat "$tmp"); rm -f "$tmp"
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    die "$operation failed ($status): $(printf '%s' "$body" | head -c 500)$(http_guidance "$status" "$operation")"
  fi
  printf '%s' "$body"
}

mint_installation_token() { # $1=installation id -> token JSON
  gh_request POST "/app/installations/$1/access_tokens" "Bearer $JWT" "mint-installation-token"
}

# --- shared env contract ---
APP_ID="${REVIEWER_APP_ID:-}"; [ -n "$APP_ID" ] || die "missing required env: REVIEWER_APP_ID"
KEY_PATH="${REVIEWER_APP_PRIVATE_KEY_PATH:-}"; [ -n "$KEY_PATH" ] || die "missing required env: REVIEWER_APP_PRIVATE_KEY_PATH"
[ -f "$KEY_PATH" ] || die "private key not found: $KEY_PATH"

WHAT="${1:-token}"

case "$WHAT" in
  token | slug)
    INST="${REVIEWER_APP_INSTALLATION_ID:-}"; [ -n "$INST" ] || die "missing required env: REVIEWER_APP_INSTALLATION_ID"
    STATE="${REVIEWER_STATE:-}"; [ -n "$STATE" ] || die "missing required env: REVIEWER_STATE"
    mkdir -p "$STATE"
    CACHE="$STATE/app_token.json"

    # Serve from cache when it matches this App+installation and has >5 min left.
    if [ -f "$CACHE" ]; then
      cached=$(jq -c --arg a "$APP_ID" --arg i "$INST" \
        --argjson now "$(date +%s)" --argjson skew "$REFRESH_BEFORE_EXPIRY" '
        if (.app_id == $a and .installation_id == $i
            and (.token | type == "string") and (.slug | type == "string")
            and ((.expires_at // 0) - $now) >= $skew)
        then {token, slug} else empty end' "$CACHE" 2>/dev/null || true)
      if [ -n "$cached" ]; then
        printf '%s' "$(printf '%s' "$cached" | jq -r --arg w "$WHAT" 'if $w == "slug" then .slug else .token end')"
        exit 0
      fi
    fi

    JWT=$(make_jwt)
    slug=$(gh_request GET /app "Bearer $JWT" "get-app-json" | jq -r '.slug // empty')
    [ -n "$slug" ] || die "unexpected /app response: missing slug"

    token_json=$(mint_installation_token "$INST")
    token=$(printf '%s' "$token_json" | jq -r '.token // empty')
    expires_at=$(printf '%s' "$token_json" | jq -r '.expires_at // empty')
    if [ -z "$token" ] || [ -z "$expires_at" ]; then
      die "unexpected token response: missing token/expires_at"
    fi
    expires_epoch=$(date -d "$expires_at" +%s)

    ( umask 077
      jq -nc --arg a "$APP_ID" --arg i "$INST" --arg s "$slug" \
        --arg t "$token" --argjson e "$expires_epoch" \
        '{app_id: $a, installation_id: $i, slug: $s, token: $t, expires_at: $e}' > "$CACHE" )

    if [ "$WHAT" = slug ]; then printf '%s' "$slug"; else printf '%s' "$token"; fi
    ;;

  discover)
    target="${2:-}"
    [[ "$target" =~ ^[^/]+/[^/]+$ ]] || die "usage: get-installation-token.sh discover OWNER/REPO"
    JWT=$(make_jwt)
    id=$(gh_request GET "/repos/$target/installation" "Bearer $JWT" "get-repo-installation" | jq -r '.id // empty')
    [[ "$id" =~ ^[0-9]+$ ]] || die "unexpected /installation response: missing numeric id"
    printf '%s' "$id"
    ;;

  discover-target)
    JWT=$(make_jwt)
    constrained="${REVIEWER_APP_INSTALLATION_ID:-}"
    if [ -n "$constrained" ]; then
      [[ "$constrained" =~ ^[0-9]+$ ]] || die "REVIEWER_APP_INSTALLATION_ID must be numeric; got '$constrained'"
      installation_ids="$constrained"
    else
      installations=$(gh_request GET "/app/installations?per_page=100" "Bearer $JWT" "list-installations")
      printf '%s' "$installations" | jq -e 'type == "array"' >/dev/null \
        || die "unexpected /app/installations response"
      installation_ids=$(printf '%s' "$installations" | jq -r '.[].id')
    fi

    candidates="[]"
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      token=$(mint_installation_token "$id" | jq -r '.token // empty')
      [ -n "$token" ] || die "no token minted for installation $id"
      repos=$(gh_request GET "/installation/repositories?per_page=100" "Bearer $token" "list-installation-repositories")
      printf '%s' "$repos" | jq -e '.repositories | type == "array"' >/dev/null \
        || die "unexpected /installation/repositories response"
      total=$(printf '%s' "$repos" | jq -r '.total_count // 0')
      returned=$(printf '%s' "$repos" | jq -r '.repositories | length')
      if [ "$total" -gt "$returned" ]; then
        die "installation $id exposes $total repositories; set REVIEWER_REPO or pass --repo"
      fi
      candidates=$(printf '%s' "$repos" | jq -c --argjson acc "$candidates" --arg id "$id" '
        $acc + [.repositories[] | select(.full_name | type == "string")
                | {repo: .full_name, installation_id: $id}]')
    done <<< "$installation_ids"

    result=$(printf '%s' "$candidates" | jq -c 'unique_by(.installation_id + ":" + .repo)')
    count=$(printf '%s' "$result" | jq 'length')
    if [ "$count" -eq 0 ]; then
      die "no repositories found for this GitHub App installation"
    fi
    if [ "$count" -gt 1 ]; then
      preview=$(printf '%s' "$result" | jq -r '
        ([.[0:10][].repo] | join(", "))
        + (if length > 10 then ", ... (+\(length - 10) more)" else "" end)')
      die "multiple repositories found ($preview); set REVIEWER_REPO or pass --repo"
    fi
    printf '%s' "$result" | jq -cj '.[0]'
    ;;

  *)
    die "unknown query: $WHAT; expected 'token', 'slug', 'discover', or 'discover-target'"
    ;;
esac
