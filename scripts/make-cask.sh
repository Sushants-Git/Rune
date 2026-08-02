#!/usr/bin/env bash
# Generate the Homebrew cask for a released version.
#
#   VERSION=0.6.0 ./scripts/make-cask.sh            # print it
#   VERSION=0.6.0 ./scripts/make-cask.sh > Casks/rune.rb
#
# The cask goes in a tap repository — a GitHub repo named `homebrew-rune` —
# not in this one, because that's where `brew tap` looks. This script lives here
# because the version, the asset name and the bundle identifier do, and a cask
# that disagrees with any of them fails at install time rather than at review.
#
# The sha256 has to be of the exact bytes GitHub serves, so it's computed from
# the published asset rather than from a local build: two builds of the same
# commit are not byte-identical, and a cask whose checksum matches only the
# machine that generated it is worse than no cask.
set -euo pipefail

REPO="${REPO:-Sushants-Git/Rune}"
VERSION="${VERSION:?set VERSION, e.g. VERSION=0.6.0}"
ASSET="Rune-v${VERSION}-macos-universal.zip"
URL="https://github.com/${REPO}/releases/download/v${VERSION}/${ASSET}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Prefer the plain public URL, because that is what `brew` itself will use — if
# this fails, brew will fail the same way, and it's better to find out here.
if ! curl -fsSL --retry 2 -o "$WORK/$ASSET" "$URL" 2>/dev/null; then
  echo "note: $URL is not publicly downloadable; falling back to gh" >&2
  echo "      (brew cannot install from a private repository — see README)" >&2
  gh release download "v${VERSION}" --repo "$REPO" --pattern "$ASSET" --dir "$WORK"
fi

SHA="$(shasum -a 256 "$WORK/$ASSET" | cut -d' ' -f1)"

cat <<CASK
cask "rune" do
  version "${VERSION}"
  sha256 "${SHA}"

  url "https://github.com/${REPO}/releases/download/v#{version}/Rune-v#{version}-macos-universal.zip",
      verified: "github.com/${REPO}/"
  name "Rune"
  desc "Terminal for running several coding agents side by side"
  homepage "https://github.com/${REPO}"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Rune ships its own updater — "Check for Updates…" in the app menu — so
  # Homebrew should not treat a self-updated copy as a version mismatch.
  auto_updates true
  depends_on macos: :ventura

  app "Rune.app"

  zap trash: [
    "~/Library/Preferences/com.rune.rune.plist",
    "~/Library/Saved Application State/com.rune.rune.savedState",
  ]
end
CASK
