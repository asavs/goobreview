#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/gcloud" <<'FAKE_GCLOUD'
#!/usr/bin/env bash
set -euo pipefail

fixture="${GCLOUD_FIXTURE:-}"
checkout_fixture="${CHECKOUT_GCLOUD_FIXTURE:-}"
[ -n "$fixture$checkout_fixture" ] || { echo "GCLOUD_FIXTURE or CHECKOUT_GCLOUD_FIXTURE is required" >&2; exit 2; }

cmd="$1:$2"
if [ -n "$checkout_fixture" ]; then
  case "$cmd" in
    config:get-value)
      echo "alpha-project"
      exit 0
      ;;
    compute:instances)
      case "$checkout_fixture" in
        unreachable) exit 1 ;;
        *) echo "goobreview-1" ; exit 0 ;;
      esac
      ;;
    compute:ssh)
      case "$checkout_fixture" in
        aligned)
          cat "$CHECKOUT_VM_REPORT"
          ;;
        dirty-vm)
          sed 's/vm_dirty=false/vm_dirty=true/; s/vm_status_count=0/vm_status_count=1/' "$CHECKOUT_VM_REPORT"
          ;;
        diverged-vm)
          sed 's/vm_head=.*/vm_head=0000000000000000000000000000000000000000/' "$CHECKOUT_VM_REPORT"
          ;;
        unreachable)
          exit 1
          ;;
        *)
          echo "unexpected CHECKOUT_GCLOUD_FIXTURE: $checkout_fixture" >&2
          exit 2
          ;;
      esac
      exit 0
      ;;
  esac
fi

case "$cmd" in
  auth:list)
    case "$fixture" in
      unauthenticated) ;;
      *) printf '%s\n' user@example.test ;;
    esac
    ;;

  config:get-value)
    case "$fixture" in
      no-active-two-billed|no-active-inferred-billing|no-active-no-billed-with-account|no-active-no-billing) echo "(unset)" ;;
      active-unbilled-with-alternative|active-billed-compute-disabled) echo "alpha-project" ;;
      restore-saved-project)
        if [ -f "$RESTORE_MARKER" ]; then
          echo "alpha-project"
        else
          echo "(unset)"
        fi
        ;;
      unauthenticated)
        echo "ERROR: (gcloud.config.get-value) You do not currently have an active account selected." >&2
        exit 1
        ;;
      *) exit 2 ;;
    esac
    ;;

  config:set)
    case "$fixture" in
      restore-saved-project)
        project="${4:-}"
        printf '%s' "$project" > "$RESTORE_MARKER"
        ;;
      *) exit 2 ;;
    esac
    ;;

  projects:list)
    case "$fixture" in
      unauthenticated)
        echo "ERROR: (gcloud.projects.list) You do not currently have an active account selected." >&2
        exit 1
        ;;
      no-active-two-billed|no-active-inferred-billing|active-unbilled-with-alternative)
        printf '%s\n' alpha-project beta-project gamma-project
        ;;
      no-active-no-billed-with-account|no-active-no-billing|active-billed-compute-disabled|restore-saved-project)
        printf '%s\n' alpha-project
        ;;
      *) exit 2 ;;
    esac
    ;;

  projects:describe)
    project="${3:-}"
    case "$fixture:$project" in
      active-unbilled-with-alternative:alpha-project|active-billed-compute-disabled:alpha-project|restore-saved-project:alpha-project) echo "$project" ;;
      *) echo "$project" ;;
    esac
    ;;

  billing:accounts)
    case "$fixture" in
      no-active-two-billed|no-active-no-billed-with-account|active-unbilled-with-alternative|active-billed-compute-disabled|restore-saved-project)
        printf '%s\t%s\n' billingAccounts/ABC123 "Personal Billing"
        ;;
      no-active-no-billing)
        ;;
      *) exit 2 ;;
    esac
    ;;

  billing:projects)
    project="${4:-}"
    case "$fixture:$project" in
      no-active-two-billed:alpha-project|no-active-two-billed:beta-project)
        if [[ "$*" == *"billingAccountName,billingEnabled"* ]]; then
          printf '%s\t%s\n' billingAccounts/ABC123 True
        else
          printf '%s\n' True
        fi
        ;;
      no-active-inferred-billing:alpha-project|no-active-inferred-billing:beta-project)
        if [[ "$*" == *"billingAccountName,billingEnabled"* ]]; then
          printf '%s\t%s\n' billingAccounts/INFERRED True
        else
          printf '%s\n' True
        fi
        ;;
      active-unbilled-with-alternative:beta-project|active-billed-compute-disabled:alpha-project|restore-saved-project:alpha-project)
        if [[ "$*" == *"billingAccountName,billingEnabled"* ]]; then
          printf '%s\t%s\n' billingAccounts/ABC123 True
        else
          printf '%s\n' True
        fi
        ;;
      *)
        if [[ "$*" == *"billingAccountName,billingEnabled"* ]]; then
          printf '\t%s\n' False
        else
          printf '%s\n' False
        fi
        ;;
    esac
    ;;

  services:list)
    case "$fixture" in
      active-billed-compute-disabled) exit 0 ;;
      *) printf '%s\n' compute.googleapis.com ;;
    esac
    ;;

  *)
    echo "unexpected gcloud call: $*" >&2
    exit 2
    ;;
esac
FAKE_GCLOUD
chmod +x "$FAKE_BIN/gcloud"

pass_count=0

pass() {
  printf 'ok - %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

run_gcloud_preflight() {
  local fixture="$1" out="$2"
  shift 2

  PATH="$FAKE_BIN:$PATH" GCLOUD_FIXTURE="$fixture" \
    bash "$PREFLIGHT_DIR/gcloud.sh" "$@" > "$out"
}

setup_gcloud_repo_with_saved_project() {
  local name="$1" saved_project="$2" repo
  repo="$TMP_ROOT/$name"

  mkdir -p "$repo/scripts/preflight" "$repo/scripts/lib"
  cp "$PREFLIGHT_DIR/gcloud.sh" "$repo/scripts/preflight/gcloud.sh"
  cp "$PREFLIGHT_DIR/../lib/ops.sh" "$repo/scripts/lib/ops.sh"
  cp "$PREFLIGHT_DIR/../lib/gcloud.sh" "$repo/scripts/lib/gcloud.sh"

  cat > "$repo/.goobreview-cloud-shell.env" <<EOF
GOOBREVIEW_GCP_PROJECT='$saved_project'
EOF

  printf '%s' "$repo"
}

run_gcloud_preflight_in_repo() {
  local fixture="$1" repo="$2" out="$3" marker="$4"
  shift 4

  PATH="$FAKE_BIN:$PATH" GCLOUD_FIXTURE="$fixture" RESTORE_MARKER="$marker" \
    bash "$repo/scripts/preflight/gcloud.sh" "$@" > "$out"
}

setup_checkout_repo() {
  local name="$1" branch="${2:-main}" repo
  repo="$TMP_ROOT/$name"

  mkdir -p "$repo/scripts/preflight" "$repo/scripts/lib"
  cp "$PREFLIGHT_DIR/checkout.sh" "$repo/scripts/preflight/checkout.sh"
  cp "$PREFLIGHT_DIR/../lib/ops.sh" "$repo/scripts/lib/ops.sh"

  git -C "$repo" init -b "$branch" >/dev/null
  git -C "$repo" config user.email fixtures@example.test
  git -C "$repo" config user.name "Fixture Tests"
  printf 'hello\n' > "$repo/README.md"
  git -C "$repo" add README.md scripts/preflight/checkout.sh scripts/lib/ops.sh
  git -C "$repo" commit -m "initial" >/dev/null
  git -C "$repo" remote add origin https://github.com/asavschaeffer/goobreview

  printf '%s' "$repo"
}

setup_launch_repo() {
  local name="$1" repo
  repo="$TMP_ROOT/$name"

  mkdir -p "$repo/scripts/lib" "$repo/config" "$repo/state"
  cp "$PREFLIGHT_DIR/../launch-check.sh" "$repo/scripts/launch-check.sh"
  cp "$PREFLIGHT_DIR/../lib/ops.sh" "$repo/scripts/lib/ops.sh"
  chmod +x "$repo/scripts/launch-check.sh"

  printf '["ci"]\n' > "$repo/config/required-checks.json"
  printf 'key\n' > "$repo/state/app-key.pem"
  chmod 600 "$repo/state/app-key.pem"
  cat > "$repo/config/reviewer.env" <<EOF
REVIEWER_REPO=owner/repo
REVIEWER_APP_ID=123
REVIEWER_APP_INSTALLATION_ID=456
REVIEWER_APP_PRIVATE_KEY_PATH=$repo/state/app-key.pem
REVIEWER_STATE=$repo/state
EOF

  printf '%s' "$repo"
}

write_launch_metadata() {
  local repo="$1" bypass="${2:-0}" owner_repo="${3:-owner/repo}"
  local out="$repo/state/dry-run-fixture.txt"
  local required_sha

  printf 'dry run\n' > "$out"
  required_sha="$(sha256sum "$repo/config/required-checks.json" | awk '{print $1}')"
  jq -n \
    --arg repo "$owner_repo" \
    --arg dry_run_out "$out" \
    --arg required_checks_sha256 "$required_sha" \
    --arg dry_run_bypass_ci "$bypass" \
    '{repo:$repo,dry_run_out:$dry_run_out,required_checks_sha256:$required_checks_sha256,dry_run_bypass_ci:$dry_run_bypass_ci,event:"APPROVE",required_checks:["ci"]}' \
    > "$out.launch.json"
}

write_vm_report_for_repo() {
  local repo="$1" out="$2" dirty="${3:-false}" head

  head="$(git -C "$repo" rev-parse --verify HEAD)"
  cat > "$out" <<EOF
vm_reachable=true
vm_checkout_present=true
vm_branch=$(git -C "$repo" symbolic-ref --quiet --short HEAD)
vm_head=$head
vm_origin=https://github.com/asavschaeffer/goobreview
vm_status_count=0
vm_dirty=$dirty
EOF
}

run_checkout_preflight() {
  local repo="$1" out="$2"
  shift 2

  PATH="$FAKE_BIN:$PATH" \
    bash "$repo/scripts/preflight/checkout.sh" "$@" > "$out"
}

run_checkout_preflight_with_setup_url() {
  local repo="$1" out="$2" setup_url="$3"
  shift 3

  PATH="$FAKE_BIN:$PATH" GOOBREVIEW_SETUP_VM_URL="$setup_url" \
    bash "$repo/scripts/preflight/checkout.sh" "$@" > "$out"
}

run_checkout_preflight_with_vm() {
  local fixture="$1" repo="$2" out="$3" vm_report="$4"
  shift 4

  PATH="$FAKE_BIN:$PATH" CHECKOUT_GCLOUD_FIXTURE="$fixture" CHECKOUT_VM_REPORT="$vm_report" \
    bash "$repo/scripts/preflight/checkout.sh" "$@" > "$out"
}

run_launch_check() {
  local repo="$1" out="$2"
  shift 2

  (cd "$repo" && "$@" bash scripts/launch-check.sh) > "$out" 2>&1
}

assert_contains() {
  local name="$1" needle="$2" file="$3"

  if ! grep -Fq -- "$needle" "$file"; then
    printf 'missing expected text: %s\n' "$needle" >&2
    printf '%s\n' "--- $file ---" >&2
    sed -n '1,220p' "$file" >&2
    fail "$name"
  fi
  pass "$name"
}

assert_not_contains() {
  local name="$1" needle="$2" file="$3"

  if grep -Fq -- "$needle" "$file"; then
    printf 'unexpected text: %s\n' "$needle" >&2
    printf '%s\n' "--- $file ---" >&2
    sed -n '1,220p' "$file" >&2
    fail "$name"
  fi
  pass "$name"
}

test_unauthenticated_gcloud_stops_before_project_inference() {
  local out="$TMP_ROOT/unauthenticated.txt" report="$TMP_ROOT/unauthenticated.report"

  CLOUDSDK_CONFIG=/tmp/goobreview-isolated run_gcloud_preflight unauthenticated "$out"

  assert_contains "unauthenticated reports no active account" "active account:          none" "$out"
  assert_contains "unauthenticated reports Cloud SDK config" "Cloud SDK config:        /tmp/goobreview-isolated" "$out"
  assert_contains "unauthenticated points to auth login" "gcloud auth login" "$out"
  assert_not_contains "unauthenticated avoids billing diagnosis" "Set up Cloud Billing" "$out"

  CLOUDSDK_CONFIG=/tmp/goobreview-isolated run_gcloud_preflight unauthenticated "$report" --report
  assert_contains "unauthenticated report marks auth false" "gcloud_authenticated='false'" "$report"
  assert_contains "unauthenticated report includes config" "cloudsdk_config='/tmp/goobreview-isolated'" "$report"
}

test_no_active_project_lists_billing_ready_projects() {
  local out="$TMP_ROOT/no-active-two-billed.txt" report="$TMP_ROOT/no-active-two-billed.report"

  run_gcloud_preflight no-active-two-billed "$out"

  assert_contains "counts accessible projects" "accessible projects:     3" "$out"
  assert_contains "counts billing-ready projects" "billing-ready projects:  2 (alpha-project (+1 more))" "$out"
  assert_contains "dedupes direct and linked billing accounts" "open billing accounts:   1" "$out"
  assert_contains "prints first billing-ready project" "  - alpha-project" "$out"
  assert_contains "prints second billing-ready project" "  - beta-project" "$out"
  assert_not_contains "omits unbilled project from billing-ready list" "  - gamma-project" "$out"
  assert_contains "prompts direct project selection" "gcloud config set project PROJECT_ID" "$out"

  run_gcloud_preflight no-active-two-billed "$report" --report
  assert_contains "report keeps project list single-line" "billing_enabled_projects='alpha-project,beta-project'" "$report"
}


test_no_active_project_infers_billing_account_from_projects() {
  local out="$TMP_ROOT/no-active-inferred-billing.txt" report="$TMP_ROOT/no-active-inferred-billing.report"

  run_gcloud_preflight no-active-inferred-billing "$out"

  assert_contains "counts inferred billing account once" "open billing accounts:   1" "$out"
  assert_contains "dedupes linked billing account across projects" "billing-ready projects:  2 (alpha-project (+1 more))" "$out"

  run_gcloud_preflight no-active-inferred-billing "$report" --report
  assert_contains "reports inferred billing account count" "billing_account_count='1'" "$report"
}

test_no_active_project_with_billing_account_but_no_billed_project() {
  local out="$TMP_ROOT/no-active-no-billed-with-account.txt"

  run_gcloud_preflight no-active-no-billed-with-account "$out"

  assert_contains "reports no billing-ready projects" "billing-ready projects:  0 (none)" "$out"
  assert_contains "uses bootstrap to link existing billing" "create or select a project and link one of your billing accounts" "$out"
}

test_no_active_project_without_billing() {
  local out="$TMP_ROOT/no-active-no-billing.txt"

  run_gcloud_preflight no-active-no-billing "$out"

  assert_contains "reports no open billing accounts" "open billing accounts:   0" "$out"
  assert_contains "asks for cloud billing setup" "Set up Cloud Billing" "$out"
}

test_active_unbilled_project_points_to_alternative() {
  local out="$TMP_ROOT/active-unbilled-with-alternative.txt"

  run_gcloud_preflight active-unbilled-with-alternative "$out"

  assert_contains "detects active billing disabled" "billing enabled:         false" "$out"
  assert_contains "lists alternative project" "  - beta-project" "$out"
  assert_contains "suggests switching or bootstrap repair" "Switch to one listed below, or run bash scripts/bootstrap-gcp.sh to link billing." "$out"
}

test_active_billed_project_with_compute_disabled() {
  local out="$TMP_ROOT/active-billed-compute-disabled.txt"

  run_gcloud_preflight active-billed-compute-disabled "$out"

  assert_contains "detects billed active project" "billing enabled:         true" "$out"
  assert_contains "detects compute disabled" "Compute Engine API:      false" "$out"
  assert_contains "delegates compute enablement to bootstrap" "bootstrap-gcp.sh can do this before VM creation" "$out"
}

test_gcloud_restores_saved_project_when_unset() {
  local repo out marker
  repo="$(setup_gcloud_repo_with_saved_project gcloud-restore alpha-project)"
  out="$TMP_ROOT/restore-saved-project.report"
  marker="$TMP_ROOT/restore-saved-project.marker"
  rm -f "$marker"

  run_gcloud_preflight_in_repo restore-saved-project "$repo" "$out" "$marker" --report

  assert_contains "restore writes config set with saved project" "alpha-project" "$marker"
  assert_contains "restore reports active project restored" "active_project='alpha-project'" "$out"
  assert_contains "restore reports usable project" "usable_project='true'" "$out"
}

test_checkout_aligned_clean() {
  local repo out
  repo="$(setup_checkout_repo checkout-aligned main)"
  out="$TMP_ROOT/checkout-aligned.report"

  run_checkout_preflight "$repo" "$out" --report --strict

  assert_contains "checkout reports clean local state" "local_dirty='false'" "$out"
  assert_contains "checkout reports matching setup ref" "setup_ref_mismatch='false'" "$out"
  assert_contains "checkout strict passes" "strict_ok='true'" "$out"
}

test_checkout_setup_ref_mismatch_fails_strict() {
  local repo out
  repo="$(setup_checkout_repo checkout-branch feature-sync)"
  out="$TMP_ROOT/checkout-branch.report"

  if run_checkout_preflight "$repo" "$out" --report --strict; then
    fail "checkout setup ref mismatch fails strict"
  fi
  assert_contains "checkout detects setup ref mismatch" "setup_ref_mismatch='true'" "$out"
  pass "checkout setup ref mismatch fails strict"
}

test_checkout_explicit_setup_url_passes_strict() {
  local repo out
  repo="$(setup_checkout_repo checkout-explicit feature-sync)"
  out="$TMP_ROOT/checkout-explicit.report"

  run_checkout_preflight_with_setup_url "$repo" "$out" \
    "https://raw.githubusercontent.com/asavschaeffer/goobreview/feature-sync/scripts/setup-vm.sh" \
    --report --strict

  assert_contains "checkout explicit setup URL clears mismatch" "setup_ref_mismatch='false'" "$out"
  assert_contains "checkout explicit setup URL strict passes" "strict_ok='true'" "$out"
}

test_checkout_allows_setup_ref_mismatch_when_requested() {
  local repo out
  repo="$(setup_checkout_repo checkout-allowed feature-sync)"
  out="$TMP_ROOT/checkout-allowed.report"

  run_checkout_preflight "$repo" "$out" --report --strict --allow-setup-ref-mismatch

  assert_contains "checkout still reports allowed setup mismatch" "setup_ref_mismatch='true'" "$out"
  assert_contains "checkout allowed setup mismatch strict passes" "strict_ok='true'" "$out"
}

test_checkout_dirty_local_fails_strict() {
  local repo out
  repo="$(setup_checkout_repo checkout-dirty main)"
  printf 'dirty\n' >> "$repo/README.md"
  out="$TMP_ROOT/checkout-dirty.report"

  if run_checkout_preflight "$repo" "$out" --report --strict; then
    fail "checkout dirty local fails strict"
  fi
  assert_contains "checkout detects dirty local state" "local_dirty='true'" "$out"
  pass "checkout dirty local fails strict"
}

test_checkout_vm_aligned() {
  local repo out vm_report
  repo="$(setup_checkout_repo checkout-vm-aligned main)"
  out="$TMP_ROOT/checkout-vm-aligned.report"
  vm_report="$TMP_ROOT/checkout-vm-aligned.vm"
  write_vm_report_for_repo "$repo" "$vm_report"

  run_checkout_preflight_with_vm aligned "$repo" "$out" "$vm_report" --report --strict

  assert_contains "checkout reports VM reachable" "vm_reachable='true'" "$out"
  assert_contains "checkout reports VM alignment" "alignment='true'" "$out"
  assert_contains "checkout VM strict passes" "strict_ok='true'" "$out"
}

test_checkout_vm_diverged_fails_strict() {
  local repo out vm_report
  repo="$(setup_checkout_repo checkout-vm-diverged main)"
  out="$TMP_ROOT/checkout-vm-diverged.report"
  vm_report="$TMP_ROOT/checkout-vm-diverged.vm"
  write_vm_report_for_repo "$repo" "$vm_report"

  if run_checkout_preflight_with_vm diverged-vm "$repo" "$out" "$vm_report" --report --strict; then
    fail "checkout VM divergence fails strict"
  fi
  assert_contains "checkout reports VM divergence" "alignment='false'" "$out"
  pass "checkout VM divergence fails strict"
}

test_checkout_dirty_vm_fails_strict() {
  local repo out vm_report
  repo="$(setup_checkout_repo checkout-vm-dirty main)"
  out="$TMP_ROOT/checkout-vm-dirty.report"
  vm_report="$TMP_ROOT/checkout-vm-dirty.vm"
  write_vm_report_for_repo "$repo" "$vm_report"

  if run_checkout_preflight_with_vm dirty-vm "$repo" "$out" "$vm_report" --report --strict; then
    fail "checkout dirty VM fails strict"
  fi
  assert_contains "checkout reports dirty VM" "vm_dirty='true'" "$out"
  pass "checkout dirty VM fails strict"
}

test_checkout_unreachable_vm_does_not_fail_strict() {
  local repo out vm_report
  repo="$(setup_checkout_repo checkout-vm-unreachable main)"
  out="$TMP_ROOT/checkout-vm-unreachable.report"
  vm_report="$TMP_ROOT/checkout-vm-unreachable.vm"
  write_vm_report_for_repo "$repo" "$vm_report"

  run_checkout_preflight_with_vm unreachable "$repo" "$out" "$vm_report" --report --strict

  assert_contains "checkout reports unchecked VM" "vm_checked='false'" "$out"
  assert_contains "checkout unreachable VM strict passes" "strict_ok='true'" "$out"
}

source_setup_vm_helpers() {
  # shellcheck source=scripts/setup-vm.sh
  GOOBREVIEW_SETUP_VM_TEST_HELPERS=1 . "$PREFLIGHT_DIR/../setup-vm.sh"
}

test_setup_vm_allows_reviewer_specific_paths() {
  (
    source_setup_vm_helpers
    require_safe_owned_path GOOBREVIEW_CHECKOUT_DIR /opt/goobreview/example
    require_safe_owned_path GOOBREVIEW_STATE_DIR /var/lib/goobreview/example
    require_safe_owned_path GOOBREVIEW_CHECKOUT_DIR /srv/goobreview/reviewer-a
  )
  pass "setup-vm allows reviewer-specific checkout and state paths"
}

test_setup_vm_rejects_broad_chown_targets() {
  local out="$TMP_ROOT/setup-vm-unsafe-path.txt"

  if (
    source_setup_vm_helpers
    require_safe_owned_path GOOBREVIEW_CHECKOUT_DIR /opt
  ) > "$out" 2>&1; then
    fail "setup-vm rejects broad checkout chown target"
  fi
  assert_contains "setup-vm explains unsafe checkout path" "unsafe shared directory '/opt'" "$out"

  if (
    source_setup_vm_helpers
    require_safe_owned_path GOOBREVIEW_STATE_DIR /var/lib
  ) > "$out" 2>&1; then
    fail "setup-vm rejects broad state chown target"
  fi
  assert_contains "setup-vm explains unsafe state path" "unsafe shared directory '/var/lib'" "$out"
}

test_launch_check_passes_matching_current_dry_run() {
  local repo out
  repo="$(setup_launch_repo launch-pass)"
  out="$TMP_ROOT/launch-pass.out"
  write_launch_metadata "$repo" 0

  run_launch_check "$repo" "$out" env

  assert_contains "launch check reports success" "Launch validation passed." "$out"
  assert_contains "launch check reports CI bypass disabled" "CI bypass:           0" "$out"
}

test_launch_check_rejects_bypassed_ci_without_override() {
  local repo out
  repo="$(setup_launch_repo launch-bypass)"
  out="$TMP_ROOT/launch-bypass.out"
  write_launch_metadata "$repo" 1

  if run_launch_check "$repo" "$out" env; then
    fail "launch check rejects bypassed dry-run CI"
  fi
  assert_contains "launch check explains bypassed CI" "Latest dry run used REVIEWER_DRY_RUN_BYPASS_CI=1" "$out"
  pass "launch check rejects bypassed dry-run CI"
}

test_launch_check_rejects_changed_config() {
  local repo out
  repo="$(setup_launch_repo launch-changed-config)"
  out="$TMP_ROOT/launch-changed-config.out"
  write_launch_metadata "$repo" 0
  printf '["ci","lint"]\n' > "$repo/config/required-checks.json"

  if run_launch_check "$repo" "$out" env; then
    fail "launch check rejects changed required-check config"
  fi
  assert_contains "launch check tells operator to rerun dry-run" "required-check config changed after the latest dry run" "$out"
  pass "launch check rejects changed required-check config"
}

test_unauthenticated_gcloud_stops_before_project_inference
test_no_active_project_lists_billing_ready_projects
test_no_active_project_infers_billing_account_from_projects
test_no_active_project_with_billing_account_but_no_billed_project
test_no_active_project_without_billing
test_active_unbilled_project_points_to_alternative
test_active_billed_project_with_compute_disabled
test_gcloud_restores_saved_project_when_unset
test_checkout_aligned_clean
test_checkout_setup_ref_mismatch_fails_strict
test_checkout_explicit_setup_url_passes_strict
test_checkout_allows_setup_ref_mismatch_when_requested
test_checkout_dirty_local_fails_strict
test_checkout_vm_aligned
test_checkout_vm_diverged_fails_strict
test_checkout_dirty_vm_fails_strict
test_checkout_unreachable_vm_does_not_fail_strict
test_setup_vm_allows_reviewer_specific_paths
test_setup_vm_rejects_broad_chown_targets
test_launch_check_passes_matching_current_dry_run
test_launch_check_rejects_bypassed_ci_without_override
test_launch_check_rejects_changed_config

printf 'passed %s preflight fixture assertions\n' "$pass_count"
