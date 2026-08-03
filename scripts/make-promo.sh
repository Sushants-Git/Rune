#!/usr/bin/env bash
# Render build/rune-promo.mp4 from a recorded demo.
#
#   RUNE_FILM=1 build/Rune.app/Contents/MacOS/Rune   # record the demo
#   ./scripts/make-promo.sh                          # composite + encode
#
# The frames are the running app, captured by the RUNE_FILM harness — not a
# mockup, so the video can't drift from the product. This script only frames
# them: a title card, the window on a desk, captions, and an end card.
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

# A macOS wallpaper, blurred to within an inch of its life. A flat backdrop left
# the window looking pasted on; this reads as a desk without competing with it.
WALLPAPER="${WALLPAPER:-/System/Library/Desktop Pictures/Radial Sky Blue.heic}"

[ -f "$FILM/script.json" ] || {
  echo "error: no recording at $FILM — run the RUNE_FILM harness first" >&2; exit 1; }

rm -rf "$FRAMES"; mkdir -p "$FRAMES" "$REPO_ROOT/build"

swift - "$FILM" "$FRAMES" "$WALLPAPER" <<'SWIFT'
import AppKit
import CoreImage

let film = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
let wallpaper = URL(fileURLWithPath: CommandLine.arguments[3])

let script = try! JSONSerialization.jsonObject(
    with: Data(contentsOf: film.appendingPathComponent("script.json"))) as! [String: Any]
// The capture runs at whatever rate a live terminal allows, so frames arrive
// unevenly and the recording is timestamped rather than counted. Everything
// below works in seconds and resamples to a steady 30fps on the way out.
let fps = 30.0
let duration = script["duration"] as! Double
let times = script["times"] as! [Double]
let marks = (script["marks"] as! [[String: Any]]).map {
    (time: $0["time"] as! Double, key: $0["key"] as? String, caption: $0["caption"] as! String)
}

/// The captured frame showing at a given moment.
func capture(at t: Double) -> Int {
    var index = 0
    for (i, stamp) in times.enumerated() where stamp <= t { index = i }
    return index
}

let W = 1920.0, H = 1080.0

let ink = NSColor(calibratedWhite: 0.98, alpha: 1)
let dim = NSColor(calibratedWhite: 0.68, alpha: 1)
let marker = NSColor(calibratedRed: 1, green: 0.886, blue: 0.478, alpha: 1)
let slate = NSColor(calibratedWhite: 0.08, alpha: 1)

func font(_ size: Double, _ weight: NSFont.Weight = .regular) -> NSFont {
    .systemFont(ofSize: size, weight: weight)
}

func attributed(_ s: String, _ f: NSFont, _ colour: NSColor, alpha: Double) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [
        .font: f, .foregroundColor: colour.withAlphaComponent(alpha)])
}

/// `y` is the bottom of the line; the string is centred on `centreX`.
func text(_ s: String, _ f: NSFont, _ colour: NSColor,
          centreX: Double, y: Double, alpha: Double = 1) {
    let a = attributed(s, f, colour, alpha: alpha)
    a.draw(at: CGPoint(x: centreX - a.size().width / 2, y: y))
}

// MARK: - Backdrop

/// The wallpaper, scaled to fill, blurred and dimmed. Built once — it is the
/// same 1920x1080 pixels in every frame.
let backdrop: CGImage = {
    guard let source = CIImage(contentsOf: wallpaper) else {
        fatalError("no wallpaper at \(wallpaper.path)")
    }
    let scale = max(W / source.extent.width, H / source.extent.height)
    let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let frame = CGRect(x: scaled.extent.midX - W / 2, y: scaled.extent.midY - H / 2,
                       width: W, height: H)
    // Clamped first, or the blur drags transparency in from beyond the edges.
    let blurred = scaled.cropped(to: frame).clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 70])
    return CIContext().createCGImage(blurred, from: frame)!
}()

func drawBackdrop(_ ctx: CGContext) {
    ctx.draw(backdrop, in: CGRect(x: 0, y: 0, width: W, height: H))
    // Dark enough that a dark window is still the brightest thing in frame.
    ctx.setFillColor(NSColor(calibratedWhite: 0.02, alpha: 0.66).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
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

/// The caption in force at a moment, and when it arrived.
func caption(at t: Double) -> ((key: String?, caption: String), Double)? {
    var current: ((String?, String), Double)?
    for m in marks where m.time <= t { current = ((m.key, m.caption), m.time) }
    return current
}

/// A shortcut on a key cap, then the line that goes with it, centred as one
/// group. The cap carries the shortcut so the sentence doesn't have to, which
/// keeps the line short enough to take in at a glance.
func captionLine(_ key: String?, _ line: String, baseline: Double,
                 _ ctx: CGContext, alpha: Double) {
    let capFont = font(31, .semibold), lineFont = font(40, .medium)
    let body = attributed(line, lineFont, ink, alpha: alpha)
    let centre = baseline + body.size().height / 2

    var cap: NSAttributedString?
    var capWidth = 0.0
    if let key {
        cap = attributed(key, capFont, slate, alpha: alpha)
        capWidth = max(cap!.size().width + 34, 62)
    }
    let gap = key == nil ? 0.0 : 22.0
    var x = W / 2 - (capWidth + gap + body.size().width) / 2

    if let cap {
        let height = 56.0
        let rect = CGRect(x: x, y: centre - height / 2, width: capWidth, height: height)
        ctx.setFillColor(marker.withAlphaComponent(alpha).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.fillPath()
        cap.draw(at: CGPoint(x: rect.midX - cap.size().width / 2,
                             y: centre - cap.size().height / 2))
        x += capWidth + gap
    }
    body.draw(at: CGPoint(x: x, y: baseline))
}

// MARK: - Timeline

let intro = Int(1.1 * fps)
let shot = Int(duration * fps)
let outro = Int(2.2 * fps)
let total = intro + shot + outro

// The window, and the room around it. The band under it belongs to the caption
// and nothing else — the eye learns after one beat where to look.
let windowWidth = 1400.0
let topMargin = 80.0
let captionBaseline = 92.0

/// The last frame that loaded, for ticks where the capture dropped one.
var held: NSImage?

for frame in 0..<total {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let ctx = graphics.cgContext

    drawBackdrop(ctx)

    if frame < intro {
        // Held briefly and gone: the demo is the pitch, not the title card.
        let p = Double(frame) / Double(intro)
        let alpha = min(1, p * 4) * (p > 0.82 ? (1 - p) / 0.18 : 1)
        mark(at: CGPoint(x: W / 2, y: H / 2 + 96), side: 132, ctx, alpha: alpha)
        text("Rune", font(84, .semibold), ink, centreX: W / 2, y: H / 2 - 52, alpha: alpha)
        text("The terminal for humans who run agents.", font(34), dim,
             centreX: W / 2, y: H / 2 - 124, alpha: alpha)
    } else if frame < intro + shot {
        let elapsed = Double(frame - intro) / fps
        // A dropped capture holds the frame before it. Skipping would leave a
        // hole in the numbering, and ffmpeg stops at the first one it hits.
        if let image = NSImage(contentsOf: film.appendingPathComponent(
            String(format: "%04d.png", capture(at: elapsed)))) { held = image }
        guard let image = held else { continue }

        let size = CGSize(width: windowWidth,
                          height: windowWidth * image.size.height / image.size.width)
        let rect = CGRect(x: (W - windowWidth) / 2, y: H - size.height - topMargin,
                          width: windowWidth, height: size.height)
        let rounded = CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 90,
                      color: NSColor(calibratedWhite: 0, alpha: 0.75).cgColor)
        ctx.addPath(rounded)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(rounded)
        ctx.clip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        ctx.restoreGState()

        // A hairline, or the dark window dissolves into the dark backdrop.
        ctx.addPath(rounded)
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.11).cgColor)
        ctx.setLineWidth(2)
        ctx.strokePath()

        if let (line, since) = caption(at: elapsed) {
            // Each caption rises as it arrives, so a cut reads as a cut.
            let age = elapsed - since
            let eased = 1 - pow(1 - min(age / 0.28, 1), 3)
            captionLine(line.key, line.caption, baseline: captionBaseline + eased * 10,
                        ctx, alpha: min(1, age / 0.18))
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
        let width = attributed(url, urlFont, ink, alpha: 1).size().width + 24
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
