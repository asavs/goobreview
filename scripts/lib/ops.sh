#!/usr/bin/env bash
# Shared helpers for setup/ops scripts. Source after `set -euo pipefail`.

ops_script_dir() {
  local source_path="$1"
  cd "$(dirname "$source_path")" && pwd
}

ops_repo_root() {
  local script_dir="$1"
  cd "$script_dir/.." && pwd
}

ops_log() {
  printf '[%s] %s\n' "${OPS_LOG_PREFIX:-goobreview}" "$*"
}

ops_warn() {
  printf '[%s] Warning: %s\n' "${OPS_LOG_PREFIX:-goobreview}" "$*" >&2
}

ops_die() {
  printf '[%s] ERROR: %s\n' "${OPS_LOG_PREFIX:-goobreview}" "$*" >&2
  exit 1
}

ops_require_command() {
  local name="$1" hint="${2:-}"
  if ! command -v "$name" >/dev/null 2>&1; then
    if [ -n "$hint" ]; then
      ops_die "$name not found. $hint"
    fi
    ops_die "$name not found."
  fi
}

ops_require_file() {
  local path="$1" hint="${2:-}"
  if [ ! -f "$path" ]; then
    if [ -n "$hint" ]; then
      ops_die "Missing $path. $hint"
    fi
    ops_die "Missing $path."
  fi
}

ops_require_executable() {
  local path="$1" hint="${2:-}"
  if [ ! -x "$path" ]; then
    if [ -n "$hint" ]; then
      ops_die "Missing $path (or not executable). $hint"
    fi
    ops_die "Missing $path (or not executable)."
  fi
}

ops_require_nonempty() {
  local name="$1" value="$2" hint="${3:-}"
  if [ -z "$value" ]; then
    if [ -n "$hint" ]; then
      ops_die "$name is required. $hint"
    fi
    ops_die "$name is required."
  fi
}

ops_require_envs() {
  local name
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then
      ops_die "Missing required env: $name. Run scripts/configure.sh first."
    fi
  done
}

ops_validate_uint() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*)
      ops_die "$name must be numeric; got '$value'."
      ;;
  esac
}

ops_validate_owner_repo() {
  local value="$1" name="${2:-REVIEWER_REPO}"
  case "$value" in
    */*)
      if [ "${value#*/}" = "" ] || [ "${value%/*}" = "" ] || [ "${value#*/*/}" != "$value" ]; then
        ops_die "$name must be in owner/repo form; got '$value'."
      fi
      ;;
    *)
      ops_die "$name must be in owner/repo form; got '$value'."
      ;;
  esac
}

ops_prompt() {
  local question="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -r -p "$question [$default]: " reply
    printf '%s' "${reply:-$default}"
  else
    read -r -p "$question: " reply
    printf '%s' "$reply"
  fi
}

ops_confirm() {
  local question="$1" reply
  read -r -p "$question [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

ops_copy_if_missing() {
  local target="$1" example="$2"
  if [ -f "$target" ]; then
    ops_log "$(basename "$target") already exists; leaving in place."
    return 0
  fi
  if [ ! -f "$example" ]; then
    ops_warn "Example $(basename "$example") missing; skipping $(basename "$target")."
    return 1
  fi
  cp "$example" "$target"
  ops_log "Created $(basename "$target") from example."
  return 0
}

ops_env_get() {
  local env_file="$1" name="$2"
  awk -F= -v k="$name" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$env_file" 2>/dev/null || true
}

ops_env_set() {
  local env_file="$1" name="$2" value="$3" esc
  esc=$(printf '%s' "$value" | sed -e 's/[\\|&]/\\&/g')
  if grep -qE "^${name}=" "$env_file"; then
    sed -i.bak "s|^${name}=.*|${name}=${esc}|" "$env_file"
    rm -f "$env_file.bak"
  else
    printf '%s=%s\n' "$name" "$value" >> "$env_file"
  fi
}

ops_source_env() {
  local env_file="$1"
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
}

ops_to_owner_repo() {
  local url="$1"
  case "$url" in
    git@github.com:*) url="${url#git@github.com:}" ;;
    https://github.com/*) url="${url#https://github.com/}" ;;
    *) printf ''; return 0 ;;
  esac
  url="${url%.git}"
  printf '%s' "$url"
}

ops_shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
