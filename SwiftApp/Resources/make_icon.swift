// Draws the Church Translate app icon (concept B: speech bubbles with a cross).
// Regenerate all icon files with:  ./make_icon.sh
//
// Usage: swift make_icon.swift <output.png> <size> [mac|ios]
//   mac: rounded "squircle" tile inset on a transparent canvas, with soft shadow (macOS style)
//   ios: full-bleed square, no transparency (iPadOS rounds the corners itself)
import AppKit
import CoreGraphics
import CoreText

let args = CommandLine.arguments
guard args.count >= 3, let size = Double(args[2]) else {
    print("usage: make_icon.swift out.png size [mac|ios]"); exit(1)
}
let outPath = args[1]
let style = args.count > 3 ? args[3] : "mac"

let navyTop = CGColor(red: 0x2E/255, green: 0x5A/255, blue: 0x86/255, alpha: 1)
let navyBottom = CGColor(red: 0x1C/255, green: 0x38/255, blue: 0x5A/255, alpha: 1)
let navy = CGColor(red: 0x24/255, green: 0x47/255, blue: 0x6B/255, alpha: 1)
let gold = CGColor(red: 0xEF/255, green: 0x9F/255, blue: 0x27/255, alpha: 1)
let goldText = CGColor(red: 0x41/255, green: 0x24/255, blue: 0x02/255, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

let px = Int(size)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

// Work in a 1024-unit, y-down coordinate system
let k = size / 1024
ctx.scaleBy(x: k, y: k)
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)

// Tile placement: macOS template uses an 824-pt tile centred on a 1024 canvas
let tileOrigin: Double = style == "mac" ? 100 : 0
let tileSize: Double = style == "mac" ? 824 : 1024
let u = tileSize / 100   // concept was drawn on a 100-unit grid
func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: tileOrigin + x * u, y: tileOrigin + y * u) }
func R(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
    CGRect(x: tileOrigin + x * u, y: tileOrigin + y * u, width: w * u, height: h * u)
}

// Background tile
let tile = R(0, 0, 100, 100)
let tilePath: CGPath = style == "mac"
    ? CGPath(roundedRect: tile, cornerWidth: 22.5 * u, cornerHeight: 22.5 * u, transform: nil)
    : CGPath(rect: tile, transform: nil)
if style == "mac" {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28,
                  color: CGColor(gray: 0, alpha: 0.30))
    ctx.addPath(tilePath); ctx.setFillColor(navyBottom); ctx.fillPath()
    ctx.restoreGState()
}
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let grad = CGGradient(colorsSpace: cs, colors: [navyTop, navyBottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: P(50, 0), end: P(50, 100), options: [])

func bubble(_ rect: CGRect, radius: Double, tail: [CGPoint], color: CGColor, shadow: Bool) {
    ctx.saveGState()
    if shadow {
        ctx.setShadow(offset: CGSize(width: 0, height: 0.9 * u), blur: 2.4 * u,
                      color: CGColor(gray: 0, alpha: 0.28))
    }
    // Draw body and tail as one layer so they merge cleanly and share one shadow
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(color)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
    let t = CGMutablePath()
    t.addLines(between: tail)
    t.closeSubpath()
    ctx.addPath(t)
    ctx.fillPath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// Back bubble (gold, "Hola")
bubble(R(11, 16, 50, 38), radius: 11 * u,
       tail: [P(19, 52), P(15, 64), P(31, 52)], color: gold, shadow: true)

// "Hola" text, centred in the gold bubble's visible upper area
let fontSize = 13.5 * u
let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: fontSize) } ?? font
let attr = NSAttributedString(string: "Hola", attributes: [
    .font: rounded, .foregroundColor: NSColor(cgColor: goldText)!,
])
let line = CTLineCreateWithAttributedString(attr)
let bounds = CTLineGetImageBounds(line, ctx)
ctx.saveGState()
// Text draws y-up; flip locally around the baseline
// Centre over the part of the gold bubble left visible (x 11–50), above the white bubble
let cx = tileOrigin + 31.5 * u, baseline = tileOrigin + 37.5 * u
ctx.translateBy(x: cx - bounds.width / 2 - bounds.minX, y: baseline)
ctx.scaleBy(x: 1, y: -1)
ctx.textPosition = .zero
CTLineDraw(line, ctx)
ctx.restoreGState()

// Front bubble (white, with cross)
bubble(R(38, 40, 51, 40), radius: 11 * u,
       tail: [P(79, 78), P(84, 90), P(68, 78)], color: white, shadow: true)
ctx.setFillColor(navy)
ctx.addPath(CGPath(roundedRect: R(60.6, 47, 5.8, 27), cornerWidth: 1.2 * u, cornerHeight: 1.2 * u, transform: nil))
ctx.addPath(CGPath(roundedRect: R(53, 54.5, 21, 5.8), cornerWidth: 1.2 * u, cornerHeight: 1.2 * u, transform: nil))
ctx.fillPath()

// Subtle top highlight on the tile
let hl = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(hl, start: P(50, 0), end: P(50, 45), options: [])
ctx.restoreGState()

guard let img = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
