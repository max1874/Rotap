#!/usr/bin/env bash
# Builds build/Rotap.app with Xcode (same as ⌘B in Rotap.xcodeproj, Release configuration).
# This is a development build: it is signed but not notarized. Releases go through `make release`,
# and the copy to run day to day is the one `make install` puts in /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Release}"
xcodebuild -project Rotap.xcodeproj -scheme Rotap -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData SYMROOT="$PWD/build" -quiet build

# The account's release pipeline (`asc notarize rotap`) picks the app up from build/Rotap.app.
rm -rf build/Rotap.app
ditto "build/$CONFIG/Rotap.app" build/Rotap.app
echo "build/Rotap.app"
