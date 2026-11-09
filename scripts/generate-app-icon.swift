#!/usr/bin/env swift
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Draws the icon on a 1024 × 1024 canvas (y up).
func drawIcon(in context: CGContext) {
    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    // Apple's macOS template: 824 pt body centered, ~185 pt corner radius.
    let body = canvas.insetBy(dx: 100, dy: 100)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    // Shadow under the body.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, alpha: 0.35).cgColor)
    color(0x0B2A55).setFill()
    squircle.fill()
    context.restoreGState()

    // Background: deep water.
    context.saveGState()
    squircle.addClip()
    NSGradient(colors: [color(0x1B6FB8), color(0x0A2E5C)])?.draw(in: body, angle: -90)

    // The vessel: a tall rounded glass.
    let vessel = CGRect(x: 312, y: 214, width: 400, height: 560)
    let vesselPath = NSBezierPath(roundedRect: vessel, xRadius: 92, yRadius: 92)
    color(0xFFFFFF, alpha: 0.10).setFill()
    vesselPath.fill()

    // Water with a wave on top, clipped to the vessel.
    context.saveGState()
    vesselPath.addClip()
    let waterTop: CGFloat = 520
    let wave = NSBezierPath()
    wave.move(to: CGPoint(x: vessel.minX, y: vessel.minY))
    wave.line(to: CGPoint(x: vessel.minX, y: waterTop))
    let steps = 60
    for step in 0 ... steps {
        let t = CGFloat(step) / CGFloat(steps)
        let x = vessel.minX + t * vessel.width
        let y = waterTop + sin(t * .pi * 2.2 + 0.4) * 22 + sin(t * .pi * 5.1) * 6
        wave.line(to: CGPoint(x: x, y: y))
    }
    wave.line(to: CGPoint(x: vessel.maxX, y: vessel.minY))
    wave.close()
    NSGradient(colors: [color(0x7FE3FF), color(0x2C9BE0), color(0x1667B8)])?.draw(in: wave, angle: -90)

    // Meniscus highlight along the wave.
    let crest = NSBezierPath()
    for step in 0 ... steps {
        let t = CGFloat(step) / CGFloat(steps)
        let point = CGPoint(
            x: vessel.minX + t * vessel.width,
            y: waterTop + sin(t * .pi * 2.2 + 0.4) * 22 + sin(t * .pi * 5.1) * 6
        )
        step == 0 ? crest.move(to: point) : crest.line(to: point)
    }
    crest.lineWidth = 10
    color(0xFFFFFF, alpha: 0.75).setStroke()
    crest.stroke()
    context.restoreGState()

    // Glass rim and a soft left-side reflection.
    vesselPath.lineWidth = 14
    color(0xFFFFFF, alpha: 0.55).setStroke()
    vesselPath.stroke()
    let reflection = NSBezierPath(
        roundedRect: CGRect(x: vessel.minX + 40, y: vessel.minY + 90, width: 26, height: 360),
        xRadius: 13,
        yRadius: 13
    )
    color(0xFFFFFF, alpha: 0.22).setFill()
    reflection.fill()

    // The droplet hanging from the rim.
    let drop = NSBezierPath()
    let center = CGPoint(x: 512, y: 690)
    let radius: CGFloat = 46
    drop.move(to: CGPoint(x: center.x, y: center.y + radius * 2.1))
    drop.curve(
        to: CGPoint(x: center.x + radius, y: center.y),
        controlPoint1: CGPoint(x: center.x + radius * 0.35, y: center.y + radius * 1.4),
        controlPoint2: CGPoint(x: center.x + radius, y: center.y + radius * 0.75)
    )
    drop.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 180, clockwise: true)
    drop.curve(
        to: CGPoint(x: center.x, y: center.y + radius * 2.1),
        controlPoint1: CGPoint(x: center.x - radius, y: center.y + radius * 0.75),
        controlPoint2: CGPoint(x: center.x - radius * 0.35, y: center.y + radius * 1.4)
    )
    NSGradient(colors: [color(0xE6FAFF), color(0x8ADCFF)])?.draw(in: drop, angle: -90)
    color(0xFFFFFF, alpha: 0.9).setFill()
    NSBezierPath(ovalIn: CGRect(x: center.x - 22, y: center.y + 2, width: 16, height: 22)).fill()

    // Top sheen on the body.
    NSGradient(colors: [color(0xFFFFFF, alpha: 0.18), color(0xFFFFFF, alpha: 0)])?
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    context.restoreGState()
}

func renderPNG(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.interpolationQuality = .high
    drawIcon(in: context)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

struct Slot {
    let points: Int
    let scale: Int
    var filename: String {
        "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    }
}

let slots = [16, 32, 128, 256, 512].flatMap { [Slot(points: $0, scale: 1), Slot(points: $0, scale: 2)] }
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

var images: [[String: String]] = []
for slot in slots {
    guard let png = renderPNG(pixels: slot.points * slot.scale) else { fatalError("Rendering \(slot.filename) failed") }
    try png.write(to: outputDirectory.appendingPathComponent(slot.filename))
    images.append([
        "filename": slot.filename,
        "idiom": "mac",
        "scale": "\(slot.scale)x",
        "size": "\(slot.points)x\(slot.points)"
    ])
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(slots.count) icons to \(outputDirectory.path)")
