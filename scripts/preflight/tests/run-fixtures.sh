#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PREFLIGHT_DIR/../.." && pwd)"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/gcloud" <<'FAKE_GCLOUD'
#!/usr/bin/env bash
set -euo pipefail

fixture="${GCLOUD_FIXTURE:-}"
[ -n "$fixture" ] || { echo "GCLOUD_FIXTURE is required" >&2; exit 2; }

cmd="$1:$2"
case "$cmd" in
  config:get-value)
    case "$fixture" in
      no-active-two-billed|no-active-no-billed-with-account|no-active-no-billing) echo "(unset)" ;;
      active-unbilled-with-alternative|active-billed-compute-disabled) echo "alpha-project" ;;
      *) exit 2 ;;
    esac
    ;;

  projects:list)
    case "$fixture" in
      no-active-two-billed|active-unbilled-with-alternative)
        printf '%s\n' alpha-project beta-project gamma-project
        ;;
      no-active-no-billed-with-account|no-active-no-billing|active-billed-compute-disabled)
        printf '%s\n' alpha-project
        ;;
      *) exit 2 ;;
    esac
    ;;

  projects:describe)
    project="${3:-}"
    case "$fixture:$project" in
      active-unbilled-with-alternative:alpha-project|active-billed-compute-disabled:alpha-project) echo "$project" ;;
      *) echo "$project" ;;
    esac
    ;;

  billing:accounts)
    case "$fixture" in
      no-active-two-billed|no-active-no-billed-with-account|active-unbilled-with-alternative|active-billed-compute-disabled)
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
      active-unbilled-with-alternative:beta-project|active-billed-compute-disabled:alpha-project)
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

test_no_active_project_lists_billing_ready_projects() {
  local out="$TMP_ROOT/no-active-two-billed.txt" report="$TMP_ROOT/no-active-two-billed.report"

  run_gcloud_preflight no-active-two-billed "$out"

  assert_contains "counts accessible projects" "accessible projects:     3" "$out"
  assert_contains "counts billing-ready projects" "billing-ready projects:  2 (alpha-project (+1 more))" "$out"
  assert_contains "prints first billing-ready project" "  - alpha-project" "$out"
  assert_contains "prints second billing-ready project" "  - beta-project" "$out"
  assert_not_contains "omits unbilled project from billing-ready list" "  - gamma-project" "$out"
  assert_contains "prompts direct project selection" "gcloud config set project PROJECT_ID" "$out"

  run_gcloud_preflight no-active-two-billed "$report" --report
  assert_contains "report keeps project list single-line" "billing_enabled_projects='alpha-project,beta-project'" "$report"
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

test_no_active_project_lists_billing_ready_projects
test_no_active_project_with_billing_account_but_no_billed_project
test_no_active_project_without_billing
test_active_unbilled_project_points_to_alternative
test_active_billed_project_with_compute_disabled

printf 'passed %s preflight fixture assertions\n' "$pass_count"
