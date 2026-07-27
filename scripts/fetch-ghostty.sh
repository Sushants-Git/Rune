#!/usr/bin/env bash
# Clone (or update) the pinned ghostty checkout used to build libghostty.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/vendor/ghostty"
GHOSTTY_URL="https://github.com/ghostty-org/ghostty.git"
GHOSTTY_REF="$(cat "$REPO_ROOT/GHOSTTY_COMMIT")"

if [ ! -d "$GHOSTTY_DIR/.git" ]; then
  mkdir -p "$(dirname "$GHOSTTY_DIR")"
  git clone "$GHOSTTY_URL" "$GHOSTTY_DIR"
fi

git -C "$GHOSTTY_DIR" fetch origin "$GHOSTTY_REF" --depth 1 2>/dev/null || git -C "$GHOSTTY_DIR" fetch origin
git -C "$GHOSTTY_DIR" checkout --detach "$GHOSTTY_REF"

echo "ghostty checked out at $GHOSTTY_REF"
