#!/usr/bin/env bash
# Rasterize Resources/icon.svg into Resources/AppIcon.icns.
#
# Uses NSImage's native SVG support (macOS 13+) so there is no dependency on
# rsvg or ImageMagick. The generated icns is committed, so this only needs to
# run again when the mark itself changes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$REPO_ROOT/Resources/icon.svg"
ICONSET="$(mktemp -d)/AppIcon.iconset"
ICNS="$REPO_ROOT/Resources/AppIcon.icns"

mkdir -p "$ICONSET"

swift - "$SVG" "$ICONSET" <<'EOF'
import AppKit

let svg = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: svg) else {
    fatalError("could not read \(svg.path) as an image")
}

// name -> pixel size, per iconutil's expected iconset layout.
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in variants {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not make a \(px)px bitmap") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
               from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(name).png")
    }
    try! png.write(to: outDir.appendingPathComponent("\(name).png"))
}
EOF

iconutil -c icns "$ICONSET" -o "$ICNS"
rm -rf "$(dirname "$ICONSET")"
echo "==> $ICNS"
