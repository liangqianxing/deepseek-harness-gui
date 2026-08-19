import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift scripts/generate-icon.swift <iconset-directory>\n", stderr)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

let variants: [(points: Int, scale: Int, name: String)] = [
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png")
]

func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    bitmap.size = NSSize(width: pixels, height: pixels)
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.shouldAntialias = true
    context.imageInterpolation = .high

    let size = CGFloat(pixels)
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    let outer = canvas.insetBy(dx: size * 0.055, dy: size * 0.055)
    let outerPath = NSBezierPath(
        roundedRect: outer,
        xRadius: size * 0.22,
        yRadius: size * 0.22
    )
    NSColor(srgbRed: 0.075, green: 0.09, blue: 0.11, alpha: 1).setFill()
    outerPath.fill()

    let panel = outer.insetBy(dx: size * 0.105, dy: size * 0.13)
    let panelPath = NSBezierPath(
        roundedRect: panel,
        xRadius: size * 0.105,
        yRadius: size * 0.105
    )
    NSColor(srgbRed: 0.13, green: 0.16, blue: 0.19, alpha: 1).setFill()
    panelPath.fill()

    let headerHeight = size * 0.13
    let header = NSRect(
        x: panel.minX,
        y: panel.maxY - headerHeight,
        width: panel.width,
        height: headerHeight
    )
    NSGraphicsContext.saveGraphicsState()
    panelPath.addClip()
    NSColor(srgbRed: 0.16, green: 0.20, blue: 0.23, alpha: 1).setFill()
    header.fill()
    NSGraphicsContext.restoreGraphicsState()

    let dotRadius = size * 0.027
    let dotCenter = NSPoint(
        x: panel.minX + size * 0.075,
        y: panel.maxY - headerHeight * 0.5
    )
    let dot = NSBezierPath(
        ovalIn: NSRect(
            x: dotCenter.x - dotRadius,
            y: dotCenter.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )
    )
    NSColor(srgbRed: 0.98, green: 0.43, blue: 0.31, alpha: 1).setFill()
    dot.fill()

    let strokeWidth = max(1.5, size * 0.048)
    let commandPath = NSBezierPath()
    commandPath.lineWidth = strokeWidth
    commandPath.lineCapStyle = .round
    commandPath.lineJoinStyle = .round
    commandPath.move(to: NSPoint(x: size * 0.31, y: size * 0.53))
    commandPath.line(to: NSPoint(x: size * 0.44, y: size * 0.42))
    commandPath.line(to: NSPoint(x: size * 0.31, y: size * 0.31))
    NSColor(srgbRed: 0.24, green: 0.82, blue: 0.77, alpha: 1).setStroke()
    commandPath.stroke()

    let cursorPath = NSBezierPath()
    cursorPath.lineWidth = strokeWidth
    cursorPath.lineCapStyle = .round
    cursorPath.move(to: NSPoint(x: size * 0.52, y: size * 0.31))
    cursorPath.line(to: NSPoint(x: size * 0.68, y: size * 0.31))
    NSColor(srgbRed: 0.93, green: 0.95, blue: 0.96, alpha: 1).setStroke()
    cursorPath.stroke()

    let statusRadius = size * 0.058
    let statusRect = NSRect(
        x: outer.maxX - statusRadius * 2.35,
        y: outer.minY + statusRadius * 0.45,
        width: statusRadius * 2,
        height: statusRadius * 2
    )
    let statusBorder = NSBezierPath(ovalIn: statusRect.insetBy(dx: -size * 0.012, dy: -size * 0.012))
    NSColor(srgbRed: 0.075, green: 0.09, blue: 0.11, alpha: 1).setFill()
    statusBorder.fill()
    let status = NSBezierPath(ovalIn: statusRect)
    NSColor(srgbRed: 0.45, green: 0.86, blue: 0.37, alpha: 1).setFill()
    status.fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

for variant in variants {
    let pixels = variant.points * variant.scale
    let data = try renderIcon(pixels: pixels)
    try data.write(to: outputDirectory.appendingPathComponent(variant.name))
}
