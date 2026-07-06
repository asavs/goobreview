#!/usr/bin/env bash
# Snapshot, state, and artifact safety fixtures for the reviewer suite. Sourced by run-fixtures.sh, which
# provides the assert helpers, TMP_ROOT, and the sourced reviewer libs; the
# runner's registration list controls execution order.
# shellcheck disable=SC2034,SC2154,SC2317,SC2329

test_symlink_snapshot_safety() {
  local worktree_dir outside_file prompt_file output err_file

  worktree_dir="$TMP_ROOT/worktree-symlink"
  outside_file="$TMP_ROOT/outside-secret.txt"
  prompt_file="$TMP_ROOT/prompt-symlink.md"
  err_file="$TMP_ROOT/agy-symlink.err"
  mkdir -p "$worktree_dir/docs"
  printf 'outside secret should not appear\n' > "$outside_file"
  ln -s "$outside_file" "$worktree_dir/docs/GUIDELINES.md"

  REPO="example/repo"
  STATE_DIR="$TMP_ROOT/state-symlink"
  RUNTIME_STATE_DIR="$TMP_ROOT/runtime-symlink"
  AGY_TIMEOUT=60
  AGY_MODEL=auto
  mkdir -p "$STATE_DIR"
  printf 'APPROVE\n' > "$prompt_file"
  if run_agy_review "$prompt_file" "$err_file" "$worktree_dir" >/dev/null; then
    fail "agy refuses snapshot containing symlinks"
  fi
  pass "agy refuses snapshot containing symlinks"
  assert_contains "agy refusal explains symlink snapshot" "PR-head snapshot contains symlinks" "$err_file"
  assert_eq "agy records agy_failed as transcript source on refusal" "agy_failed" "$(agy_transcript_source)"

  sanitize_review_worktree_symlinks "$worktree_dir"
  if [ -L "$worktree_dir/docs/GUIDELINES.md" ]; then
    fail "snapshot sanitizer removes symlink"
  fi
  pass "snapshot sanitizer removes symlink"
  assert_contains "snapshot sanitizer leaves metadata stub" "symlink metadata only" "$worktree_dir/docs/GUIDELINES.md"
  assert_contains "snapshot sanitizer records symlink target" "target: $outside_file" "$worktree_dir/docs/GUIDELINES.md"
  assert_not_contains "snapshot sanitizer does not copy target content" "outside secret" "$worktree_dir/docs/GUIDELINES.md"
}

test_worktree_cache_keeps_per_head_slots() {
  local source_dir tarball state_dir runtime_dir first second first_again fetches_file

  source_dir="$TMP_ROOT/worktree-cache-source"
  tarball="$TMP_ROOT/worktree-cache.tar.gz"
  state_dir="$TMP_ROOT/worktree-cache-state"
  runtime_dir="$TMP_ROOT/worktree-cache-runtime"
  fetches_file="$TMP_ROOT/worktree-cache-fetches"
  mkdir -p "$source_dir/repo-root" "$state_dir" "$runtime_dir"
  printf 'cached\n' > "$source_dir/repo-root/README.md"
  mkdir -p "$source_dir/repo-root/.agents"
  printf 'injected-rule\n' > "$source_dir/repo-root/.agents/rules.md"
  tar -czf "$tarball" -C "$source_dir" repo-root

  REPO="example/repo"
  STATE_DIR="$state_dir"
  RUNTIME_STATE_DIR="$runtime_dir"
  LOG_FILE="$TMP_ROOT/worktree-cache.log"
  : > "$LOG_FILE"

  # shellcheck disable=SC2317 # Mocked API helper is invoked indirectly by prepare_review_worktree.
  github_api_get() {
    case "${1:-}" in
      repos/example/repo/tarball/*)
        count=$(cat "$fetches_file" 2>/dev/null || printf 0)
        count=$((count + 1))
        printf '%s\n' "$count" > "$fetches_file"
        cat "$tarball"
        ;;
      *)
        return 1
        ;;
    esac
  }

  first=$(prepare_review_worktree sha1)
  second=$(prepare_review_worktree sha2)
  first_again=$(prepare_review_worktree sha1)

  assert_eq "worktree cache reuses first head slot" "$first" "$first_again"
  assert_contains "worktree cache stores first head content" "cached" "$first/README.md"
  assert_contains "worktree cache stores second head content" "cached" "$second/README.md"
  assert_eq "worktree cache avoids re-fetching evicted heads" "2" "$(cat "$fetches_file")"

  if [ -e "$first/.agents" ]; then
    fail "worktree prep strips .agents from PR-head snapshot"
  fi
  pass "worktree prep strips .agents from PR-head snapshot"
}

test_invalid_verdict_state() {
  local artifact count

  STATE_DIR="$TMP_ROOT/invalid-state"
  mkdir -p "$STATE_DIR"

  assert_eq "missing invalid verdict count is zero" "0" "$(review_attempts_count invalid-verdict 17 abc123)"
  count=$(review_attempts_record invalid-verdict 17 abc123)
  assert_eq "invalid verdict first attempt is recorded" "1" "$count"
  count=$(review_attempts_record invalid-verdict 17 abc123)
  assert_eq "invalid verdict attempts increment per head" "2" "$count"
  assert_eq "different head has separate invalid verdict count" "0" "$(review_attempts_count invalid-verdict 17 def456)"

  artifact=$(write_invalid_verdict_artifact 17 abc123 INVALID_VERDICT $'NOPE\nbody')
  assert_contains "invalid artifact records PR" "PR: #17" "$artifact"
  assert_contains "invalid artifact records head SHA" "Head SHA: abc123" "$artifact"
  assert_contains "invalid artifact persists rejected output" "NOPE" "$artifact"

  review_attempts_clear invalid-verdict 17 abc123
  assert_eq "invalid verdict attempts clear after valid output" "0" "$(review_attempts_count invalid-verdict 17 abc123)"

  assert_eq "missing review failure count is zero" "0" "$(review_attempts_count review-failure 17 abc123)"
  count=$(review_attempts_record review-failure 17 abc123)
  assert_eq "review failure first attempt is recorded" "1" "$count"
  count=$(review_attempts_record review-failure 17 abc123)
  assert_eq "review failure attempts increment per head" "2" "$count"
  assert_eq "different head has separate review failure count" "0" "$(review_attempts_count review-failure 17 def456)"

  review_attempts_clear review-failure 17 abc123
  assert_eq "review failure attempts clear after success" "0" "$(review_attempts_count review-failure 17 abc123)"

  # The counter kinds share one file family; distinct kinds never collide.
  review_attempts_record invalid-verdict 17 abc123 >/dev/null
  assert_eq "counter kinds keep separate counts per head" "0" "$(review_attempts_count review-failure 17 abc123)"
}

test_artifact_secret_safety() {
  local src dst normal_src normal_dst key_src

  STATE_DIR="$TMP_ROOT/artifact-state"
  mkdir -p "$STATE_DIR"
  LOG_FILE="$TMP_ROOT/artifact-secret.log"
  : > "$LOG_FILE"

  src="$TMP_ROOT/secret-artifact.txt"
  dst="$TMP_ROOT/secret-artifact.out"
  cat > "$src" <<'EOF'
GoobReview dry run
GH_TOKEN=ghs_should_not_be_written
GITHUB_TOKEN: github_pat_should_not_be_written
REVIEWER_APP_PRIVATE_KEY_PATH=/var/lib/goobreview/example/app-key.pem
GEMINI_API_KEY=gemini_should_not_be_written
GOOGLE_APPLICATION_CREDENTIALS=/var/lib/goobreview/google.json
AWS_SECRET_ACCESS_KEY=aws_should_not_be_written
EOF
  if install_secret_scanned_artifact "$src" "$dst"; then
    fail "dry-run artifact secret assignments are rejected"
  fi
  pass "dry-run artifact secret assignments are rejected"
  if [ -e "$dst" ]; then
    fail "rejected dry-run artifact is not written"
  fi
  pass "rejected dry-run artifact is not written"
  assert_contains "dry-run artifact rejection is logged" "Refusing to write artifact containing high-confidence secret material" "$LOG_FILE"

  key_src="$TMP_ROOT/key-artifact.txt"
  cat > "$key_src" <<'EOF'
-----BEGIN PRIVATE KEY-----
abc
-----END PRIVATE KEY-----
EOF
  if artifact_secret_scan "$key_src" >/dev/null; then
    fail "private key material is rejected"
  fi
  pass "private key material is rejected"

  normal_src="$TMP_ROOT/normal-artifact.txt"
  normal_dst="$TMP_ROOT/normal-artifact.out"
  cat > "$normal_src" <<'EOF'
diff --git a/README.md b/README.md
+ Document that GH_TOKEN and GITHUB_TOKEN are unset before Gemini runs.
+ Mention REVIEWER_APP_PRIVATE_KEY_PATH by name without printing its value.
env:
  GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
EOF
  install_secret_scanned_artifact "$normal_src" "$normal_dst"
  assert_contains "ordinary artifact text is preserved" "GH_TOKEN and GITHUB_TOKEN are unset" "$normal_dst"
  assert_file_mode "accepted dry-run artifact is mode 0600" "600" "$normal_dst"

  # Variable/expression references are not literal secrets: a workflow diff that
  # wires `${{ secrets.GITHUB_TOKEN }}` or `$GH_TOKEN` must still be capturable.
  local ref_src ref_dst
  ref_src="$TMP_ROOT/ref-artifact.txt"
  ref_dst="$TMP_ROOT/ref-artifact.out"
  cat > "$ref_src" <<'EOF'
diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
+        env:
+          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
+          GH_TOKEN: $GITHUB_TOKEN
EOF
  if ! install_secret_scanned_artifact "$ref_src" "$ref_dst"; then
    fail "artifact with Actions/shell secret references is accepted"
  fi
  pass "artifact with Actions/shell secret references is accepted"
  assert_contains "referenced-secret artifact is preserved" "secrets.GITHUB_TOKEN" "$ref_dst"

  # The reference carve-out must not mask a real literal credential assignment.
  local literal_src literal_dst
  literal_src="$TMP_ROOT/literal-artifact.txt"
  literal_dst="$TMP_ROOT/literal-artifact.out"
  cat > "$literal_src" <<'EOF'
diff --git a/deploy.sh b/deploy.sh
+GITHUB_TOKEN=ghp_realtokenmaterial123456
EOF
  if install_secret_scanned_artifact "$literal_src" "$literal_dst"; then
    fail "literal credential assignment is still rejected"
  fi
  pass "literal credential assignment is still rejected"
}

test_state_and_output_permissions() {
  local state_dir output_src output_dst

  state_dir="$TMP_ROOT/private-state"
  mkdir -p "$state_dir"
  chmod 755 "$state_dir"
  STATE_DIR="$state_dir"
  LOG_FILE="$TMP_ROOT/private-state.log"
  : > "$LOG_FILE"

  ensure_owner_private_dir "runtime state" "$state_dir"
  assert_file_mode "state directory is repaired to 0700" "700" "$state_dir"

  output_src="$TMP_ROOT/prompt-output-src.md"
  output_dst="$TMP_ROOT/prompt-output.md"
  printf 'prompt text\n' > "$output_src"
  secure_install_file "$output_src" "$output_dst"
  assert_file_mode "prompt output is mode 0600" "600" "$output_dst"
}
