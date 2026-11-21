#!/bin/bash
# One-time setup of a macOS 26 (Tahoe) VM for local XNU 12377 SWEET kernel builds.
# Run as the normal (non-root) user that will own the build, with internet access.
#
# Why this VM: GitHub Actions costs 20-50 min per build iteration. Locally we can
# rebuild a single file in seconds and the whole kernel in minutes, which is what
# we need to instrument the current early-boot fault (dc zva on 0xfffffe000c600040).
#
# After running this, hand the SSH host/user/auth to the agent and ask it to run
# tools/build-local.sh. Requirements for the VM: 8+ CPU, 16+ GB RAM, 120+ GB disk
# (Xcode ~40 GB, KDK ~7 GB, build tree ~5 GB, logs ~1 GB).

set -euo pipefail

say() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }

say "macOS VM setup for SWEET-port xnu-12377 (one-time)"

# ---------------------------------------------------------------------------
# 1. macOS version
# ---------------------------------------------------------------------------
SWVER=$(sw_vers -productVersion)
say "macOS version: $SWVER"
case "$SWVER" in
  26.*|27.*) ;;
  *) warn "macOS 26.x (Tahoe) is required for the 26.5 KDK / xnu-12377. You have $SWVER." ;;
esac

# ---------------------------------------------------------------------------
# 2. Xcode 26.x + command line tools
# ---------------------------------------------------------------------------
say "Checking Xcode"
XC=""
for CAND in /Applications/Xcode_26.6.app /Applications/Xcode_26.5.app \
            /Applications/Xcode_26.5.0.app /Applications/Xcode_26.4.1.app \
            /Applications/Xcode_26.3.0.app /Applications/Xcode_26.3.app \
            /Applications/Xcode_26.2.app /Applications/Xcode.app; do
  [ -d "$CAND" ] && XC="$CAND" && break
done
if [ -z "$XC" ]; then
  warn "No Xcode 26.x found. Install it from the Mac App Store or with:"
  warn "  brew install xcodesorg/made/xcodes && sudo xcodes install 26.3"
  warn "Then re-run this script."
else
  echo "Using $XC"
  sudo xcode-select -s "$XC/Contents/Developer"
  SDKVER=$(xcrun --sdk macosx --show-sdk-version)
  echo "SDK version: $SDKVER"
  xcodebuild -version | head -3
fi

# ---------------------------------------------------------------------------
# 3. Homebrew and build dependencies
# ---------------------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  say "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
fi
say "Installing build dependencies"
brew install jq gum bash cmake ninja git python3

# darwin-xnu-build calls `xcodes` only as a presence check; stub it if missing.
if ! command -v xcodes >/dev/null 2>&1; then
  say "Stubbing xcodes (build.sh only checks that it exists)"
  printf '#!/bin/sh\nexit 0\n' | sudo tee /usr/local/bin/xcodes >/dev/null
  sudo chmod +x /usr/local/bin/xcodes
fi

# ---------------------------------------------------------------------------
# 4. Kernel Debug Kit 26.5 (build 25F71) — build.sh downloads this itself, but
#    fetch it now so we fail early if Apple's CDN is unreachable.
# ---------------------------------------------------------------------------
say "Checking KDK 26.5 (25F71)"
if [ -d "/Library/Developer/KDKs/KDK_26.5_25F71.kdk" ]; then
  echo "KDK already installed"
else
  echo "KDK not installed; build.sh will download it on first build."
  echo "If that fails, fetch it manually from https://developer.apple.com/download/all/"
  echo "and install the Kernel Debug Kit 26.5 (25F71) package."
fi

# ---------------------------------------------------------------------------
# 5. Clone the repo with the SWEET-port patch
# ---------------------------------------------------------------------------
REPO_DIR="$HOME/ios-guacamole-hotdog"
if [ -d "$REPO_DIR/.git" ]; then
  say "Repo exists at $REPO_DIR — fetching latest"
  git -C "$REPO_DIR" fetch --all -q
  git -C "$REPO_DIR" checkout -q sweet-port
  git -C "$REPO_DIR" reset --hard -q origin/sweet-port 2>/dev/null || \
    git -C "$REPO_DIR" reset --hard -q forks/sweet-port 2>/dev/null || true
else
  say "Cloning repo to $REPO_DIR"
  git clone -q --branch sweet-port https://github.com/ampekk/ios-guacamole-hotdog.git "$REPO_DIR"
fi
ls -lh "$REPO_DIR/xnu/sweet-port-ci.patch"

# ---------------------------------------------------------------------------
# 6. Enable SSH (remote login)
# ---------------------------------------------------------------------------
say "Enabling SSH (remote login)"
sudo systemsetup -setremotelogin on 2>/dev/null || \
  sudo launchctl enable system/com.openssh.sshd 2>/dev/null || \
  warn "Could not enable SSH automatically; enable it in System Settings > General > Sharing > Remote Login."

echo
echo "SSH address: $(whoami)@$(ipconfig getifaddr en0 2>/dev/null || hostname)"
echo "Also note: if this is a VM behind NAT, set up a port forward (e.g. host 2222 -> VM 22)."

# ---------------------------------------------------------------------------
# 7. Sanity check: dry-run the pinned build driver setup
# ---------------------------------------------------------------------------
say "Fetching pinned darwin-xnu-build driver (no build yet)"
cd "$REPO_DIR"
if [ ! -d dxb/.git ]; then
  git init -q dxb
  git -C dxb fetch -q --depth 1 https://github.com/blacktop/darwin-xnu-build.git \
    663906528d1cd5ea8fde7de6f16de73db9511549
  git -C dxb checkout -q FETCH_HEAD
fi
echo "dxb driver ready at $REPO_DIR/dxb"

say "SETUP COMPLETE"
echo "Next: hand SSH details to the agent; it will run tools/build-local.sh"
