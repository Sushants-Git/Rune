#!/usr/bin/env bash
# Build Rune and assemble build/Rune.app.
#
#   ./scripts/bundle.sh              # release
#   CONFIG=debug ./scripts/bundle.sh
#   VERSION=1.2.0 ./scripts/bundle.sh   # stamp a version (used by CI on tags)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$REPO_ROOT/build/Rune.app"

if [ ! -d "$REPO_ROOT/vendor/ghostty/macos/GhosttyKit.xcframework" ]; then
  echo "==> GhosttyKit.xcframework missing, building libghostty first"
  "$REPO_ROOT/scripts/build-libghostty.sh"
fi

echo "==> swift build ($CONFIG)"
swift build --package-path "$REPO_ROOT" -c "$CONFIG"

BIN="$(swift build --package-path "$REPO_ROOT" -c "$CONFIG" --show-bin-path)/Rune"
[ -x "$BIN" ] || { echo "error: no binary at $BIN" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Rune"
cp "$REPO_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$REPO_ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi

# Ad-hoc sign so macOS will let the app claim focus and open a pty.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
  || echo "warning: ad-hoc codesign failed; the app may not launch correctly" >&2

echo "==> $APP"
