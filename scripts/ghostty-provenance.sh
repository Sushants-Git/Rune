#!/usr/bin/env bash
# Print reproducible build inputs, or validate the installed outputs with --check.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/vendor/ghostty"
MODE="${MODE:-ReleaseFast}"
TARGET="${TARGET:-native}"
case "$MODE" in Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;; *) echo "error: invalid MODE" >&2; exit 1 ;; esac
case "$TARGET" in native|universal) ;; *) echo "error: invalid TARGET" >&2; exit 1 ;; esac
PIN="$(cat "$REPO_ROOT/GHOSTTY_COMMIT")"
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] || { echo "error: invalid GHOSTTY_COMMIT" >&2; exit 1; }
[ "$(git -C "$GHOSTTY_DIR" rev-parse HEAD)" = "$PIN" ] || { echo "error: stale Ghostty checkout; run scripts/fetch-ghostty.sh" >&2; exit 1; }
[ -z "$(git -C "$GHOSTTY_DIR" status --porcelain --untracked-files=normal)" ] || { echo "error: dirty Ghostty checkout" >&2; exit 1; }
ZIG_VERSION="$(zig version)"
REQUIRED_ZIG="$(sed -n 's/.*\.minimum_zig_version = "\([^"]*\)".*/\1/p' "$GHOSTTY_DIR/build.zig.zon")"
[ -n "$REQUIRED_ZIG" ] && [ "$ZIG_VERSION" = "$REQUIRED_ZIG" ] || { echo "error: expected Zig $REQUIRED_ZIG, found $ZIG_VERSION" >&2; exit 1; }

# Resolve Metal identically on cache lookup and build, including Xcode 26's component.
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  TOOLCHAINS="$(xcodebuild -showComponent MetalToolchain 2>/dev/null | awk -F': ' '/^Toolchain Identifier:/ {print $2}')"
  [ -n "$TOOLCHAINS" ] || { echo "error: run xcodebuild -downloadComponent MetalToolchain" >&2; exit 1; }
  export TOOLCHAINS
fi
XCODE="$(xcodebuild -version)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_BUILD="$(xcrun --sdk macosx --show-sdk-build-version)"
METAL="$(xcrun -sdk macosx metal --version | sed '/^InstalledDir:/d')"
INFO="$(
  printf 'schema=1\ncommit=%s\nzig=%s\nmode=%s\ntarget=%s\nhost=%s\n' "$PIN" "$ZIG_VERSION" "$MODE" "$TARGET" "$(uname -m)"
  # The cryptex mount path is random per machine, not compiler identity.
  printf '%s\n' "$XCODE" "$SDK_VERSION" "$SDK_BUILD" "$METAL"
  cd "$REPO_ROOT"
  shasum -a 256 GHOSTTY_COMMIT scripts/fetch-ghostty.sh scripts/build-libghostty.sh scripts/ghostty-provenance.sh
)"
if [ "${1:-}" = --check ]; then
  [ -f "$GHOSTTY_DIR/zig-out/rune-build-info" ] &&
    [ "$(cat "$GHOSTTY_DIR/zig-out/rune-build-info")" = "$INFO" ] || {
      echo "error: missing/stale Ghostty provenance; run MODE=$MODE TARGET=$TARGET ./scripts/build-libghostty.sh" >&2; exit 1;
    }
  [ -d "$GHOSTTY_DIR/zig-out/share/ghostty/themes" ] && [ -d "$GHOSTTY_DIR/zig-out/share/terminfo" ] || {
    echo "error: missing Ghostty resources; rebuild libghostty" >&2; exit 1;
  }
  SLICE="macos-$(uname -m)"
  if [ "$TARGET" = universal ]; then SLICE=macos-arm64_x86_64; fi
  FRAMEWORK="$GHOSTTY_DIR/macos/GhosttyKit.xcframework"
  INDEX=0
  LIBRARY=""
  while IDENTIFIER="$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$INDEX:LibraryIdentifier" "$FRAMEWORK/Info.plist" 2>/dev/null)"; do
    if [ "$IDENTIFIER" = "$SLICE" ]; then
      LIBRARY="$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$INDEX:LibraryPath" "$FRAMEWORK/Info.plist")"
      break
    fi
    INDEX=$((INDEX + 1))
  done
  [ -n "$LIBRARY" ] || { echo "error: missing Ghostty framework slice $SLICE" >&2; exit 1; }
  cmp "$GHOSTTY_DIR/include/ghostty.h" "$FRAMEWORK/$SLICE/Headers/ghostty.h"
  if [ "$TARGET" = universal ]; then
    lipo "$FRAMEWORK/$SLICE/$LIBRARY" -verify_arch arm64 x86_64
  else
    lipo "$FRAMEWORK/$SLICE/$LIBRARY" -verify_arch "$(uname -m)"
  fi
  (cd "$GHOSTTY_DIR" && shasum -a 256 --check --status --strict zig-out/rune-build-checksums) || {
    echo "error: Ghostty artifacts changed or are incomplete; rebuild libghostty" >&2; exit 1;
  }
else
  printf '%s\n' "$INFO"
fi
