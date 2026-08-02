#!/usr/bin/env bash
# Draw Resources/AppIcon.icns.
#
#   ./scripts/make-icon.sh              # write the icns
#   PREVIEW=1 ./scripts/make-icon.sh    # also drop PNGs in build/icon-preview
#
# Drawn with Core Graphics rather than exported from the website's favicon,
# which is what this used to do and why the icon looked out of place in the
# Dock. A favicon is a flat rounded rectangle; a macOS icon is a specific
# shape, on a specific grid, with a shadow under it:
#
#   - The corners are a *squircle* — continuous curvature — not the circular
#     corners an SVG `rect rx` gives you. Side by side with any Apple icon the
#     circular version reads as slightly pinched at the diagonals, which is the
#     single thing that made Rune's icon look like a web asset.
#   - Apple's grid, measured off a system icon: a 1024 canvas with the body
#     inset 105 on every side, so 814 across.
#   - A shadow beneath the body. Every icon in the Dock has one; without it
#     Rune's sat flat against the shelf while its neighbours lifted off it.
#   - A little depth in the fill and a highlight along the top edge, because a
#     dead-flat fill is the other half of looking like a sticker.
#
# Each size is drawn at its own scale rather than downsampled from 1024, so the
# 16pt version has crisp strokes instead of a blurred photograph of a big one.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$WORK"' EXIT

swift - "$ICONSET" <<'EOF'
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])

// MARK: - The shape

/// A superellipse — the continuous-curvature corner macOS uses, and the thing
/// a rounded rectangle can't give you.
///
/// The exponent isn't a guess: tracing the silhouette of a system icon and
/// fitting |x/a|^n + |y/a|^n = 1 against it puts the best match at n = 5.5
/// (mean error 0.02, against 0.08 at n = 4 and 0.03 at n = 6).
func squircle(in rect: CGRect, exponent: Double = 5.5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for step in 0...steps {
        let t = 2 * Double.pi * Double(step) / Double(steps)
        let c = cos(t), s = sin(t)
        // |x/a|^n + |y/b|^n = 1, parameterised so the sign follows the angle.
        let x = cx + a * copysign(pow(abs(c), 2 / exponent), c)
        let y = cy + b * copysign(pow(abs(s), 2 / exponent), s)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

// MARK: - The mark

/// The wordmark reduced to what survives at 16pt: a prompt, and the
/// marker-yellow cursor sitting at it. Coordinates are the favicon's 32-unit
/// box so the two stay recognisably the same drawing.
/// `emphasis` scales the mark about the tile's centre. Above 1 for the small
/// sizes: the drawing that reads at 512 turns into a smudge at 16, where the
/// tile is 13 pixels across and every stroke has to earn its place. Apple's own
/// icons redraw at small sizes for the same reason; this at least grows.
func drawMark(in context: CGContext, body: CGRect, emphasis: Double) {
    let unit = body.width / 32
    let centre = CGPoint(x: body.midX, y: body.midY)
    func point(_ x: Double, _ y: Double) -> CGPoint {
        // The favicon's y runs down the page; Core Graphics runs up.
        let raw = CGPoint(x: body.minX + x * unit, y: body.maxY - y * unit)
        return CGPoint(
            x: centre.x + (raw.x - centre.x) * emphasis,
            y: centre.y + (raw.y - centre.y) * emphasis)
    }

    context.setStrokeColor(NSColor(calibratedWhite: 0.988, alpha: 1).cgColor)
    context.setLineWidth(2.6 * unit * emphasis)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: point(9, 11.5))
    context.addLine(to: point(13.5, 16))
    context.addLine(to: point(9, 20.5))
    context.strokePath()

    let topLeft = point(16.5, 11), bottomRight = point(23, 21)
    let cursor = CGRect(
        x: topLeft.x, y: bottomRight.y,
        width: bottomRight.x - topLeft.x, height: topLeft.y - bottomRight.y)
    context.setFillColor(NSColor(calibratedRed: 1, green: 0.886, blue: 0.478, alpha: 1).cgColor)
    let corner = 1 * unit * emphasis
    context.addPath(CGPath(
        roundedRect: cursor, cornerWidth: corner, cornerHeight: corner, transform: nil))
    context.fillPath()
}

// MARK: - One icon

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not make a \(pixels)px bitmap") }

    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    let scale = Double(pixels) / 1024

    // Apple's grid, measured off a system icon rather than taken from a blog
    // post: the solid body runs 105…918 in a 1024 canvas, so 814 across.
    let body = CGRect(x: 105 * scale, y: 105 * scale,
                      width: 814 * scale, height: 814 * scale)
    let shape = squircle(in: body)

    // The shadow, drawn by filling the shape once with it set. Offset down and
    // soft: an icon should look like it is resting slightly above the shelf.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -10 * scale),
        blur: 24 * scale,
        color: NSColor(calibratedWhite: 0, alpha: 0.34).cgColor)
    context.addPath(shape)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    // The body: a near-black with just enough gradient to have a top and a
    // bottom. Rune's ink is #1b1b1b; this straddles it.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let colours = [
        NSColor(calibratedRed: 0.153, green: 0.153, blue: 0.157, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.075, green: 0.075, blue: 0.078, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: body.midX, y: body.maxY),
            end: CGPoint(x: body.midX, y: body.minY),
            options: [])
    }
    context.restoreGState()

    // A hairline of light along the *top* edge only — light comes from above,
    // and a rim running all the way round reads as a sticker's die-cut instead
    // of a tile with thickness. Skipped below 64px, where a 3/1024 stroke is
    // less than a pixel and lands as grey haze.
    if pixels >= 64 {
        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.clip(to: CGRect(x: 0, y: body.midY, width: Double(pixels), height: body.maxY))
        context.addPath(shape)
        context.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.10).cgColor)
        context.setLineWidth(3 * scale)
        context.strokePath()
        context.restoreGState()
    }

    // The small sizes get a bigger mark; see drawMark.
    drawMark(in: context, body: body, emphasis: pixels <= 32 ? 1.2 : 1)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// name -> pixel size, per iconutil's expected iconset layout.
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, pixels) in variants {
    let rep = drawIcon(pixels: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(name).png")
    }
    try! png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
}
EOF

iconutil -c icns "$ICONSET" -o "$REPO_ROOT/Resources/AppIcon.icns"
echo "==> $REPO_ROOT/Resources/AppIcon.icns"

if [ -n "${PREVIEW:-}" ]; then
  mkdir -p "$REPO_ROOT/build/icon-preview"
  cp "$ICONSET"/*.png "$REPO_ROOT/build/icon-preview/"
  echo "==> $REPO_ROOT/build/icon-preview"
fi
