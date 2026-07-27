#!/usr/bin/env bash
# Build GhosttyKit.xcframework (the libghostty embedding API) from the
# vendored ghostty checkout.
#
#   ./scripts/build-libghostty.sh            # Debug, native arch
#   MODE=ReleaseFast ./scripts/build-libghostty.sh
#   TARGET=universal ./scripts/build-libghostty.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/vendor/ghostty"
MODE="${MODE:-Debug}"
TARGET="${TARGET:-native}"

if [ ! -d "$GHOSTTY_DIR" ]; then
  "$REPO_ROOT/scripts/fetch-ghostty.sh"
fi

command -v zig >/dev/null || { echo "error: zig not on PATH (brew install zig)" >&2; exit 1; }

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
