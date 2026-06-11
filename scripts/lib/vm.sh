#!/usr/bin/env bash
# Shared read-only Compute Engine VM probes for onboarding scripts.
# Mutating VM operations intentionally stay in the scripts that request consent.

# Return success when the VM can be described in the given zone.
vm_instance_exists() {
  local vm_name="$1" zone="$2"
  gcloud compute instances describe "$vm_name" --zone="$zone" >/dev/null 2>&1
}

# Print Compute Engine instances matching a name pattern in one project as
# tab-separated name/zone/machine/status rows.
vm_list_matching_instances() {
  local project="$1" name_pattern="$2"
  gcloud compute instances list \
    --project="$project" \
    --filter="name~${name_pattern}" \
    --format='value(name,zone.basename(),machineType.basename(),status)' 2>/dev/null || true
}

# Return success when a quiet SSH no-op succeeds within the supplied timeout.
vm_ssh_reachable() {
  local vm_name="$1" zone="$2" timeout_seconds="${3:-15}"
  command -v timeout >/dev/null 2>&1 || return 2
  timeout "$timeout_seconds" gcloud compute ssh "$vm_name" --zone="$zone" --quiet --command='true' >/dev/null 2>&1
}

# Run the standard VM dependency/checkout probe and print key=value rows.
vm_remote_dependency_probe() {
  local vm_name="$1" zone="$2" timeout_seconds="${3:-30}"
  command -v timeout >/dev/null 2>&1 || return 2

  # The command runs on the VM; keep $cmd expansion remote-side.
  # shellcheck disable=SC2016
  timeout "$timeout_seconds" gcloud compute ssh "$vm_name" --zone="$zone" --quiet --command='
    set -eu
    if [ -d /opt/goobreview/example ]; then
      printf "checkout_present=true\n"
    else
      printf "checkout_present=false\n"
    fi
    for cmd in git jq curl wget node gh gemini; do
      if command -v "$cmd" >/dev/null 2>&1; then
        printf "%s=true\n" "$cmd"
      else
        printf "%s=false\n" "$cmd"
      fi
    done
  ' 2>/dev/null || true
}
