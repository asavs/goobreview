#!/usr/bin/env bash
# Print either the installation access token (default, or `token`), the App's
# slug (`slug`), or an installation ID (`discover OWNER/REPO`) to stdout.
# token/slug are cached on disk in $REVIEWER_STATE/app_token.json and refreshed
# when <5 minutes remain. Values are read from REVIEWER_* environment variables
# by default; app-token.mjs also accepts direct flags for setup diagnostics.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/lib/app-token.mjs" "$@"
