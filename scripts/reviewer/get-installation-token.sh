#!/usr/bin/env bash
# Print either the installation access token (default, or `token`) or the
# App's slug (`slug`) to stdout. Both are cached on disk in
# $REVIEWER_STATE/app_token.json and refreshed when <5 minutes remain.
# Reads REVIEWER_APP_ID, REVIEWER_APP_INSTALLATION_ID,
# REVIEWER_APP_PRIVATE_KEY_PATH, REVIEWER_STATE from the environment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/lib/app-token.mjs" "$@"
