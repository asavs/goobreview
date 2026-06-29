#!/usr/bin/env bash
# Report local research-artifact capture readiness.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_FILE="$REPO_ROOT/.goobreview-cloud-shell.env"
ENV_FILE="${REVIEWER_ENV_FILE:-$REPO_ROOT/config/reviewer.env}"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/ops.sh"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/vm.sh"
export OPS_LOG_PREFIX="preflight-research"

report=0

usage() {
  cat <<EOF
Usage: bash scripts/preflight/research.sh [--report]

Checks research consent, public/private capture eligibility, and local artifacts.

Options:
  --report   Emit machine-readable key=value output.
  -h, --help Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --report)
      report=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      ops_die "Unknown option: $1"
      ;;
  esac
  shift
done

bool() {
  case "$1" in
    1|true|True|TRUE|yes) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

shell_value() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

print_field() {
  local key="$1" value="$2"
  printf '%s=%s\n' "$key" "$(shell_value "$value")"
}

latest_research_run() {
  local root="$1"
  local candidate latest=""

  if [ ! -d "$root" ]; then
    printf ''
    return 0
  fi

  for candidate in "$root"/*/pr-*; do
    [ -d "$candidate" ] || continue
    latest="$candidate"
  done
  printf '%s' "$latest"
}

repo_visibility_from_github() {
  local repo="$1"
  local token repo_json

  if [ -z "$repo" ] || [ ! -f "$ENV_FILE" ]; then
    printf 'unknown'
    return 0
  fi
  command -v node >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  command -v curl >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'unknown'; return 0; }

  # shellcheck disable=SC1090
  ops_source_env "$ENV_FILE"
  REVIEWER_GITHUB_CONNECT_TIMEOUT="${REVIEWER_GITHUB_CONNECT_TIMEOUT:-5}"
  REVIEWER_GITHUB_MAX_TIME="${REVIEWER_GITHUB_MAX_TIME:-15}"
  REVIEWER_GITHUB_RETRIES="${REVIEWER_GITHUB_RETRIES:-0}"
  export REVIEWER_GITHUB_CONNECT_TIMEOUT REVIEWER_GITHUB_MAX_TIME REVIEWER_GITHUB_RETRIES

  token="$("$REPO_ROOT/scripts/reviewer/get-installation-token.sh" token 2>/dev/null || true)"
  if [ -z "$token" ]; then
    printf 'unknown'
    return 0
  fi

  GH_TOKEN="$token"
  export GH_TOKEN
  # shellcheck disable=SC1091
  . "$REPO_ROOT/scripts/reviewer/lib/github-api.sh"
  repo_json="$(github_api_get "repos/$repo" 2>/dev/null || true)"
  if [ -z "$repo_json" ]; then
    printf 'unknown'
    return 0
  fi
  printf '%s\n' "$repo_json" |
    jq -r 'if has("private") then (if .private then "private" else "public" end) else "unknown" end' 2>/dev/null ||
    printf 'unknown'
}

env_file_present=0
repo=""
posted_personality="none"
research_consent="0"
allow_private="0"
state_dir="${REVIEWER_STATE:-$HOME/.goobreview}"
research_root=""
latest_run=""
latest_manifest=""
research_root_present=0
repo_visibility="unknown"
capture_state="disabled"
recommendation="Set REVIEWER_RESEARCH_CONSENT=1 to retain paired public-repo research artifacts."
upload_state="local-only"
research_scope="local"

if [ -f "$ENV_FILE" ]; then
  env_file_present=1
  repo="$(ops_env_get "$ENV_FILE" REVIEWER_REPO)"
  posted_personality="$(ops_env_get "$ENV_FILE" REVIEWER_POSTED_PERSONALITY)"
  research_consent="$(ops_env_get "$ENV_FILE" REVIEWER_RESEARCH_CONSENT)"
  allow_private="$(ops_env_get "$ENV_FILE" REVIEWER_RESEARCH_ALLOW_PRIVATE)"
  state_from_env="$(ops_env_get "$ENV_FILE" REVIEWER_STATE)"
  [ -z "$posted_personality" ] && posted_personality="none"
  [ -z "$research_consent" ] && research_consent="0"
  [ -z "$allow_private" ] && allow_private="0"
  [ -z "$state_from_env" ] || state_dir="$state_from_env"
fi

if [ -f "$STATE_FILE" ] && command -v gcloud >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  vm_name="${GOOBREVIEW_VM_NAME:-goobreview-1}"
  zone="${GOOBREVIEW_ZONE:-us-central1-a}"
  vm_checkout="${GOOBREVIEW_VM_CHECKOUT:-/opt/goobreview/example}"
  vm_env_path="${GOOBREVIEW_VM_ENV_PATH:-$vm_checkout/config/reviewer.env}"
  if vm_instance_exists "$vm_name" "$zone" && vm_ssh_reachable "$vm_name" "$zone" 15; then
    remote_report="$(vm_remote_preflight_report "$vm_name" "$zone" "$vm_checkout" "$vm_env_path" research 45)"
    if [ -n "$remote_report" ]; then
      research_scope="vm"
      ENV_FILE="$(ops_report_value env_file "$remote_report")"
      env_file_present="$(ops_report_bool_int env_file_present "$remote_report")"
      repo="$(ops_report_value reviewer_repo "$remote_report")"
      posted_personality="$(ops_report_value posted_personality "$remote_report")"
      research_consent="$(ops_report_value research_consent "$remote_report")"
      repo_visibility="$(ops_report_value repo_visibility "$remote_report")"
      capture_state="$(ops_report_value research_capture_state "$remote_report")"
      research_root="$(ops_report_value research_root "$remote_report")"
      research_root_present="$(ops_report_bool_int research_root_present "$remote_report")"
      latest_run="$(ops_report_value latest_research_run "$remote_report")"
      latest_manifest="$(ops_report_value latest_research_manifest "$remote_report")"
      upload_state="$(ops_report_value research_upload_state "$remote_report")"
      recommendation="$(ops_report_value recommendation "$remote_report")"
      if [ "$report" -eq 1 ]; then
        print_field "research_scope" "$research_scope"
        print_field "vm_name" "$vm_name"
        print_field "zone" "$zone"
        print_field "env_file" "$ENV_FILE"
        print_field "env_file_present" "$(bool "$env_file_present")"
        print_field "reviewer_repo" "$repo"
        print_field "posted_personality" "$posted_personality"
        print_field "research_consent" "$research_consent"
        print_field "repo_visibility" "$repo_visibility"
        print_field "research_capture_state" "$capture_state"
        print_field "research_root" "$research_root"
        print_field "research_root_present" "$(bool "$research_root_present")"
        print_field "latest_research_run" "$latest_run"
        print_field "latest_research_manifest" "$latest_manifest"
        print_field "research_upload_state" "$upload_state"
        print_field "recommendation" "$recommendation"
        exit 0
      fi
      cat <<EOF
Research artifact preflight
---------------------------
research source:         VM ($vm_name/$zone)
target repo:             ${repo:-unset}
posted personality:      $posted_personality
research consent:        $(bool "$research_consent")
repo visibility:         $repo_visibility
capture state:           $capture_state
research root:           $research_root
latest research run:     ${latest_run:-none}
latest manifest:         ${latest_manifest:-none}
artifact upload:         $upload_state (bucket export not implemented yet)

Next: $recommendation
EOF
      exit 0
    fi
  fi
fi

research_root="$state_dir/research-runs"
if [ -d "$research_root" ]; then
  research_root_present=1
fi
latest_run="$(latest_research_run "$research_root")"
if [ -n "$latest_run" ] && [ -f "$latest_run/manifest.json" ]; then
  latest_manifest="$latest_run/manifest.json"
fi

case "$research_consent" in
  0)
    capture_state="disabled"
    recommendation="Set REVIEWER_RESEARCH_CONSENT=1 if this public repo may retain paired artifacts."
    ;;
  1)
    case "$posted_personality" in
      none|angry)
        repo_visibility="$(repo_visibility_from_github "$repo")"
        case "$repo_visibility" in
          public)
            capture_state="enabled"
            recommendation="Research capture is enabled for public live reviews. Artifacts remain local in v1."
            ;;
          private)
            if [ "$allow_private" = "1" ]; then
              capture_state="enabled"
              recommendation="Research capture is enabled for this private repo via REVIEWER_RESEARCH_ALLOW_PRIVATE. Artifacts remain local in v1."
            else
              capture_state="disabled-private"
              recommendation="Set REVIEWER_RESEARCH_ALLOW_PRIVATE=1 to capture paired artifacts on this private repo."
            fi
            ;;
          *)
            capture_state="unknown-visibility"
            recommendation="Cannot verify repo visibility; live reviewer will check before capture."
            ;;
        esac
        ;;
      *)
        capture_state="disabled-invalid-personality"
        recommendation="Set REVIEWER_POSTED_PERSONALITY to none or angry."
        ;;
    esac
    ;;
  *)
    capture_state="disabled-invalid-consent"
    recommendation="Set REVIEWER_RESEARCH_CONSENT to 0 or 1."
    ;;
esac

if [ "$report" -eq 1 ]; then
  print_field "research_scope" "$research_scope"
  print_field "env_file" "$ENV_FILE"
  print_field "env_file_present" "$(bool "$env_file_present")"
  print_field "reviewer_repo" "$repo"
  print_field "posted_personality" "$posted_personality"
  print_field "research_consent" "$research_consent"
  print_field "research_allow_private" "$allow_private"
  print_field "repo_visibility" "$repo_visibility"
  print_field "research_capture_state" "$capture_state"
  print_field "research_root" "$research_root"
  print_field "research_root_present" "$(bool "$research_root_present")"
  print_field "latest_research_run" "$latest_run"
  print_field "latest_research_manifest" "$latest_manifest"
  print_field "research_upload_state" "$upload_state"
  print_field "recommendation" "$recommendation"
  exit 0
fi

cat <<EOF
Research artifact preflight
---------------------------
research source:         local
target repo:             ${repo:-unset}
posted personality:      $posted_personality
research consent:        $(bool "$research_consent")
allow private capture:   $(bool "$allow_private")
repo visibility:         $repo_visibility
capture state:           $capture_state
research root:           $research_root
latest research run:     ${latest_run:-none}
latest manifest:         ${latest_manifest:-none}
artifact upload:         $upload_state (bucket export not implemented yet)

Next: $recommendation
EOF
