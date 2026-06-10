#!/usr/bin/env bash
# Convenience wrapper for read-only GoobReview VM discovery.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/preflight/vm-discovery.sh" "$@"
