#!/usr/bin/env swift
// Tiler app icon generator (SPEC §10.2). Procedural, deterministic: two runs produce byte-
// identical PNGs (and .icns), no randomness, no timestamps, no external assets. Run with:
//
//   swift scripts/make-icon.swift [--out <path/to/AppIcon.icns>] [--preview <dir>]
//
// --out       output .icns path (default: <repo root>/Resources/AppIcon.icns).
// --preview   also write standalone PNGs at 1024/256/64/32/16 px into <dir>, for visual
//             inspection (e.g. side by side with real macOS app icons) without unpacking the
//             .icns.
//
// Design (measured against real macOS app icons on this Mac, e.g.
// /System/Applications/Calculator.app, via `sips` + alpha-channel analysis — see the ratios
// below): the macOS "big sur+" icon grid — an 824 px rounded-square body centered on a 1024 px
// canvas (bodyRatio = 824/1024), corner radius ≈ 0.25 × body side (measured ≈ 206 px of an 824
// px body), a soft system-like drop shadow, a calm diagonal gradient fill, and a white glyph —
// a rounded "screen" outline with a 2×2 tiled grid inset inside it, gap between tiles — drawn
// in the same visual language as the in-app palette icons (`Sources/TilerCore/IconGeometry.swift`,
// `Sources/Tiler/App/PresetIcon.swift`): stroke outline + filled inset rounded rects, one ink
// color, whole-pixel snapped at every size so it stays legible down to 16 px.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - CLI

struct Options {
    var outputPath: String
    var previewDir: String?
}

func parseArguments() -> Options {
    let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
    let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    var out = repoRoot.appendingPathComponent("Resources/AppIcon.icns").path
    var preview: String?
    var args = CommandLine.arguments.dropFirst()
    while let arg = args.first {
        args.removeFirst()
        switch arg {
        case "--out":
            guard let value = args.first else { fatalError("--out needs a path") }
            args.removeFirst()
            out = value
        case "--preview":
            guard let value = args.first else { fatalError("--preview needs a directory") }
            args.removeFirst()
            preview = value
        default:
            fatalError("unknown argument: \(arg)")
        }
    }
    return Options(outputPath: out, previewDir: preview)
}

// MARK: - Icon drawing

/// One iconset member: pixel side length and its Apple iconset filename.
struct IconSize {
    let pixels: Int
    let filename: String
}

/// Apple's standard 10-entry iconset (16–1024, @1x/@2x), per `iconutil`'s requirements.
let iconSizes: [IconSize] = [
    IconSize(pixels: 16, filename: "icon_16x16.png"),
    IconSize(pixels: 32, filename: "icon_16x16@2x.png"),
    IconSize(pixels: 32, filename: "icon_32x32.png"),
    IconSize(pixels: 64, filename: "icon_32x32@2x.png"),
    IconSize(pixels: 128, filename: "icon_128x128.png"),
    IconSize(pixels: 256, filename: "icon_128x128@2x.png"),
    IconSize(pixels: 256, filename: "icon_256x256.png"),
    IconSize(pixels: 512, filename: "icon_256x256@2x.png"),
    IconSize(pixels: 512, filename: "icon_512x512.png"),
    IconSize(pixels: 1024, filename: "icon_512x512@2x.png"),
]

/// Nearest whole pixel, at least `minimum` (icon-local; the canvas we render *is* the pixel
/// grid, so rounding to the nearest integer snaps geometry to whole device pixels at every
/// requested size — no separate backing-scale factor needed).
func snap(_ value: CGFloat, minimum: CGFloat = 0) -> CGFloat {
    max(minimum, value.rounded())
}

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Draws the Tiler app icon into `context` at `canvas` × `canvas` pixels (origin bottom-left,
/// Quartz default). Every measurement below is a ratio of `canvas` or of a shape it derives
/// from, then snapped to whole pixels for that canvas, so the same code draws every required
/// size crisply.
func drawIcon(in context: CGContext, canvas: CGFloat) {
    context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

    // MARK: Body — 824⁄1024 rounded square, centered, corner radius ≈ 0.25 × body side
    // (measured on real macOS app icons: alpha-channel edge fit gave body 823–824 px of 1024,
    // centered exactly, corner radius ≈ 204–208 px — a near-circular corner, not an exotic
    // "squircle" exponent, hence a plain `CGPath(roundedRect:)`).
    let bodyRatio: CGFloat = 824 / 1024
    let cornerRatio: CGFloat = 0.25 // of body side
    let bodySide = snap(canvas * bodyRatio, minimum: 2)
    let bodyOrigin = ((canvas - bodySide) / 2).rounded()
    let bodyRect = CGRect(x: bodyOrigin, y: bodyOrigin, width: bodySide, height: bodySide)
    let bodyCorner = snap(bodySide * cornerRatio, minimum: 1)
    let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: bodyCorner, cornerHeight: bodyCorner, transform: nil)

    // MARK: System-like drop shadow (measured: soft, hugs the edge, offset slightly down).
    // Cast by an opaque fill of `bodyPath` BEFORE it is used as a clip — a shadow renders only
    // outside the shape casting it, so setting the clip first (as a later gradient fill needs)
    // would clip the shadow away too.
    context.saveGState()
    let shadowBlur = canvas * 0.035
    let shadowOffset = CGSize(width: 0, height: -canvas * 0.012)
    context.setShadow(offset: shadowOffset, blur: shadowBlur, color: srgb(0, 0, 0, 0.45))
    context.addPath(bodyPath)
    context.setFillColor(srgb(0, 0, 0))
    context.fillPath()
    context.restoreGState() // drop the shadow; the base fill above is about to be painted over

    // MARK: Calm diagonal gradient fill, clipped to the rounded body.
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let colors = [srgb(125, 184, 255), srgb(58, 86, 212)] as CFArray
    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else {
        fatalError("could not build gradient")
    }
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: bodyRect.minX, y: bodyRect.maxY),
        end: CGPoint(x: bodyRect.maxX, y: bodyRect.minY),
        options: []
    )
    context.restoreGState() // drop clip

    // MARK: Glyph — window-tiling, in the palette icons' visual language: a rounded "screen"
    // outline stroke, and a 2×2 grid of filled rounded tiles inset inside it with a gap between
    // them (`Sources/TilerCore/IconGeometry.swift` §"Icons"). One ink color (white), so it
    // reads at any size the same way the in-app icons do.
    let glyphRatio: CGFloat = 0.60 // of body side
    let glyph = snap(bodySide * glyphRatio, minimum: 4)
    let glyphOrigin = CGPoint(x: bodyRect.midX - glyph / 2, y: bodyRect.midY - glyph / 2)
    let glyphRect = CGRect(x: snap(glyphOrigin.x), y: snap(glyphOrigin.y), width: glyph, height: glyph)

    let stroke = snap(glyph * 0.085, minimum: 1)
    let outerCorner = snap(glyph * 0.16, minimum: 1)
    let outlineRect = glyphRect.insetBy(dx: stroke / 2, dy: stroke / 2)
    let outlineCorner = max(0, outerCorner - stroke / 2)

    let ink = srgb(255, 255, 255, 0.96)
    context.setStrokeColor(ink)
    context.setLineWidth(stroke)
    context.addPath(CGPath(roundedRect: outlineRect, cornerWidth: outlineCorner, cornerHeight: outlineCorner, transform: nil))
    context.strokePath()

    let contentInset = stroke + snap(glyph * 0.11, minimum: 1)
    let content = glyphRect.insetBy(dx: contentInset, dy: contentInset)
    // Size the gap AFTER the tile, so 2 tiles + gap always sum to exactly
    // `content.width` and no leftover margin is needed. The old code picked `gap`
    // first and rounded the leftover half-pixel margin with `.rounded()`, which
    // rounds up and lands the whole pixel on one side only — the grid sat 1 px
    // off-centre (measured: 3px left/2px right at 32px, similarly at 16px).
    let gapEstimate = snap(content.width * 0.09, minimum: 1)
    let tile = ((content.width - gapEstimate) / 2).rounded(.down)
    let gap = content.width - 2 * tile
    // A rounded corner on a 1–2 px tile anti-aliases into a faint blob instead of
    // a crisp square (measured ~80% ink vs. the outline's ~100% at 16 px) — below
    // 3 px, draw plain squares instead.
    let tileCorner = tile < 3 ? 0 : snap(tile * 0.15, minimum: 1)

    context.setFillColor(ink)
    for row in 0..<2 {
        for col in 0..<2 {
            let x = content.minX + CGFloat(col) * (tile + gap)
            let y = content.minY + CGFloat(row) * (tile + gap)
            let rect = CGRect(x: x, y: y, width: tile, height: tile)
            let path = CGPath(roundedRect: rect, cornerWidth: tileCorner, cornerHeight: tileCorner, transform: nil)
            context.addPath(path)
            context.fillPath()
        }
    }
}

// MARK: - Rendering

func renderPNGData(canvas: Int) -> Data {
    let size = CGFloat(canvas)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: canvas,
              height: canvas,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else {
        fatalError("could not create bitmap context at \(canvas)px")
    }
    drawIcon(in: context, canvas: size)
    guard let image = context.makeImage() else { fatalError("could not snapshot image at \(canvas)px") }

    let data = NSMutableDataStub()
    guard let destination = CGImageDestinationCreateWithData(data.cfData, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("could not create PNG destination at \(canvas)px")
    }
    // No metadata/properties are set — deterministic bytes across runs.
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not finalize PNG at \(canvas)px") }
    return data.cfData as Data
}

/// Minimal `CFMutableData` holder (avoids pulling in Foundation's `NSMutableData` just for
/// this one bridging use).
final class NSMutableDataStub {
    let cfData: CFMutableData = CFDataCreateMutable(nil, 0)
}

// MARK: - Main

let options = parseArguments()
let fm = FileManager.default

let workDir = fm.temporaryDirectory.appendingPathComponent("tiler-make-icon-\(ProcessInfo.processInfo.globallyUniqueString)")
let iconsetDir = workDir.appendingPathComponent("AppIcon.iconset")
try! fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: workDir) }

print("==> rendering \(iconSizes.count) sizes")
for entry in iconSizes {
    let data = renderPNGData(canvas: entry.pixels)
    let url = iconsetDir.appendingPathComponent(entry.filename)
    try! data.write(to: url)
}

let outputURL = URL(fileURLWithPath: options.outputPath)
try! fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
if fm.fileExists(atPath: outputURL.path) {
    try! fm.removeItem(at: outputURL)
}

print("==> iconutil -c icns \(iconsetDir.path) -o \(outputURL.path)")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir.path, "-o", outputURL.path]
try! process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(process.terminationStatus)")
}
print(outputURL.path)

if let previewDir = options.previewDir {
    let previewURL = URL(fileURLWithPath: previewDir)
    try! fm.createDirectory(at: previewURL, withIntermediateDirectories: true)
    for size in [1024, 256, 64, 32, 16] {
        let data = renderPNGData(canvas: size)
        let url = previewURL.appendingPathComponent("preview_\(size).png")
        try! data.write(to: url)
    }
    print("==> previews written to \(previewURL.path)")
}
