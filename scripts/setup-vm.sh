#!/usr/bin/env bash
# Installs GoobReview dependencies on a fresh Ubuntu VM and clones the template.
# Idempotent: safe to re-run. Designed to be invoked over SSH by bootstrap-gcp.sh,
# or directly from inside the VM as the regular login user (not root).
set -euo pipefail

REPO_URL="${GOOBREVIEW_REPO_URL:-https://github.com/asavschaeffer/goobreview.git}"
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
  git jq curl wget ca-certificates gnupg lsb-release util-linux coreutils tar

# Small VMs (e2-micro = 1 GB RAM) can OOM when Gemini CLI spikes during a
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

node_major="$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || echo 0)"
if [ "${node_major:-0}" -lt 20 ]; then
  log "Installing Node.js 20 from NodeSource"
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
else
  log "Node $(node -v) already installed"
fi

if ! command -v gh >/dev/null 2>&1; then
  log "Installing GitHub CLI"
  sudo mkdir -p -m 755 /etc/apt/keyrings
  wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh
else
  log "gh $(gh --version | head -n1 | awk '{print $3}') already installed"
fi

if ! command -v gemini >/dev/null 2>&1; then
  log "Installing Gemini CLI (npm global)"
  sudo npm install -g @google/gemini-cli
else
  log "gemini already installed"
fi

log "Preparing $CHECKOUT_DIR and $STATE_DIR"
sudo mkdir -p "$CHECKOUT_DIR" "$STATE_DIR"
sudo chown -R "$TARGET_USER:$TARGET_USER" "$CHECKOUT_DIR" "$STATE_DIR"

if [ ! -d "$CHECKOUT_DIR/.git" ]; then
  log "Cloning $REPO_URL into $CHECKOUT_DIR"
  git clone "$REPO_URL" "$CHECKOUT_DIR"
else
  log "$CHECKOUT_DIR already a git checkout, skipping clone"
fi

log "Versions:"
git --version
gh --version | head -n1
node --version
gemini --version 2>/dev/null || echo "gemini installed (version flag may require login)"

cat <<EOF

[setup-vm] Done. Next, on this VM:

  cd $CHECKOUT_DIR
  gemini                              # sign in to Google, trust this folder, /quit

  # Then register a GitHub App (docs/github-app-setup.md), scp its
  # private key into $STATE_DIR/app-key.pem, and run:
  scripts/configure.sh

Then continue with docs/quickstart.md from step 5 (dry run), then step 6 (scheduler).
EOF
