#!/usr/bin/env bash
# Config resolution fixtures for the reviewer suite. Sourced by run-fixtures.sh, which
# provides the assert helpers, TMP_ROOT, and the sourced reviewer libs; the
# runner's registration list controls execution order.
# shellcheck disable=SC2034,SC2154,SC2317,SC2329

test_private_key_permissions() {
  local key_file="$TMP_ROOT/app-key.pem"

  printf 'key\n' > "$key_file"
  chmod 600 "$key_file"
  validate_private_key_file "$key_file"
  pass "private key mode 0600 is accepted"

  chmod 644 "$key_file"
  if ( validate_private_key_file "$key_file" ) >/dev/null 2>&1; then
    fail "private key mode with group/other bits is rejected"
  fi
  pass "private key mode with group/other bits is rejected"
}

test_config_file_resolution() {
  local config_dir="$TMP_ROOT/config-resolution"
  local default_file="$config_dir/required-checks.json"
  local example_file="$config_dir/required-checks.example.json"
  local explicit_file="$config_dir/explicit-required-checks.json"

  mkdir -p "$config_dir"
  printf '[]\n' > "$example_file"
  unset REVIEWER_REQUIRED_CHECKS_FILE

  assert_eq "dry-run config resolution may use example fallback" "$example_file" \
    "$(resolve_reviewer_config_file "required checks" REVIEWER_REQUIRED_CHECKS_FILE "$default_file" "$example_file" 1)"

  if ( resolve_reviewer_config_file "required checks" REVIEWER_REQUIRED_CHECKS_FILE "$default_file" "$example_file" 0 ) >/dev/null 2>&1; then
    fail "live config resolution rejects example fallback"
  fi
  pass "live config resolution rejects example fallback"

  printf '["ci"]\n' > "$default_file"
  assert_eq "live config resolution uses real default file" "$default_file" \
    "$(resolve_reviewer_config_file "required checks" REVIEWER_REQUIRED_CHECKS_FILE "$default_file" "$example_file" 0)"

  printf '["explicit"]\n' > "$explicit_file"
  REVIEWER_REQUIRED_CHECKS_FILE="$explicit_file"
  assert_eq "explicit config file is accepted" "$explicit_file" \
    "$(resolve_reviewer_config_file "required checks" REVIEWER_REQUIRED_CHECKS_FILE "$default_file" "$example_file" 0)"

  REVIEWER_REQUIRED_CHECKS_FILE="$TMP_ROOT/missing.json"
  if ( resolve_reviewer_config_file "required checks" REVIEWER_REQUIRED_CHECKS_FILE "$default_file" "$example_file" 1 ) >/dev/null 2>&1; then
    fail "explicit missing config file is rejected"
  fi
  pass "explicit missing config file is rejected"
  unset REVIEWER_REQUIRED_CHECKS_FILE
}

test_personality_config_resolution() {
  local config_dir

  config_dir="$TMP_ROOT/personality-config"
  mkdir -p "$config_dir/personalities"
  printf 'control\n' > "$config_dir/personalities/control.md"
  printf 'linus\n' > "$config_dir/personalities/linus.md"
  printf 'angry\n' > "$config_dir/personalities/angry.md"
  REPO_DIR="$config_dir"
  CONFIG_DIR="$config_dir"
  unset REVIEWER_PERSONALITY_FILE

  REVIEWER_POSTED_PERSONALITY=none
  resolve_reviewer_personality_config
  assert_eq "posted personality none is recorded" "none" "$POSTED_PERSONALITY"
  assert_eq "posted personality none maps to control" "$config_dir/personalities/control.md" "$PERSONALITY_FILE"

  REVIEWER_POSTED_PERSONALITY=linus
  resolve_reviewer_personality_config
  assert_eq "posted personality linus is recorded" "linus" "$POSTED_PERSONALITY"
  assert_eq "posted personality linus maps to linus" "$config_dir/personalities/linus.md" "$PERSONALITY_FILE"

  REVIEWER_POSTED_PERSONALITY=angry
  resolve_reviewer_personality_config
  assert_eq "posted personality angry is recorded" "angry" "$POSTED_PERSONALITY"
  assert_eq "posted personality angry maps to angry" "$config_dir/personalities/angry.md" "$PERSONALITY_FILE"

  unset REVIEWER_POSTED_PERSONALITY
  REVIEWER_PERSONALITY_FILE="$config_dir/custom.md"
  printf 'custom\n' > "$REVIEWER_PERSONALITY_FILE"
  resolve_reviewer_personality_config
  assert_eq "legacy personality file remains custom" "custom" "$POSTED_PERSONALITY"
  assert_eq "legacy personality file remains active" "$config_dir/custom.md" "$PERSONALITY_FILE"

  REVIEWER_POSTED_PERSONALITY=bad
  if ( resolve_reviewer_personality_config ) >/dev/null 2>&1; then
    fail "invalid posted personality is rejected"
  fi
  pass "invalid posted personality is rejected"

  unset REVIEWER_POSTED_PERSONALITY REVIEWER_PERSONALITY_FILE
}

test_log_rotation() {
  local log_file="$TMP_ROOT/rotate.log"

  printf '1234567890' > "$log_file"
  REVIEWER_LOG_MAX_BYTES=5 REVIEWER_LOG_ROTATE_KEEP=2 bash "$REVIEWER_DIR/rotate-log.sh" "$log_file"

  assert_eq "log rotation truncates active log" "0" "$(wc -c < "$log_file" | tr -d ' ')"
  assert_contains "log rotation preserves first archive" "1234567890" "$log_file.1"
}
