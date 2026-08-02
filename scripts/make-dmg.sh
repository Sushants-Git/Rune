#!/usr/bin/env bash
# Build build/Rune-v<version>-macos-universal.dmg from build/Rune.app.
#
#   ./scripts/make-dmg.sh                 # version comes from the built app
#   VERSION=0.7.0 ./scripts/make-dmg.sh
#
# A disk image alongside the zip rather than instead of it. They answer
# different questions: the zip is what the in-app updater downloads and unpacks
# with no one watching, and the dmg is what a person opens — it mounts with an
# Applications symlink beside the app, so installing is the drag everyone
# already knows.
#
# That drag is also the fix for Rune not appearing in Raycast or Spotlight:
# both index /Applications and nowhere else, so an app left in ~/Downloads is
# invisible to them. A zip encourages exactly that mistake; a dmg with a visible
# /Applications target doesn't.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${APP:-$REPO_ROOT/build/Rune.app}"
[ -d "$APP" ] || { echo "error: no app at $APP — run ./scripts/bundle.sh" >&2; exit 1; }

VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$APP/Contents/Info.plist")}"

# Named after what's actually inside. A local build is usually native-only, and
# a file called "universal" that runs on one architecture is the kind of thing
# nobody notices until an Intel user does.
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Rune")"
case "$ARCHS" in
  *arm64*\ *x86_64*|*x86_64*\ *arm64*) SLICE="universal" ;;
  *) SLICE="$(echo "$ARCHS" | tr -d ' ')" ;;
esac
DMG="$REPO_ROOT/build/Rune-v${VERSION}-macos-${SLICE}.dmg"

STAGING="$(mktemp -d)/Rune"
mkdir -p "$STAGING"
trap 'rm -rf "$(dirname "$STAGING")"' EXIT

# ditto rather than cp: an app bundle has symlinks and extended attributes, and
# a copy that loses them is a bundle that won't launch.
ditto "$APP" "$STAGING/Rune.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "Rune ${VERSION}" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -quiet \
  "$DMG"

echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
