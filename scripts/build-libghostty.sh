#!/usr/bin/env bash
# Build GhosttyKit.xcframework (the libghostty embedding API) from the
# vendored ghostty checkout.
#
#   ./scripts/build-libghostty.sh            # ReleaseFast, native arch
#   MODE=Debug ./scripts/build-libghostty.sh # only if you're debugging ghostty
#   TARGET=universal ./scripts/build-libghostty.sh
#
# ReleaseFast by default, deliberately. libghostty is the renderer, the VT
# parser and the font shaper: everything that runs per cell, per frame. A Zig
# Debug build leaves every bounds and overflow check in and optimises nothing,
# which does not read as "a debug build" when you use it. It reads as a slow
# terminal, and it cost a long time to track down once.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/vendor/ghostty"
MODE="${MODE:-ReleaseFast}"
TARGET="${TARGET:-native}"

if [ ! -d "$GHOSTTY_DIR" ]; then
  "$REPO_ROOT/scripts/fetch-ghostty.sh"
fi

command -v zig >/dev/null || { echo "error: zig not on PATH (brew install zig)" >&2; exit 1; }

# Ghostty compiles its Metal shaders via `xcrun -sdk macosx metal`. Since Xcode 26
# the Metal compiler ships as a separately downloaded component, and on some Xcode
# installs the plain `xcrun metal` shim fails to find it even once installed. If
# that's the case, pin TOOLCHAINS to the Metal toolchain so xcrun resolves it.
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  METAL_TOOLCHAIN="$(xcodebuild -showComponent MetalToolchain 2>/dev/null \
    | awk -F': ' '/^Toolchain Identifier:/ {print $2}')"
  if [ -z "${METAL_TOOLCHAIN:-}" ]; then
    echo "error: Metal toolchain missing. Run: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
  fi
  export TOOLCHAINS="$METAL_TOOLCHAIN"
  echo "==> using Metal toolchain $TOOLCHAINS"
fi

echo "==> building libghostty ($MODE, $TARGET)"
(
  cd "$GHOSTTY_DIR"
  zig build \
    -Demit-xcframework=true \
    -Demit-macos-app=false \
    -Dxcframework-target="$TARGET" \
    -Doptimize="$MODE"
)

XCFRAMEWORK="$GHOSTTY_DIR/macos/GhosttyKit.xcframework"
[ -d "$XCFRAMEWORK" ] || { echo "error: expected $XCFRAMEWORK" >&2; exit 1; }
echo "==> $XCFRAMEWORK"
