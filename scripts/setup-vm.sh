#!/usr/bin/env bash
# Installs GoobReview dependencies on a fresh Ubuntu VM and clones the template.
# Idempotent: safe to re-run. Designed to be invoked over SSH by bootstrap-gcp.sh,
# or directly from inside the VM as the regular login user (not root).
set -euo pipefail

REPO_URL="${GOOBREVIEW_REPO_URL:-https://github.com/asavschaeffer/goobreview.git}"
CHECKOUT_DIR="${GOOBREVIEW_CHECKOUT_DIR:-/opt/goobreview/example}"
STATE_DIR="${GOOBREVIEW_STATE_DIR:-/var/lib/goobreview/example}"
TARGET_USER="${GOOBREVIEW_USER:-$USER}"

log() { printf '[setup-vm] %s\n' "$*"; }

if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" = "root" ]; then
  echo "Refusing to install for the root user. Re-run as a normal sudoer user, or set GOOBREVIEW_USER." >&2
  exit 1
fi

log "apt: base packages"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  git jq curl wget ca-certificates gnupg lsb-release util-linux coreutils

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
  if ! grep -qE "^$SWAPFILE[[:space:]]" /etc/fstab; then
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
sudo chown -R "$TARGET_USER:$TARGET_USER" \
  "$(dirname "$CHECKOUT_DIR")" "$(dirname "$STATE_DIR")"

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

Then continue with docs/quickstart.md from step 6 (dry run, scheduler).
EOF
