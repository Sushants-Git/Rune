#!/usr/bin/env bash
# Clone (or update) the pinned ghostty checkout used to build libghostty.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_DIR="$REPO_ROOT/vendor/ghostty"
GHOSTTY_URL="https://github.com/ghostty-org/ghostty.git"
GHOSTTY_REF="$(cat "$REPO_ROOT/GHOSTTY_COMMIT")"

[[ "$GHOSTTY_REF" =~ ^[0-9a-f]{40}$ ]] || { echo "error: GHOSTTY_COMMIT must be a full commit SHA" >&2; exit 1; }

if [ ! -e "$GHOSTTY_DIR/.git" ]; then
  mkdir -p "$(dirname "$GHOSTTY_DIR")"
  # Cache restores may have populated ignored build outputs here already.
  git init "$GHOSTTY_DIR"
  git -C "$GHOSTTY_DIR" remote add origin "$GHOSTTY_URL"
fi

if git -C "$GHOSTTY_DIR" rev-parse --verify HEAD >/dev/null 2>&1 &&
   [ -n "$(git -C "$GHOSTTY_DIR" status --porcelain --untracked-files=normal)" ]; then
  echo "error: vendor/ghostty has local changes; preserve them before fetching" >&2
  exit 1
fi

if [ "$(git -C "$GHOSTTY_DIR" rev-parse --verify HEAD 2>/dev/null || true)" != "$GHOSTTY_REF" ]; then
  git -C "$GHOSTTY_DIR" fetch --no-tags --depth 1 "$GHOSTTY_URL" "$GHOSTTY_REF"
fi
git -C "$GHOSTTY_DIR" checkout --detach "$GHOSTTY_REF"

echo "ghostty checked out at $GHOSTTY_REF"
