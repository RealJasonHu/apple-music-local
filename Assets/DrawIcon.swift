import AppKit

// Original vector artwork: a waveform landing in a local library tray.
// Generated with AppKit so every icon resolution is rendered independently.
let destination = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
let resolutions: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, pixels) in resolutions {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
        pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Unable to allocate icon bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let bounds = NSRect(x: 72, y: 72, width: 880, height: 880)
    let tile = NSBezierPath(roundedRect: bounds, xRadius: 205, yRadius: 205)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 36
    shadow.shadowOffset = NSSize(width: 0, height: -15)
    shadow.set()
    NSColor(calibratedRed: 0.93, green: 0.18, blue: 0.37, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(calibratedRed: 1, green: 0.42, blue: 0.40, alpha: 1),
                       NSColor(calibratedRed: 0.91, green: 0.14, blue: 0.38, alpha: 1)])!
        .draw(in: tile, angle: -60)

    NSColor.white.withAlphaComponent(0.18).setStroke()
    let inset = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 203, yRadius: 203)
    inset.lineWidth = 4
    inset.stroke()

    // Five rounded waveform bars make the mark legible at Dock sizes.
    let bars: [(CGFloat, CGFloat)] = [(314, 164), (413, 286), (512, 384), (611, 262), (710, 134)]
    NSColor.white.setFill()
    for (x, height) in bars {
        NSBezierPath(roundedRect: NSRect(x: x - 28, y: 570 - height / 2, width: 56, height: height),
                     xRadius: 28, yRadius: 28).fill()
    }

    let tray = NSBezierPath()
    tray.move(to: NSPoint(x: 285, y: 342))
    tray.line(to: NSPoint(x: 285, y: 295))
    tray.curve(to: NSPoint(x: 329, y: 251), controlPoint1: NSPoint(x: 285, y: 268),
               controlPoint2: NSPoint(x: 302, y: 251))
    tray.line(to: NSPoint(x: 695, y: 251))
    tray.curve(to: NSPoint(x: 739, y: 295), controlPoint1: NSPoint(x: 722, y: 251),
               controlPoint2: NSPoint(x: 739, y: 268))
    tray.line(to: NSPoint(x: 739, y: 342))
    tray.lineWidth = 42
    tray.lineCapStyle = .round
    tray.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.94).setStroke()
    tray.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode icon")
    }
    try png.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name))
}
