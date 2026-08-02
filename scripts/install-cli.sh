#!/usr/bin/env bash
# Put `rune` on your PATH.
#
#   ./scripts/install-cli.sh                 # symlink into the first writable
#                                            # of /usr/local/bin, ~/.local/bin
#   BIN=~/bin ./scripts/install-cli.sh       # somewhere specific
#   APP=/Applications/Rune.app ./scripts/install-cli.sh
#
# A symlink rather than a copy, so the command follows the app: after Rune
# updates itself, `rune --version` reports the new version without anyone
# remembering to reinstall anything. The binary is both the app and the tool —
# see CLI.swift for how it tells which one it's being.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Prefer an installed app over a build directory: a symlink into build/ breaks
# the moment someone runs a clean build, and does so silently.
if [ -z "${APP:-}" ]; then
  for candidate in "/Applications/Rune.app" "$HOME/Applications/Rune.app" \
                   "$REPO_ROOT/build/Rune.app"; do
    if [ -d "$candidate" ]; then APP="$candidate"; break; fi
  done
fi
[ -n "${APP:-}" ] && [ -d "$APP" ] || {
  echo "error: no Rune.app found. Build one (./scripts/bundle.sh) or set APP=." >&2
  exit 1
}

BINARY="$APP/Contents/MacOS/Rune"
[ -x "$BINARY" ] || { echo "error: no executable at $BINARY" >&2; exit 1; }

if [ -z "${BIN:-}" ]; then
  for candidate in "/usr/local/bin" "$HOME/.local/bin"; do
    if [ -d "$candidate" ] && [ -w "$candidate" ]; then BIN="$candidate"; break; fi
  done
  # Nothing writable existed; make the one that needs no privileges.
  BIN="${BIN:-$HOME/.local/bin}"
fi
mkdir -p "$BIN"

ln -sf "$BINARY" "$BIN/rune"
echo "==> $BIN/rune -> $BINARY"

case ":$PATH:" in
  *":$BIN:"*) "$BIN/rune" --version ;;
  *) echo "note: $BIN is not on your PATH. Add it:"
     echo "      echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.zshrc" ;;
esac
