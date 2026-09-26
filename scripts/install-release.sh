#!/usr/bin/env bash
# Installs the released disk image into /Applications — the same file a user downloads, not the
# build/ copy. A development build is signed but not notarized, so running it proves nothing about
# what users get.
#
# Usage: scripts/install-release.sh [path-to-dmg]   (default: build/Rotap-<version>.dmg)
set -euo pipefail
cd "$(dirname "$0")/.."

settings="$(xcodebuild -project Rotap.xcodeproj -target Rotap -configuration Release -showBuildSettings 2>/dev/null)"
VERSION="$(awk '$1 == "MARKETING_VERSION" { print $3 }' <<<"$settings")"
DMG="${1:-build/Rotap-$VERSION.dmg}"
[ -f "$DMG" ] || { echo "error: $DMG not found — run 'make release' first, or pass a downloaded .dmg" >&2; exit 1; }

# The check Gatekeeper makes on a downloaded file.
spctl --assess --type open --context context:primary-signature "$DMG"

MOUNT="$(mktemp -d /tmp/rotap-install.XXXXXX)"
cleanup() { hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true; }
trap cleanup EXIT
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet -readonly

# Quitting mid-recording would finalize the file, but never do it behind the user's back.
if pgrep -xq Rotap && osascript -e 'tell application "System Events" to exists (button "停止" of toolbar 1 of window 1 of process "Rotap")' 2>/dev/null | grep -q true; then
  echo "error: Rotap is recording; stop it first" >&2
  exit 1
fi
osascript -e 'tell application "Rotap" to quit' 2>/dev/null || true
while pgrep -xq Rotap; do sleep 0.2; done

rm -rf /Applications/Rotap.app
ditto "$MOUNT/Rotap.app" /Applications/Rotap.app
xcrun stapler validate /Applications/Rotap.app
echo "==> installed Rotap $VERSION"
