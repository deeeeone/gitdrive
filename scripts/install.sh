#!/bin/bash
# Builds GitDrive from source with your own free Apple ID and installs it to /Applications.
#
#   ./scripts/install.sh              build, install and open
#   ./scripts/install.sh --no-install build only (result in build/Build/Products/Release)
set -euo pipefail
cd "$(dirname "$0")/.."

install=true
[[ "${1:-}" == "--no-install" ]] && install=false

say()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

# 1. Xcode
xcode-select -p >/dev/null 2>&1 && [[ -d "$(xcode-select -p)/../SharedFrameworks" ]] \
  || fail "Install Xcode from the App Store, open it once, then run this again."

# 2. XcodeGen
if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || fail "Install Homebrew (https://brew.sh) or XcodeGen, then run this again."
  say "Installing XcodeGen"
  brew install xcodegen
fi

# 3. Signing team, read from your Apple Development certificate
if [[ ! -f Config/Local.xcconfig ]]; then
  team=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1)
  [[ -n "$team" ]] || fail "No Apple Development certificate found.
  Open Xcode > Settings > Accounts, add your Apple ID (free is fine),
  click Manage Certificates, add an 'Apple Development' certificate, then run this again."
  lower=$(echo "$team" | tr '[:upper:]' '[:lower:]')
  say "Using team $team"
  cat > Config/Local.xcconfig <<CONF
DEVELOPMENT_TEAM = $team
GITDRIVE_BUNDLE_ID = dev.gitdrive.t$lower
GITDRIVE_OAUTH_CLIENT_ID =
CONF
fi

# 4. Build
say "Generating the Xcode project"
xcodegen generate --quiet
say "Building (this takes a minute or two the first time)"
xcodebuild -project GitDrive.xcodeproj -scheme GitDrive -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates -quiet build \
  || fail "Build failed. If it mentions signing, open GitDrive.xcodeproj in Xcode once and build there."

app=build/Build/Products/Release/GitDrive.app
if ! $install; then
  say "Built $app"
  exit 0
fi

# 5. Install
say "Installing to /Applications"
pkill -x GitDrive 2>/dev/null || true
rm -rf /Applications/GitDrive.app
cp -R "$app" /Applications/
open /Applications/GitDrive.app
say "Done. Click the cloud icon in the menu bar to sign in."
