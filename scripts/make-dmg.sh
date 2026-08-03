#!/usr/bin/env bash
# Build build/Rune-v<version>-macos-<arch>.dmg from build/Rune.app.
#
#   ./scripts/make-dmg.sh                 # version comes from the built app
#   VERSION=0.7.6 ./scripts/make-dmg.sh
#   PLAIN=1 ./scripts/make-dmg.sh         # skip the Finder dressing
#
# A disk image alongside the zip rather than instead of it. They answer
# different questions: the zip is what the in-app updater downloads and unpacks
# with no one watching, and the dmg is what a person opens — it mounts with an
# Applications symlink beside the app, so installing is the drag everyone
# already knows.
#
# That drag is also the fix for Rune not appearing in Raycast or Spotlight:
# both index /Applications and nowhere else, so an app left in ~/Downloads is
# invisible to them. A zip encourages exactly that mistake; a dmg with a visible
# /Applications target doesn't.
#
# The window is dressed: a drawn background, the two icons placed either side of
# an arrow, and Rune's own icon on the volume. All of it is *best effort* —
# arranging a Finder window means scripting Finder, which is not guaranteed to
# be available on a build machine, so a failure there downgrades to a plain
# image rather than failing the release. A plain dmg still installs correctly;
# it just looks like a folder.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${APP:-$REPO_ROOT/build/Rune.app}"
[ -d "$APP" ] || { echo "error: no app at $APP — run ./scripts/bundle.sh" >&2; exit 1; }

VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$APP/Contents/Info.plist")}"

# Named after what's actually inside. A local build is usually native-only, and
# a file called "universal" that runs on one architecture is the kind of thing
# nobody notices until an Intel user does.
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Rune")"
case "$ARCHS" in
  *arm64*\ *x86_64*|*x86_64*\ *arm64*) SLICE="universal" ;;
  *) SLICE="$(echo "$ARCHS" | tr -d ' ')" ;;
esac
DMG="$REPO_ROOT/build/Rune-v${VERSION}-macos-${SLICE}.dmg"

VOLUME="Rune ${VERSION}"
WORK="$(mktemp -d)"
STAGING="$WORK/Rune"
MOUNT=""
mkdir -p "$STAGING"
cleanup() {
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ditto rather than cp: an app bundle has symlinks and extended attributes, and
# a copy that loses them is a bundle that won't launch.
ditto "$APP" "$STAGING/Rune.app"
ln -s /Applications "$STAGING/Applications"

# ---------------------------------------------------------------------------
# The window's furniture: a background to drag across, and an icon for the
# volume itself so the mounted disk isn't a generic white drive.
# ---------------------------------------------------------------------------
WINDOW_WIDTH=660
WINDOW_HEIGHT=420

if [ -z "${PLAIN:-}" ]; then
  mkdir -p "$STAGING/.background"
  swift - "$STAGING/.background/background.tiff" "$WINDOW_WIDTH" "$WINDOW_HEIGHT" <<'SWIFT'
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let width = Double(CommandLine.arguments[2])!, height = Double(CommandLine.arguments[3])!

/// Drawn at 1x and 2x into one TIFF. Finder picks the representation matching
/// the display, which is the only way to get a background that isn't soft on a
/// retina screen — a single 2x PNG is drawn at its pixel size and overflows the
/// window instead of filling it.
func draw(scale: Double) -> NSBitmapImageRep {
    let pixelsWide = Int(width * scale), pixelsHigh = Int(height * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    // No manual scaling: setting `rep.size` to the point size while the bitmap
    // is `scale` times that already establishes the transform. Scaling again
    // squares it, and the 2x layer lands drawn at 4x — mostly off-canvas, which
    // is what the first attempt shipped.

    // The same near-black the app icon is built from, so the window and the
    // thing you're dragging out of it look like one product.
    let colours = [
        NSColor(calibratedRed: 0.109, green: 0.109, blue: 0.113, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.063, green: 0.063, blue: 0.067, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
    }

    // An arrow between where the two icons sit. Drawn low-contrast on purpose:
    // it is a hint about direction, not the subject of the window.
    let midY = height - 200
    let from = 250.0, to = 410.0
    context.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.22).cgColor)
    context.setLineWidth(2)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: from, y: midY))
    context.addLine(to: CGPoint(x: to - 12, y: midY))
    context.strokePath()

    context.setStrokeColor(NSColor(calibratedRed: 1, green: 0.886, blue: 0.478, alpha: 0.85).cgColor)
    context.setLineWidth(2.4)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: to - 22, y: midY + 9))
    context.addLine(to: CGPoint(x: to - 8, y: midY))
    context.addLine(to: CGPoint(x: to - 22, y: midY - 9))
    context.strokePath()

    func write(_ text: String, size: Double, weight: NSFont.Weight, alpha: Double, y: Double) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: alpha),
            .paragraphStyle: style,
        ]
        NSAttributedString(string: text, attributes: attributes)
            .draw(in: NSRect(x: 0, y: y, width: width, height: size * 2))
    }

    write("Drag Rune into Applications", size: 15, weight: .medium, alpha: 0.82, y: 96)
    // Where it has to end up, and why — the reason this window exists at all.
    write("Anywhere else and Spotlight and Raycast won't find it",
          size: 11.5, weight: .regular, alpha: 0.38, y: 72)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: NSSize(width: width, height: height))
image.addRepresentation(draw(scale: 1))
image.addRepresentation(draw(scale: 2))
try! image.tiffRepresentation!.write(to: output)
SWIFT

fi

# ---------------------------------------------------------------------------
# Build it writable first: a compressed image can't be rearranged, and the
# arrangement is the whole point of the dressing.
# ---------------------------------------------------------------------------
RW="$WORK/rw.dmg"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGING" -fs HFS+ \
  -format UDRW -quiet "$RW"

# Mounted browsable — *without* -nobrowse — because Finder can only script a
# disk it has been told about; a hidden mount fails with "Can't get disk".
#
# And the mount point is read back rather than assumed to be /Volumes/$VOLUME.
# If anything already holds that name, macOS silently mounts at "…$VOLUME 1"
# and the assumed path resolves to a directory that doesn't exist on the
# read-only system volume — so every write fails and the image ships plain.
MOUNT="$(hdiutil attach "$RW" | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | tail -1)"
[ -n "$MOUNT" ] && [ -d "$MOUNT" ] || { echo "error: could not mount $RW" >&2; exit 1; }
# Finder addresses the disk by the name it actually got, suffix and all.
VOLUME="$(basename "$MOUNT")"

if [ -z "${PLAIN:-}" ]; then
  # And the layout. `|| true` throughout: a build machine with no Finder to
  # script still has to produce a working image.
  if ! osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {240, 130, $((240 + WINDOW_WIDTH)), $((130 + WINDOW_HEIGHT + 22))}
    set options to the icon view options of container window
    set arrangement of options to not arranged
    set icon size of options to 112
    set background picture of options to file ".background:background.tiff"
    set position of item "Rune.app" of container window to {170, 196}
    set position of item "Applications" of container window to {490, 196}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
APPLESCRIPT
  then
    echo "note: could not arrange the window (no Finder here?); shipping it plain" >&2
  fi

  # Rune's icon on the volume itself, last. Two traps here, both of which
  # produce a plain white disk while every command reports success:
  # `hdiutil create -srcfolder` drops .VolumeIcon.icns on the way in, so it has
  # to be written to the mounted volume; and Finder deletes it again when it
  # opens the window, so it has to be written *after* the arranging.
  cp "$REPO_ROOT/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
  SetFile -a C "$MOUNT" 2>/dev/null || echo "note: could not set the volume icon" >&2
fi

sync
hdiutil detach "$MOUNT" -quiet

rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -quiet -o "$DMG"

echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
