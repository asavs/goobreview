#!/usr/bin/env bash
# Installs GoobReview dependencies on a fresh Ubuntu VM and clones the template.
# Idempotent: safe to re-run. Designed to be invoked over SSH by bootstrap-gcp.sh,
# or directly from inside the VM as the regular login user (not root).
set -euo pipefail

REPO_URL="${GOOBREVIEW_REPO_URL:-https://github.com/asavs/goobreview.git}"
CHECKOUT_DIR="${GOOBREVIEW_CHECKOUT_DIR:-/opt/goobreview/example}"
STATE_DIR="${GOOBREVIEW_STATE_DIR:-/var/lib/goobreview/example}"
TARGET_USER="${GOOBREVIEW_USER:-${USER:-$(id -un)}}"

log() { printf '[setup-vm] %s\n' "$*"; }
die() { printf '[setup-vm] ERROR: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "$1 not found."; }
require_absolute_path() {
  local name="$1" value="$2"
  case "$value" in
    /*) ;;
    *) die "$name must be an absolute path; got '$value'." ;;
  esac
}

# Reject paths where a recursive ownership change would affect a system root or
# broad shared directory instead of a reviewer-specific checkout/state tree.
require_safe_owned_path() {
  local name="$1" value="$2"
  case "$value" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/var/lib)
      die "$name points at unsafe shared directory '$value'. Use a reviewer-specific subdirectory such as /opt/goobreview/example or /var/lib/goobreview/example."
      ;;
  esac
}

if [ "${GOOBREVIEW_SETUP_VM_TEST_HELPERS:-0}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" = "root" ]; then
  die "Refusing to install for the root user. Re-run as a normal sudoer user, or set GOOBREVIEW_USER."
fi
require_command sudo
require_command apt-get
require_absolute_path GOOBREVIEW_CHECKOUT_DIR "$CHECKOUT_DIR"
require_absolute_path GOOBREVIEW_STATE_DIR "$STATE_DIR"
require_safe_owned_path GOOBREVIEW_CHECKOUT_DIR "$CHECKOUT_DIR"
require_safe_owned_path GOOBREVIEW_STATE_DIR "$STATE_DIR"
if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
  die "Target user '$TARGET_USER' does not exist. Set GOOBREVIEW_USER to a real login user."
fi

log "apt: base packages"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  git jq curl wget ca-certificates gnupg lsb-release util-linux coreutils tar openssl

# Small VMs (e2-micro = 1 GB RAM) can OOM when Antigravity CLI spikes during a
# review. A 2 GB swap file turns hard OOM kills into slower-but-successful
# runs. Override size via GOOBREVIEW_SWAP_SIZE (e.g. "0" to skip).
SWAPFILE="${GOOBREVIEW_SWAPFILE:-/swapfile}"
SWAP_SIZE="${GOOBREVIEW_SWAP_SIZE:-2G}"
if [ "$SWAP_SIZE" != "0" ]; then
  if ! sudo swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
    log "Configuring $SWAP_SIZE swap at $SWAPFILE"
    if [ ! -f "$SWAPFILE" ]; then
      sudo fallocate -l "$SWAP_SIZE" "$SWAPFILE" 2>/dev/null \
        || sudo dd if=/dev/zero of="$SWAPFILE" bs=1M count=2048 status=none
      sudo chmod 600 "$SWAPFILE"
      sudo mkswap "$SWAPFILE" >/dev/null
    fi
    sudo swapon "$SWAPFILE"
  else
    log "Swap already active at $SWAPFILE"
  fi
  if ! grep -qE "^${SWAPFILE}[[:space:]]" /etc/fstab; then
    echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
  fi
fi

if ! command -v agy >/dev/null 2>&1; then
  log "Installing Antigravity CLI"
  curl -fsSL https://antigravity.google/cli/install.sh | sudo -E bash -s -- --dir /usr/local/bin
else
  log "agy already installed"
fi

log "Preparing $CHECKOUT_DIR and $STATE_DIR"
sudo mkdir -p "$CHECKOUT_DIR" "$STATE_DIR"
sudo chown -R "$TARGET_USER:$TARGET_USER" "$CHECKOUT_DIR" "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"

if [ ! -d "$CHECKOUT_DIR/.git" ]; then
  log "Cloning $REPO_URL into $CHECKOUT_DIR"
  git clone "$REPO_URL" "$CHECKOUT_DIR"
else
  log "$CHECKOUT_DIR already a git checkout, skipping clone"
fi

log "Versions:"
git --version
openssl version
agy --version </dev/null 2>/dev/null || echo "agy installed (version flag may require login)"

cat <<EOF

[setup-vm] Done. Next, on this VM:

  cd $CHECKOUT_DIR
  agy                                 # sign in to Google

  # Then register a GitHub App (docs/github-app-setup.md), scp its
  # private key into $STATE_DIR/app-key.pem, and run:
  scripts/configure.sh

Then continue with docs/quickstart.md from step 5 (dry run), then step 6 (scheduler).
EOF
