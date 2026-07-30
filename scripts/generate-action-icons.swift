#!/usr/bin/env swift
//
// Regenerates the Finder Quick Action icons in ExportMarkdownAction. They sit at
// the root of that synchronized folder so they land directly in each .appex's
// Contents/Resources, and each target names its own via FINDER_ACTION_ICON_NAME
// (wired to CFBundleIconName / NSExtensionServiceToolbarIconFile in Info.plist).
//
//   swift scripts/generate-action-icons.swift ExportMarkdownAction
//
// Matching Apple's built-in actions
// --------------------------------
// Login Items & Extensions draws each action's icon *as authored* — it does not
// composite a plate. Apple's built-ins (Create PDF, Trim, Convert Image, Remove
// Background) and third-party ones alike ship the rounded plate inside their own
// artwork, which is why a bare glyph renders plate-less and undersized.
//
// The numbers below were measured off Apple's own Create PDF icon as rendered in
// that list, so ours line up 1:1:
//
//   plate        26x26pt, corner radius 8pt, vertical gradient #B4B4B9 -> #8E8E93
//   glyph        white, .medium weight, fitted to a centred 16pt box
//   canvas       32x32pt, plate centred — the list draws at natural size and
//                does not upscale, so the canvas has to be the full slot
//
// The plate is not a flat fill. Sampling a column down Apple's tiles gives ~#B4B4B9
// at the top falling to systemGray #8E8E93 about 60% of the way down and staying
// there — a subtle top-lit sheen. Create PDF and Convert Image measure identically,
// so it is a system treatment rather than per-icon artwork. A flat systemGray plate
// is noticeably duller side by side.
//
// When comparing against a screen capture, convert samples to sRGB first. Raw
// bitmap components come back in the display's space, where Apple's #8E8E93 reads
// as #7B7B81 — that gap is a colour-space artifact, not the list darkening icons.
//
// The glyphs themselves are real SF Symbols drawn straight from the system,
// never redrawn by hand.
//
// The filenames deliberately avoid a "Template" suffix: NSImage would then treat
// them as template images and flatten the plate and glyph into one solid mask.
//
// Output is PNG at 1x/2x rather than a vector PDF: a fill in a CGPDFContext is
// written untagged, whereas PNG carries an explicit sRGB profile. 1x/2x only —
// macOS has no 3x displays, and tiffutil mis-tags a third rep's point size.

import AppKit

let specs: [(file: String, symbol: String)] = [
  // `doc` is the same page-with-folded-corner silhouette Finder uses for Create PDF.
  ("CreatePDFActionIcon",      "doc"),
  // The same angled-photo-on-rectangle glyph Finder's Convert Image uses; its
  // width sits much closer to Apple's than plain `photo` does.
  ("CreatePNGActionIcon",      "photo.on.rectangle.angled"),
  ("CreateHTMLActionIcon",     "safari"),
  // Stays in the document family alongside Create PDF rather than the busier
  // square.and.arrow.up, which visually merges at this size.
  ("ExportMarkdownActionIcon", "arrow.up.doc"),
]

let canvas: CGFloat = 32
let plateSide: CGFloat = 26
let plateRadius: CGFloat = 8
// Deliberately larger than the ~14pt Apple's own glyphs measure, and drawn at
// .medium rather than .regular: at this size Apple's glyphs read thin and float in
// too much padding, so ours are tightened up and weighted a step heavier.
let glyphBox: CGFloat = 16
let glyphWeight: NSFont.Weight = .medium
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
// Bottom is systemGray in light appearance; the top is lifted to match Apple's
// sheen. Greys either way, as Apple uses, so the one static asset reads correctly
// against both the light and dark extension list.
let plateBottom = CGColor(colorSpace: sRGB,
                          components: [0x8E/255.0, 0x8E/255.0, 0x93/255.0, 1])!
let plateTop = CGColor(colorSpace: sRGB,
                       components: [0xB4/255.0, 0xB4/255.0, 0xB9/255.0, 1])!
// Stops run bottom-to-top: flat systemGray across the lower 38%, then the ramp.
let plateGradient = CGGradient(colorsSpace: sRGB,
                               colors: [plateBottom, plateBottom, plateTop] as CFArray,
                               locations: [0, 0.38, 1])!

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(
    "usage: generate-action-icons.swift <output-dir>\n".data(using: .utf8)!)
  exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

/// The SF Symbol, rendered white at the configured weight.
///
/// Drawn as an image rather than via NSSymbolImageRep's `outlinePath`. That
/// property returns a simplified union for layered symbols — on
/// photo.on.rectangle.angled it fills the front photo solid, losing the mountain
/// and sun — and it was only needed back when these were vector PDFs.
func symbolImage(_ symbol: String) -> NSImage {
  let config = NSImage.SymbolConfiguration(pointSize: 256, weight: glyphWeight)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
  guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
          .withSymbolConfiguration(config)
  else { fatalError("no such SF Symbol: \(symbol)") }
  return img
}

/// The symbol's real ink box as a fraction of its own canvas, so glyphs fill
/// `glyphBox` consistently despite the padding SF Symbols bakes in.
func inkBounds(of img: NSImage) -> CGRect {
  let n = 512
  let probe = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: n * 4, bitsPerPixel: 32)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: probe)
  img.draw(in: NSRect(x: 0, y: 0, width: CGFloat(n), height: CGFloat(n)))
  NSGraphicsContext.restoreGraphicsState()

  var minX = n, maxX = -1, minY = n, maxY = -1
  for y in 0..<n {
    for x in 0..<n where (probe.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
      minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
  }
  let f = CGFloat(n)
  // colorAt is top-left origin; drawing is bottom-left, so flip y.
  return CGRect(x: CGFloat(minX) / f, y: CGFloat(n - 1 - maxY) / f,
                width: CGFloat(maxX - minX + 1) / f, height: CGFloat(maxY - minY + 1) / f)
}

for spec in specs {
  let glyph = symbolImage(spec.symbol)
  let ink = inkBounds(of: glyph)
  // Scale so the ink — not the symbol's padded canvas — fills glyphBox, centred.
  let scale = min(glyphBox / ink.width, glyphBox / ink.height)
  let drawRect = NSRect(x: (canvas - ink.width * scale) / 2 - ink.minX * scale,
                        y: (canvas - ink.height * scale) / 2 - ink.minY * scale,
                        width: scale, height: scale)

  let plate = NSRect(x: (canvas - plateSide) / 2, y: (canvas - plateSide) / 2,
                     width: plateSide, height: plateSide)
  let plateShape = NSBezierPath(roundedRect: plate,
                                xRadius: plateRadius, yRadius: plateRadius).cgPath

  for scaleFactor in [1, 2] {
    let px = Int(canvas) * scaleFactor
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(scaleFactor), y: CGFloat(scaleFactor))
    ctx.setShouldAntialias(true)

    ctx.saveGState()
    ctx.addPath(plateShape)
    ctx.clip()
    ctx.drawLinearGradient(plateGradient,
                           start: CGPoint(x: plate.midX, y: plate.minY),
                           end: CGPoint(x: plate.midX, y: plate.maxY),
                           options: [])
    ctx.restoreGState()

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    glyph.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: canvas, height: canvas)
    guard let png = rep.representation(using: .png, properties: [:]) else {
      fatalError("could not encode \(spec.file)@\(scaleFactor)x")
    }
    let suffix = scaleFactor == 1 ? "" : "@\(scaleFactor)x"
    try png.write(to: outDir.appendingPathComponent("\(spec.file)\(suffix).png"))
  }
  print("\(spec.file).png (1x/2x)  <-  \(spec.symbol)")
}
