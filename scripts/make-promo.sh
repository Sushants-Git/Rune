#!/usr/bin/env bash
# Render build/rune-promo.mp4 from a recorded demo.
#
#   RUNE_FILM=1 build/Rune.app/Contents/MacOS/Rune   # record the demo
#   ./scripts/make-promo.sh                          # composite + encode
#
# The frames are the running app, captured by the RUNE_FILM harness — not a
# mockup, so the video can't drift from the product. This script only frames
# them: a title card, the window on a dark stage, captions, and an end card.
#
# Captions come from the script the harness wrote *as it recorded*, rather than
# being listed again here. Two lists of timings is one too many; they drift the
# first time a beat moves.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-/tmp/promo}"
FILM="$WORK/film"
FRAMES="$WORK/out"
OUT="$REPO_ROOT/build/rune-promo.mp4"

[ -f "$FILM/script.json" ] || {
  echo "error: no recording at $FILM — run the RUNE_FILM harness first" >&2; exit 1; }

rm -rf "$FRAMES"; mkdir -p "$FRAMES" "$REPO_ROOT/build"

swift - "$FILM" "$FRAMES" <<'SWIFT'
import AppKit

let film = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])

let script = try! JSONSerialization.jsonObject(
    with: Data(contentsOf: film.appendingPathComponent("script.json"))) as! [String: Any]
let fps = script["fps"] as! Double
let shot = script["frames"] as! Int
let marks = (script["marks"] as! [[String: Any]]).map {
    (frame: $0["frame"] as! Int, caption: $0["caption"] as! String)
}

let W = 1920.0, H = 1080.0

// A dark stage: the product is dark, and a white surround would blow out beside
// it in a timeline full of other people's videos.
let stage = NSColor(calibratedWhite: 0.055, alpha: 1)
let ink = NSColor(calibratedWhite: 0.97, alpha: 1)
let dim = NSColor(calibratedWhite: 0.62, alpha: 1)
let marker = NSColor(calibratedRed: 1, green: 0.886, blue: 0.478, alpha: 1)

func font(_ size: Double, _ weight: NSFont.Weight = .regular) -> NSFont {
    .systemFont(ofSize: size, weight: weight)
}

/// `y` is the bottom of the line; the string is centred on `centreX`.
func text(_ s: String, _ f: NSFont, _ colour: NSColor,
          centreX: Double, y: Double, alpha: Double = 1) {
    let a = NSAttributedString(string: s, attributes: [
        .font: f, .foregroundColor: colour.withAlphaComponent(alpha)])
    a.draw(at: CGPoint(x: centreX - a.size().width / 2, y: y))
}

func mark(at centre: CGPoint, side: Double, _ ctx: CGContext, alpha: Double) {
    let rect = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
    let path = CGMutablePath()
    let a = side / 2, steps = 240
    for i in 0...steps {
        let t = 2 * Double.pi * Double(i) / Double(steps)
        let x = rect.midX + a * copysign(pow(abs(cos(t)), 2 / 5.5), cos(t))
        let y = rect.midY + a * copysign(pow(abs(sin(t)), 2 / 5.5), sin(t))
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(NSColor(calibratedWhite: 0.13, alpha: alpha).cgColor)
    ctx.fillPath()

    let unit = side / 32
    func p(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: rect.minX + x * unit, y: rect.maxY - y * unit)
    }
    ctx.setStrokeColor(NSColor(calibratedWhite: 0.99, alpha: alpha).cgColor)
    ctx.setLineWidth(2.6 * unit); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: p(9, 11.5)); ctx.addLine(to: p(13.5, 16)); ctx.addLine(to: p(9, 20.5))
    ctx.strokePath()
    ctx.setFillColor(marker.withAlphaComponent(alpha).cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: rect.minX + 16.5 * unit, y: rect.maxY - 21 * unit,
                                           width: 6.5 * unit, height: 10 * unit),
                       cornerWidth: unit, cornerHeight: unit, transform: nil))
    ctx.fillPath()
}

/// The caption in force at a frame, and when it arrived.
func caption(at frame: Int) -> (String, Int)? {
    var current: (String, Int)?
    for m in marks where m.frame <= frame { current = (m.caption, m.frame) }
    return current
}

// MARK: - Timeline

let intro = Int(1.1 * fps)
let outro = Int(2.0 * fps)
let total = intro + shot + outro

for frame in 0..<total {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let ctx = graphics.cgContext

    ctx.setFillColor(stage.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    if frame < intro {
        // Held briefly and gone: the demo is the pitch, not the title card.
        let p = Double(frame) / Double(intro)
        let alpha = min(1, p * 4) * (p > 0.82 ? (1 - p) / 0.18 : 1)
        mark(at: CGPoint(x: W / 2, y: H / 2 + 96), side: 132, ctx, alpha: alpha)
        text("Rune", font(84, .semibold), ink, centreX: W / 2, y: H / 2 - 52, alpha: alpha)
        text("The terminal for humans who run agents.", font(34), dim,
             centreX: W / 2, y: H / 2 - 124, alpha: alpha)
    } else if frame < intro + shot {
        let index = frame - intro
        guard let image = NSImage(contentsOf:
            film.appendingPathComponent(String(format: "%04d.png", index))) else { continue }

        // Large enough to be the subject, with room under it for one line.
        let width = 1560.0
        let size = CGSize(width: width, height: width * image.size.height / image.size.width)
        let rect = CGRect(x: (W - width) / 2, y: H - size.height - 92,
                          width: width, height: size.height)
        let rounded = CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 70,
                      color: NSColor(calibratedWhite: 0, alpha: 0.65).cgColor)
        ctx.addPath(rounded)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(rounded)
        ctx.clip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        ctx.restoreGState()

        // A hairline, or the dark window dissolves into the dark stage.
        ctx.addPath(rounded)
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.09).cgColor)
        ctx.setLineWidth(2)
        ctx.strokePath()

        if let (line, since) = caption(at: index) {
            // Each caption rises as it arrives, so a cut reads as a cut.
            let age = Double(index - since) / fps
            let eased = 1 - pow(1 - min(age / 0.28, 1), 3)
            text(line, font(40, .medium), ink,
                 centreX: W / 2, y: 30 + eased * 8, alpha: min(1, age / 0.18))
        }
    } else {
        let p = Double(frame - intro - shot) / Double(outro)
        let alpha = min(1, p * 5)
        mark(at: CGPoint(x: W / 2, y: H / 2 + 132), side: 116, ctx, alpha: alpha)
        text("Free and open source.", font(50, .semibold), ink,
             centreX: W / 2, y: H / 2 - 16, alpha: alpha)
        // Under the text, not across it — at the baseline the bar read as a
        // strikethrough. Sized to the string so it underlines rather than
        // overhangs.
        let url = "github.com/Sushants-Git/Rune", urlFont = font(36, .medium)
        let width = NSAttributedString(string: url, attributes: [.font: urlFont])
            .size().width + 24
        ctx.setFillColor(marker.withAlphaComponent(0.9 * alpha).cgColor)
        ctx.fill(CGRect(x: W / 2 - width / 2, y: H / 2 - 132, width: width, height: 12))
        text(url, urlFont, ink, centreX: W / 2, y: H / 2 - 116, alpha: alpha)
        text("Universal · macOS 13+ · updates itself", font(26), dim,
             centreX: W / 2, y: 150, alpha: alpha * 0.8)
    }

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: out.appendingPathComponent(String(format: "%04d.png", frame)))
}
print("composited \(total) frames (\(String(format: "%.1f", Double(total) / fps))s)")
SWIFT

# yuv420p and even dimensions, or half the clients Twitter hands it to refuse it.
ffmpeg -y -loglevel error -framerate 30 -i "$FRAMES/%04d.png" \
  -c:v libx264 -preset slow -crf 19 -pix_fmt yuv420p -movflags +faststart \
  "$OUT"

echo "==> $OUT ($(du -h "$OUT" | cut -f1), $(ffprobe -v error \
  -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OUT" | cut -c1-4)s)"
