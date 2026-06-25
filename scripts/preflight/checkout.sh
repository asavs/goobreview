#!/usr/bin/env bash
# Report local/VM checkout alignment for onboarding safety.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_FILE="$REPO_ROOT/.goobreview-cloud-shell.env"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/ops.sh"
export OPS_LOG_PREFIX="preflight-checkout"

report=0
strict=0
allow_setup_ref_mismatch=0

usage() {
  cat <<EOF
Usage: bash scripts/preflight/checkout.sh [--report] [--strict] [--allow-setup-ref-mismatch]

Checks local checkout state, the bootstrap setup-vm.sh source ref, and the VM
checkout when the VM handoff and SSH are available.

Options:
  --report   Emit machine-readable key=value output.
  --strict   Exit nonzero when checkout divergence would make mutation unsafe.
  --allow-setup-ref-mismatch
             Do not fail strict mode when setup-vm.sh defaults to another ref.
  -h, --help Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --report)
      report=1
      ;;
    --strict)
      strict=1
      ;;
    --allow-setup-ref-mismatch)
      allow_setup_ref_mismatch=1
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

report_value() {
  local key="$1" data="$2"
  printf '%s' "$data" | awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; found=1; exit} END {if (!found) print ""}'
}

raw_ref_from_url() {
  local url="$1" rest
  case "$url" in
    https://raw.githubusercontent.com/*)
      rest="${url#https://raw.githubusercontent.com/}"
      rest="${rest#*/}"
      rest="${rest#*/}"
      case "$rest" in
        */scripts/setup-vm.sh) printf '%s' "${rest%/scripts/setup-vm.sh}" ;;
        *) printf '%s' "${rest%%/*}" ;;
      esac
      ;;
    *)
      printf ''
      ;;
  esac
}

git_value() {
  git -C "$REPO_ROOT" "$@" 2>/dev/null || true
}

state_file_present=0
if [ -f "$STATE_FILE" ]; then
  state_file_present=1
  # shellcheck disable=SC1090
  . "$STATE_FILE"
fi

local_git_found=0
local_branch=""
local_head=""
local_origin=""
local_dirty="unknown"
local_status_count="unknown"

if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  local_git_found=1
  local_branch="$(git_value symbolic-ref --quiet --short HEAD)"
  if [ -z "$local_branch" ]; then
    local_branch="(detached)"
  fi
  local_head="$(git_value rev-parse --verify HEAD)"
  local_origin="$(git_value remote get-url origin)"
  local_status="$(git_value status --porcelain --untracked-files=normal)"
  local_status_count="$(printf '%s\n' "$local_status" | awk 'NF {count++} END {print count + 0}')"
  if [ "$local_status_count" -eq 0 ]; then
    local_dirty="false"
  else
    local_dirty="true"
  fi
fi

detected_owner_repo="$(ops_to_owner_repo "$local_origin")"
if [ -z "$detected_owner_repo" ]; then
  detected_owner_repo="asavs/goobreview"
fi

setup_vm_url="${GOOBREVIEW_SETUP_VM_URL:-https://raw.githubusercontent.com/${detected_owner_repo}/main/scripts/setup-vm.sh}"
setup_vm_ref="$(raw_ref_from_url "$setup_vm_url")"
setup_ref_mismatch="unknown"
if [ "$local_git_found" -eq 1 ] && [ -n "$setup_vm_ref" ]; then
  if [ "$local_branch" != "(detached)" ] && [ "$setup_vm_ref" != "$local_branch" ]; then
    setup_ref_mismatch="true"
  else
    setup_ref_mismatch="false"
  fi
fi
if [ -n "${GOOBREVIEW_SETUP_VM_URL:-}" ]; then
  setup_ref_mismatch="false"
fi

vm_name="${GOOBREVIEW_VM_NAME:-goobreview-1}"
zone="${GOOBREVIEW_ZONE:-us-central1-a}"
vm_project="${GOOBREVIEW_GCP_PROJECT:-}"
vm_checkout="${GOOBREVIEW_VM_CHECKOUT:-/opt/goobreview/example}"
vm_checkout_quoted="$(ops_shell_quote "$vm_checkout")"

gcloud_found=0
vm_checked="false"
vm_reachable="unknown"
vm_branch=""
vm_head=""
vm_origin=""
vm_dirty="unknown"
vm_status_count="unknown"
alignment="unknown"

if command -v gcloud >/dev/null 2>&1; then
  gcloud_found=1
  if [ -z "$vm_project" ]; then
    vm_project="$(gcloud config get-value project 2>/dev/null || true)"
  fi
  if command -v timeout >/dev/null 2>&1 && gcloud compute instances describe "$vm_name" --zone="$zone" >/dev/null 2>&1; then
    vm_checked="true"
    # The command runs on the VM; keep git expansion remote-side.
    # shellcheck disable=SC2016
    remote_probe="$(timeout 30 gcloud compute ssh "$vm_name" --zone="$zone" --quiet --command="
      set -eu
      checkout=$vm_checkout_quoted
      if [ ! -d \"\$checkout/.git\" ]; then
        printf 'vm_reachable=true\n'
        printf 'vm_checkout_present=false\n'
        exit 0
      fi
      printf 'vm_reachable=true\n'
      printf 'vm_checkout_present=true\n'
      printf 'vm_branch=%s\n' \"\$(git -C \"\$checkout\" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '(detached)')\"
      printf 'vm_head=%s\n' \"\$(git -C \"\$checkout\" rev-parse --verify HEAD 2>/dev/null || true)\"
      printf 'vm_origin=%s\n' \"\$(git -C \"\$checkout\" remote get-url origin 2>/dev/null || true)\"
      status=\$(git -C \"\$checkout\" status --porcelain --untracked-files=normal 2>/dev/null || true)
      count=\$(printf '%s\n' \"\$status\" | awk 'NF {count++} END {print count + 0}')
      printf 'vm_status_count=%s\n' \"\$count\"
      if [ \"\$count\" -eq 0 ]; then
        printf 'vm_dirty=false\n'
      else
        printf 'vm_dirty=true\n'
      fi
    " 2>/dev/null || true)"
    if [ -n "$remote_probe" ]; then
      vm_reachable="$(report_value vm_reachable "$remote_probe")"
      vm_checkout_present="$(report_value vm_checkout_present "$remote_probe")"
      if [ "$vm_checkout_present" = "true" ]; then
        vm_branch="$(report_value vm_branch "$remote_probe")"
        vm_head="$(report_value vm_head "$remote_probe")"
        vm_origin="$(report_value vm_origin "$remote_probe")"
        vm_status_count="$(report_value vm_status_count "$remote_probe")"
        vm_dirty="$(report_value vm_dirty "$remote_probe")"
      fi
    else
      vm_reachable="false"
    fi
  fi
fi

if [ "$local_git_found" -eq 1 ] && [ "$vm_reachable" = "true" ] && [ -n "$vm_head" ]; then
  local_owner_repo="$(ops_to_owner_repo "$local_origin")"
  vm_owner_repo="$(ops_to_owner_repo "$vm_origin")"
  if [ "$local_head" = "$vm_head" ] && [ "$local_owner_repo" = "$vm_owner_repo" ]; then
    alignment="true"
  else
    alignment="false"
  fi
fi

recommendation="Checkout state looks safe."
strict_failure=0
if [ "$local_git_found" -ne 1 ]; then
  recommendation="Run from a git checkout before mutating setup state."
  strict_failure=1
elif [ "$local_dirty" = "true" ]; then
  recommendation="Commit, stash, or remove local checkout changes before mutating setup state."
  strict_failure=1
elif [ "$setup_ref_mismatch" = "true" ] && [ "$allow_setup_ref_mismatch" -ne 1 ]; then
  recommendation="Set GOOBREVIEW_SETUP_VM_URL to the intended setup-vm.sh ref, or run bootstrap from the branch that matches the default raw URL."
  strict_failure=1
elif [ "$vm_dirty" = "true" ]; then
  recommendation="Clean the VM checkout before mutating setup state."
  strict_failure=1
elif [ "$alignment" = "false" ]; then
  recommendation="Align the Cloud Shell and VM checkouts before mutating setup state."
  strict_failure=1
fi

if [ "$report" -eq 1 ]; then
  print_field "local_git_found" "$(bool "$local_git_found")"
  print_field "local_branch" "$local_branch"
  print_field "local_head" "$local_head"
  print_field "local_origin" "$local_origin"
  print_field "local_dirty" "$local_dirty"
  print_field "local_status_count" "$local_status_count"
  print_field "setup_vm_url" "$setup_vm_url"
  print_field "setup_vm_ref" "$setup_vm_ref"
  print_field "setup_ref_mismatch" "$setup_ref_mismatch"
  print_field "state_file" "$STATE_FILE"
  print_field "state_file_present" "$(bool "$state_file_present")"
  print_field "vm_project" "$vm_project"
  print_field "vm_name" "$vm_name"
  print_field "vm_zone" "$zone"
  print_field "vm_checkout" "$vm_checkout"
  print_field "gcloud_found" "$(bool "$gcloud_found")"
  print_field "vm_checked" "$vm_checked"
  print_field "vm_reachable" "$vm_reachable"
  print_field "vm_branch" "$vm_branch"
  print_field "vm_head" "$vm_head"
  print_field "vm_origin" "$vm_origin"
  print_field "vm_dirty" "$vm_dirty"
  print_field "vm_status_count" "$vm_status_count"
  print_field "alignment" "$alignment"
  print_field "recommendation" "$recommendation"
  if [ "$strict" -eq 1 ]; then
    print_field "strict_ok" "$(bool "$((1 - strict_failure))")"
  fi
  if [ "$strict" -eq 1 ] && [ "$strict_failure" -ne 0 ]; then
    exit 1
  fi
  exit 0
fi

cat <<EOF
Checkout preflight
------------------
local git checkout:     $(bool "$local_git_found")
local branch/ref:       ${local_branch:-unknown}
local HEAD:             ${local_head:-unknown}
local origin:           ${local_origin:-unknown}
local dirty:            $local_dirty${local_status_count:+ ($local_status_count)}
setup-vm.sh URL:        $setup_vm_url
setup-vm.sh ref:        ${setup_vm_ref:-unknown}
setup ref mismatch:     $setup_ref_mismatch
handoff file:           $(bool "$state_file_present") ($STATE_FILE)
VM name:                $vm_name
VM zone:                $zone
VM checkout:            $vm_checkout
VM checked:             $vm_checked
VM reachable:           $vm_reachable
VM branch/ref:          ${vm_branch:-unknown}
VM HEAD:                ${vm_head:-unknown}
VM origin:              ${vm_origin:-unknown}
VM dirty:               $vm_dirty${vm_status_count:+ ($vm_status_count)}
local/VM aligned:       $alignment

Next: $recommendation
EOF

if [ "$strict" -eq 1 ] && [ "$strict_failure" -ne 0 ]; then
  exit 1
fi
