#!/usr/bin/env bash
# Render build/rune-promo.mp4 — a short slide video introducing Rune.
#
#   ./scripts/make-promo.sh
#
# Frames are drawn one at a time rather than crossfading stills in ffmpeg, so
# the motion is decided here: content settles upward as it fades in, and slides
# dissolve into each other. One ffmpeg call turns them into H.264.
#
# The switcher on slide 3 is a real render of the real view — see the
# RUNE_PROMO harness — not a mockup. The states are fabricated, the pixels
# aren't.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-/tmp/promo}"
FRAMES="$WORK/frames"
SWITCHER="$WORK/switcher.png"
OUT="$REPO_ROOT/build/rune-promo.mp4"

[ -f "$SWITCHER" ] || {
  echo "error: $SWITCHER missing — run the RUNE_PROMO harness first" >&2; exit 1; }

rm -rf "$FRAMES"; mkdir -p "$FRAMES"

swift - "$FRAMES" "$SWITCHER" <<'SWIFT'
import AppKit

let frames = URL(fileURLWithPath: CommandLine.arguments[1])
let switcher = NSImage(contentsOfFile: CommandLine.arguments[2])!

let W = 1920.0, H = 1080.0, FPS = 24.0

// The website's palette, so the video and the page are the same product.
let page = NSColor(calibratedRed: 0.988, green: 0.988, blue: 0.988, alpha: 1)
let ink = NSColor(calibratedWhite: 0.105, alpha: 1)
let muted = NSColor(calibratedWhite: 0.42, alpha: 1)
let marker = NSColor(calibratedRed: 1, green: 0.886, blue: 0.478, alpha: 1)
let working = NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.42, alpha: 1)
let turn = NSColor(calibratedRed: 0.29, green: 0.56, blue: 0.99, alpha: 1)

func font(_ size: Double, _ weight: NSFont.Weight = .regular) -> NSFont {
    .systemFont(ofSize: size, weight: weight)
}

/// `y` is the *bottom* of the line, and the string is centred on `centreX`.
/// Drawing into a tall centred rect instead put the glyphs at the top of that
/// rect, so every position meant something other than it said and the wordmark
/// landed on top of the icon.
func text(_ s: String, _ f: NSFont, _ colour: NSColor, centreX: Double, y: Double,
          alpha: Double = 1) {
    let a = NSAttributedString(string: s, attributes: [
        .font: f, .foregroundColor: colour.withAlphaComponent(alpha),
    ])
    let size = a.size()
    a.draw(at: CGPoint(x: centreX - size.width / 2, y: y))
}

/// Rune's mark, drawn rather than loaded: the icns is a squircle with a shadow,
/// and on a light slide the tile alone is enough.
func mark(at centre: CGPoint, side: Double, _ ctx: CGContext, alpha: Double) {
    let rect = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
    let path = CGMutablePath()
    let a = side / 2, steps = 240
    for i in 0...steps {
        let t = 2 * Double.pi * Double(i) / Double(steps)
        let x = rect.midX + a * copysign(pow(abs(cos(t)), 2 / 5.5), cos(t))
        let y = rect.midY + a * copysign(pow(abs(sin(t)), 2 / 5.5), sin(t))
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.02), blur: side * 0.05,
                  color: NSColor(calibratedWhite: 0, alpha: 0.18 * alpha).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor(calibratedWhite: 0.10, alpha: alpha).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

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

func chip(_ label: String, tone: NSColor, at centre: CGPoint, _ ctx: CGContext, alpha: Double) {
    let f = font(30, .medium)
    let width = label.size(withAttributes: [.font: f]).width + 108
    let rect = CGRect(x: centre.x - width / 2, y: centre.y - 32, width: width, height: 64)
    ctx.setFillColor(tone.withAlphaComponent(0.13 * alpha).cgColor)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(tone.withAlphaComponent(alpha).cgColor)
    ctx.fillEllipse(in: CGRect(x: rect.minX + 26, y: centre.y - 7, width: 14, height: 14))
    let a = NSAttributedString(string: label, attributes: [
        .font: f, .foregroundColor: tone.withAlphaComponent(alpha)])
    a.draw(at: CGPoint(x: rect.minX + 56, y: centre.y - 19))
}

// MARK: - Slides

typealias Slide = (_ ctx: CGContext, _ progress: Double, _ alpha: Double) -> Void

// Everything drifts up a little as it arrives; `lift` is that offset.
func lift(_ progress: Double) -> Double {
    let eased = 1 - pow(1 - min(progress / 0.35, 1), 3)
    return (1 - eased) * 26
}

let slides: [(Double, Slide)] = [
    // 1 — what it is
    (3.4, { ctx, p, alpha in
        let dy = lift(p)
        mark(at: CGPoint(x: W / 2, y: H / 2 + 196 - dy), side: 168, ctx, alpha: alpha)
        text("Rune", font(96, .semibold), ink, centreX: W / 2, y: H / 2 - 24 - dy, alpha: alpha)
        text("The terminal for humans who run agents.", font(40), muted,
             centreX: W / 2, y: H / 2 - 120 - dy, alpha: alpha)
        text("macOS · built on libghostty", font(26, .medium), muted,
             centreX: W / 2, y: 138, alpha: alpha * 0.75)
    }),
    // 2 — the problem
    (3.2, { ctx, p, alpha in
        let dy = lift(p)
        text("Four agents running.", font(72, .semibold), ink,
             centreX: W / 2, y: H / 2 + 30 - dy, alpha: alpha)
        text("Four terminals that look identical.", font(72, .semibold),
             ink.withAlphaComponent(0.32), centreX: W / 2, y: H / 2 - 90 - dy, alpha: alpha)
    }),
    // 3 — the answer, in the actual UI
    (5.0, { ctx, p, alpha in
        let dy = lift(p)
        text("⌘K says which one wants you.", font(46, .semibold), ink,
             centreX: W / 2, y: H - 196 - dy, alpha: alpha)
        // The panel is the slide. Sized to the frame rather than to whatever
        // the capture happened to be.
        let width = 1300.0
        let size = CGSize(width: width, height: width * switcher.size.height / switcher.size.width)
        let rect = CGRect(x: (W - size.width) / 2, y: H / 2 - size.height / 2 - 60 - dy,
                          width: size.width, height: size.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 60,
                      color: NSColor(calibratedWhite: 0, alpha: 0.22 * alpha).cgColor)
        switcher.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
        ctx.restoreGState()
    }),
    // 4 — the vocabulary
    (3.6, { ctx, p, alpha in
        let dy = lift(p)
        text("Two states and silence.", font(58, .semibold), ink,
             centreX: W / 2, y: H / 2 + 150 - dy, alpha: alpha)
        chip("working", tone: working, at: CGPoint(x: W / 2, y: H / 2 + 46 - dy), ctx, alpha: alpha)
        chip("your turn", tone: turn, at: CGPoint(x: W / 2, y: H / 2 - 46 - dy), ctx, alpha: alpha)
        text("nothing at all, when it can't know", font(30), muted,
             centreX: W / 2, y: H / 2 - 160 - dy, alpha: alpha * 0.85)
        text("read from what each agent publishes — never from the screen",
             font(26), muted, centreX: W / 2, y: 150, alpha: alpha * 0.7)
    }),
    // 5 — the shape of it
    (3.6, { ctx, p, alpha in
        let dy = lift(p)
        text("Three places to put a terminal.", font(58, .semibold), ink,
             centreX: W / 2, y: H / 2 + 156 - dy, alpha: alpha)
        let rows = [("⌘D", "Splits", "panes side by side"),
                    ("⌘T", "Tabs", "a strip inside the title bar"),
                    ("⌘N", "Workspaces", "whole sets, reachable from ⌘K")]
        for (i, row) in rows.enumerated() {
            let y = H / 2 + 20 - Double(i) * 78 - dy
            let key = NSAttributedString(string: row.0, attributes: [
                .font: font(34, .semibold), .foregroundColor: ink.withAlphaComponent(alpha)])
            key.draw(at: CGPoint(x: W / 2 - 430, y: y))
            let name = NSAttributedString(string: row.1, attributes: [
                .font: font(34, .medium), .foregroundColor: ink.withAlphaComponent(alpha)])
            name.draw(at: CGPoint(x: W / 2 - 300, y: y))
            let desc = NSAttributedString(string: row.2, attributes: [
                .font: font(30), .foregroundColor: muted.withAlphaComponent(alpha)])
            desc.draw(at: CGPoint(x: W / 2 - 40, y: y + 3))
        }
    }),
    // 6 — where to get it
    (3.8, { ctx, p, alpha in
        let dy = lift(p)
        mark(at: CGPoint(x: W / 2, y: H / 2 + 168 - dy), side: 116, ctx, alpha: alpha)
        text("Free and open source.", font(54, .semibold), ink,
             centreX: W / 2, y: H / 2 + 10 - dy, alpha: alpha)
        // The highlighter stroke goes *under* the URL, drawn first so the text
        // sits on it rather than behind it.
        let width = 700.0
        ctx.setFillColor(marker.withAlphaComponent(0.9 * alpha).cgColor)
        ctx.fill(CGRect(x: W / 2 - width / 2, y: H / 2 - 92 - dy, width: width, height: 18))
        text("github.com/Sushants-Git/Rune", font(38, .medium), ink.withAlphaComponent(0.78),
             centreX: W / 2, y: H / 2 - 96 - dy, alpha: alpha)
        text("Universal · macOS 13+ · updates itself", font(28), muted,
             centreX: W / 2, y: 150, alpha: alpha * 0.8)
    }),
]

// MARK: - Timeline

let fade = 0.5
let total = slides.reduce(0) { $0 + $1.0 }
let frameCount = Int(total * FPS)
var starts: [Double] = []
var accumulated = 0.0
for slide in slides { starts.append(accumulated); accumulated += slide.0 }

for frame in 0..<frameCount {
    let t = Double(frame) / FPS
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let ctx = graphics.cgContext

    ctx.setFillColor(page.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    for (index, slide) in slides.enumerated() {
        let start = starts[index], end = start + slide.0
        guard t >= start - fade, t < end else { continue }
        let progress = (t - start) / slide.0
        // Dissolve in over `fade`, and out over the last `fade`.
        var alpha = 1.0
        if t < start { alpha = 0 }
        else if t - start < fade, index > 0 { alpha = (t - start) / fade }
        if end - t < fade, index < slides.count - 1 { alpha = min(alpha, (end - t) / fade) }
        slide.1(ctx, max(progress, 0), max(0, min(1, alpha)))
    }

    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: frames.appendingPathComponent(String(format: "%04d.png", frame)))
}
print("frames: \(frameCount) (\(String(format: "%.1f", total))s)")
SWIFT

mkdir -p "$REPO_ROOT/build"
# yuv420p and even dimensions, because anything else fails to play on half the
# clients Twitter hands it to.
ffmpeg -y -loglevel error -framerate 24 -i "$FRAMES/%04d.png" \
  -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -movflags +faststart \
  "$OUT"

echo "==> $OUT ($(du -h "$OUT" | cut -f1), $(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$OUT" | cut -c1-4)s)"
