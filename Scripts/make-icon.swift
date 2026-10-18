// Draws the app icon: the word "word" between two guide lines, its focus letter in red.
//
//   swift Scripts/make-icon.swift <output.png>

import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png")
let canvas = 1024.0

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("Couldn't make a bitmap") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

// The macOS icon grid: an 824-point rounded square, centred, with a soft drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.white.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

let paperTop = NSColor(srgbRed: 0.995, green: 0.982, blue: 0.950, alpha: 1)
let paperBottom = NSColor(srgbRed: 0.930, green: 0.900, blue: 0.840, alpha: 1)
NSGradient(starting: paperBottom, ending: paperTop)?.draw(in: shape, angle: 90)

let ink = NSColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: 1)
let red = NSColor(srgbRed: 0.80, green: 0.18, blue: 0.14, alpha: 1)
let centre = canvas / 2

// Guide lines with a tick pointing at the focus letter.
ink.withAlphaComponent(0.22).setFill()
let lineWidth = 560.0
NSRect(x: centre - lineWidth / 2, y: 700, width: lineWidth, height: 7).fill()
NSRect(x: centre - 4.5, y: 645, width: 9, height: 60).fill()
NSRect(x: centre - lineWidth / 2, y: 317, width: lineWidth, height: 7).fill()
NSRect(x: centre - 4.5, y: 320, width: 9, height: 60).fill()

let base = NSFont.systemFont(ofSize: 230, weight: .medium)
let font = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 230) } ?? base
func piece(_ text: String, _ colour: NSColor) -> CTLine {
    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour]))
}
func width(_ line: CTLine) -> Double { CTLineGetTypographicBounds(line, nil, nil, nil) }

// Centre the focus letter across, and the letters' x-height up and down.
let before = piece("w", ink)
let focus = piece("o", red)
let after = piece("rd", ink)
let context = NSGraphicsContext.current!.cgContext
context.textPosition = .zero
let baseline = centre - CTLineGetImageBounds(focus, context).midY
for (line, x) in [(before, centre - width(focus) / 2 - width(before)),
                  (focus, centre - width(focus) / 2),
                  (after, centre + width(focus) / 2)] {
    context.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(line, context)
}

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Couldn't encode the PNG") }
try png.write(to: output)
print("Wrote \(output.path)")
