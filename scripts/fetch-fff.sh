#!/usr/bin/env bash
# Download the pinned fff C library (github.com/dmtrKovalenko/fff) and build
# vendor/fff/libfff_c.dylib, universal, for ⌘L's transcript search.
#
# Pinned by version *and* checksum in FFF_VERSION: a release asset can be
# replaced after the fact, and this library runs inside Rune.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$REPO_ROOT/FFF_VERSION"
OUT="$REPO_ROOT/vendor/fff"
VERSION="$(sed -n 1p "$PIN")"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: bad version in FFF_VERSION" >&2; exit 1; }

if [ -f "$OUT/libfff_c.dylib" ] && [ "$(cat "$OUT/VERSION" 2>/dev/null)" = "$VERSION" ]; then
  echo "fff $VERSION already in vendor/fff"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for arch in aarch64 x86_64; do
  want="$(awk -v a="$arch" '$1 == a { print $2 }' "$PIN")"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "error: no checksum for $arch in FFF_VERSION" >&2; exit 1; }
  url="https://github.com/dmtrKovalenko/fff/releases/download/$VERSION/c-lib-$arch-apple-darwin.dylib"
  curl -fsSL --retry 3 -o "$WORK/$arch.dylib" "$url"
  got="$(shasum -a 256 "$WORK/$arch.dylib" | awk '{ print $1 }')"
  [ "$got" = "$want" ] || { echo "error: checksum mismatch for $arch ($got)" >&2; exit 1; }
done

mkdir -p "$OUT"
lipo -create "$WORK/aarch64.dylib" "$WORK/x86_64.dylib" -output "$WORK/libfff_c.dylib"
# The release is built with its CI checkout's path as its install name; it is
# loaded by path at run time, but a sensible id costs nothing.
install_name_tool -id @rpath/libfff_c.dylib "$WORK/libfff_c.dylib" 2>/dev/null
# Changing the id invalidates the signature it shipped with, and macOS kills
# any process that loads a library whose signature doesn't check out — so it
# is re-signed here, ad hoc. bundle.sh signs it again with Rune's identity.
codesign --force --sign - --timestamp=none "$WORK/libfff_c.dylib"
mv "$WORK/libfff_c.dylib" "$OUT/libfff_c.dylib"
echo "$VERSION" > "$OUT/VERSION"
echo "fff $VERSION -> vendor/fff/libfff_c.dylib ($(lipo -archs "$OUT/libfff_c.dylib"))"
