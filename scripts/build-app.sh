#!/usr/bin/env bash
# Builds build/Release/Rotap.app with Xcode (same as ⌘B in Rotap.xcodeproj, Release configuration).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Release}"
xcodebuild -project Rotap.xcodeproj -scheme Rotap -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData SYMROOT="$PWD/build" -quiet build
echo "build/$CONFIG/Rotap.app"
