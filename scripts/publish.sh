#!/usr/bin/env bash
# Cuts a release: notarize, then publish the image as a GitHub release of this repo.
#
# Signing, notarization, the disk image and its audit are not implemented here — `asc notarize rotap`
# in ~/Projects/Repo/apple-developer owns them and leaves build/Rotap-<version>.dmg (+ .sha256).
#
# Usage: scripts/publish.sh [--notes <file>] [--dry-run]
set -euo pipefail
cd "$(dirname "$0")/.."

NOTES=""
DRY_RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "usage: scripts/publish.sh [--notes <file>] [--dry-run]" >&2; exit 1 ;;
  esac
done

settings="$(xcodebuild -project Rotap.xcodeproj -target Rotap -configuration Release -showBuildSettings 2>/dev/null)"
VERSION="$(awk '$1 == "MARKETING_VERSION" { print $3 }' <<<"$settings")"
BUILD="$(awk '$1 == "CURRENT_PROJECT_VERSION" { print $3 }' <<<"$settings")"
TAG="v$VERSION"
DMG="build/Rotap-$VERSION.dmg"

# Preflight, before the minutes of notarization rather than after.
[ "$(git branch --show-current)" = "main" ] || { echo "error: releases are cut from main" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "error: working tree is dirty" >&2; exit 1; }
git fetch --quiet origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "error: main is not in sync with origin" >&2; exit 1; }
command -v asc >/dev/null || { echo "error: asc not on PATH (apple-developer repo)" >&2; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "error: $TAG already published; bump MARKETING_VERSION first" >&2
  exit 1
fi

echo "==> releasing Rotap $VERSION (build $BUILD)"
if [ -n "$DRY_RUN" ]; then
  asc notarize rotap --plan
  exit 0
fi

asc notarize rotap

body="Rotap $VERSION (build $BUILD)"
[ -n "$NOTES" ] && body="$(cat "$NOTES")"$'\n\n'"$body"
gh release create "$TAG" "$DMG" "$DMG.sha256" --target "$(git rev-parse HEAD)" \
  --title "Rotap $VERSION" --notes "$body"
echo "==> published $TAG"
