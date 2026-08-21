#!/usr/bin/env bash
# Build Rune and assemble build/Rune.app.
#
#   ./scripts/bundle.sh              # release, this machine's architecture
#   CONFIG=debug ./scripts/bundle.sh
#   VERSION=1.2.0 ./scripts/bundle.sh   # stamp a version (used by CI on tags)
#   ARCH=universal ./scripts/bundle.sh  # arm64 + x86_64, for a shipped build
#
# ARCH=universal needs a universal GhosttyKit too — a Swift build for x86_64
# can't link an arm64-only xcframework, and the failure is a wall of missing
# symbols rather than anything that says "wrong architecture". Build it with
# TARGET=universal ./scripts/build-libghostty.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
ARCH="${ARCH:-native}"
APP="$REPO_ROOT/build/Rune.app"

XCFRAMEWORK="$REPO_ROOT/vendor/ghostty/macos/GhosttyKit.xcframework"
if [ ! -d "$XCFRAMEWORK" ]; then
  echo "==> GhosttyKit.xcframework missing, building libghostty first"
  TARGET="$([ "$ARCH" = universal ] && echo universal || echo native)" \
    "$REPO_ROOT/scripts/build-libghostty.sh"
fi

# Bash 3.2 — which is what macOS ships — treats expanding an empty array under
# `set -u` as an unbound variable, so every reference below uses the
# ${arr[@]+"${arr[@]}"} form. Without it a plain native `bundle.sh` dies before
# it builds anything, while the universal path (a non-empty array) works fine
# and hides it.
SWIFT_ARCH_FLAGS=()
if [ "$ARCH" = universal ]; then
  # Fail early and legibly rather than deep in the linker.
  if [ ! -d "$XCFRAMEWORK/macos-arm64_x86_64" ]; then
    echo "error: $XCFRAMEWORK has no universal slice." >&2
    echo "       Run: TARGET=universal ./scripts/build-libghostty.sh" >&2
    exit 1
  fi
  SWIFT_ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "==> swift build ($CONFIG, $ARCH)"
swift build --package-path "$REPO_ROOT" -c "$CONFIG" ${SWIFT_ARCH_FLAGS[@]+"${SWIFT_ARCH_FLAGS[@]}"}

BIN="$(swift build --package-path "$REPO_ROOT" -c "$CONFIG" ${SWIFT_ARCH_FLAGS[@]+"${SWIFT_ARCH_FLAGS[@]}"} --show-bin-path)/Rune"
[ -x "$BIN" ] || { echo "error: no binary at $BIN" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Rune"
cp "$REPO_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$REPO_ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Shipped inside the bundle so `rune install-opencode-hook` has something to
# install; see CLI.swift.
cp "$REPO_ROOT/Resources/opencode-plugin.js" "$APP/Contents/Resources/opencode-plugin.js"

# The MIT licence Ghostty is under asks that its notice ship with anything
# built on it, so it travels inside the app rather than only in the repo.
# Ghostty's own resources: the theme library and the terminfo database.
#
# `theme = Ayu Light` resolves from two places — the user's
# ~/.config/ghostty/themes, then the app's bundled library. Rune shipped
# neither, so any theme the user had not hand-copied simply was not found,
# while the same config line worked in Ghostty.
#
# The terminfo has to come with them. libghostty only sets TERM=xterm-ghostty
# when it has a resources directory, and it looks for the terminfo database
# beside it — so shipping themes without terminfo would leave every shell
# claiming to be a terminal whose capabilities nothing can look up.
GHOSTTY_SHARE="$REPO_ROOT/vendor/ghostty/zig-out/share"
if [ -d "$GHOSTTY_SHARE/ghostty" ] && [ -d "$GHOSTTY_SHARE/terminfo" ]; then
  cp -R "$GHOSTTY_SHARE/ghostty" "$APP/Contents/Resources/ghostty"
  cp -R "$GHOSTTY_SHARE/terminfo" "$APP/Contents/Resources/terminfo"
  echo "==> bundled $(ls "$APP/Contents/Resources/ghostty/themes" | wc -l | tr -d ' ') ghostty themes"
else
  echo "warning: no ghostty resources at $GHOSTTY_SHARE — themes will not resolve" >&2
  echo "warning: run ./scripts/build-libghostty.sh to produce them" >&2
fi

cp "$REPO_ROOT/NOTICE" "$APP/Contents/Resources/NOTICE"
cp -R "$REPO_ROOT/licenses" "$APP/Contents/Resources/licenses"

if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi

# Signed with a stable identity when one is available, ad-hoc otherwise.
#
# This matters more than it looks. macOS files every permission a user grants —
# Documents, Desktop, Full Disk Access — under the app's *designated
# requirement*, and an ad-hoc signature's requirement is the cdhash of that one
# build. Every release was therefore a different app as far as macOS was
# concerned, and everything had to be granted again after every update. A real
# certificate makes the requirement `identifier "com.rune.rune" and certificate
# leaf = H"…"`, which is the same for every build it ever signs.
#
# Deliberately not `--options runtime`: the hardened runtime is a prerequisite
# for notarization, which this certificate cannot do anyway, and turning it on
# would add restrictions the app has never been tested against.
if [ -n "${RUNE_SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp=none --sign "$RUNE_SIGN_IDENTITY" \
    ${RUNE_SIGN_KEYCHAIN:+--keychain "$RUNE_SIGN_KEYCHAIN"} "$APP"
  echo "==> signed as $RUNE_SIGN_IDENTITY"
else
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    || echo "warning: ad-hoc codesign failed; the app may not launch correctly" >&2
fi

echo "==> $APP ($(lipo -archs "$APP/Contents/MacOS/Rune"))"
