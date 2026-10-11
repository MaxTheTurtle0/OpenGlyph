import AppKit

// Original OpenGlyph artwork. Every coordinate is in a 1024-point canvas.
// Draw directly into bitmap contexts so generating assets needs no display server.
func drawIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "OpenGlyph.Icon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 198, yRadius: 198)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 25
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedRed: 0.03, green: 0.21, blue: 0.74, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.02, green: 0.22, blue: 0.76, alpha: 1),
        NSColor(calibratedRed: 0.14, green: 0.48, blue: 1, alpha: 1)
    ])!.draw(in: tile, angle: 58)
    let gleam = NSBezierPath(ovalIn: NSRect(x: 490, y: 640, width: 690, height: 690))
    NSColor.white.withAlphaComponent(0.075).setFill()
    gleam.fill()
    let inset = NSBezierPath(roundedRect: NSRect(x: 66, y: 66, width: 892, height: 892), xRadius: 196, yRadius: 196)
    inset.lineWidth = 3
    NSColor.white.withAlphaComponent(0.22).setStroke()
    inset.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // Four reading-frame corners, kept bold enough to survive menu and Finder sizes.
    let corners: [[NSPoint]] = [
        [NSPoint(x: 344, y: 775), NSPoint(x: 248, y: 775), NSPoint(x: 248, y: 679)],
        [NSPoint(x: 680, y: 775), NSPoint(x: 776, y: 775), NSPoint(x: 776, y: 679)],
        [NSPoint(x: 248, y: 345), NSPoint(x: 248, y: 249), NSPoint(x: 344, y: 249)],
        [NSPoint(x: 776, y: 345), NSPoint(x: 776, y: 249), NSPoint(x: 680, y: 249)]
    ]
    NSColor.white.withAlphaComponent(0.97).setStroke()
    for points in corners {
        let path = NSBezierPath()
        path.lineWidth = 38
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: points[0])
        path.line(to: points[1])
        path.line(to: points[2])
        path.stroke()
    }

    // A constructed lowercase g: ring, right stem, and hooked descender.
    // No font, SF Symbol, or third-party artwork is embedded in the icon.
    let ring = NSBezierPath(ovalIn: NSRect(x: 378, y: 426, width: 234, height: 234))
    ring.lineWidth = 56
    NSColor.white.setStroke()
    ring.stroke()
    let stem = NSBezierPath()
    stem.lineWidth = 56
    stem.lineCapStyle = .round
    stem.lineJoinStyle = .round
    stem.move(to: NSPoint(x: 612, y: 632))
    stem.line(to: NSPoint(x: 612, y: 380))
    stem.curve(to: NSPoint(x: 410, y: 326), controlPoint1: NSPoint(x: 612, y: 277), controlPoint2: NSPoint(x: 481, y: 277))
    stem.stroke()

    // A scanning stroke crosses the letter without obscuring it.
    let scan = NSBezierPath()
    scan.move(to: NSPoint(x: 324, y: 498))
    scan.line(to: NSPoint(x: 700, y: 498))
    scan.lineWidth = 18
    scan.lineCapStyle = .round
    NSColor(calibratedRed: 0.42, green: 0.96, blue: 1, alpha: 1).setStroke()
    scan.stroke()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "OpenGlyph.Icon", code: 2)
    }
    return png
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/draw-icon.swift OUTPUT_ICONSET_DIRECTORY\n", stderr)
    exit(2)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        let filename = "icon_\(points)x\(points)\(suffix).png"
        try drawIcon(pixels: points * scale).write(to: directory.appendingPathComponent(filename), options: .atomic)
    }
}
try drawIcon(pixels: 1024).write(to: directory.deletingLastPathComponent().appendingPathComponent("OpenGlyph-icon.png"), options: .atomic)
