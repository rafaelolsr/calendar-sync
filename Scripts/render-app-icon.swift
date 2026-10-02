import AppKit
import Foundation

private let canvas = 1024

private func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

private func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    color.setStroke()
    path.stroke()
}

private func fillArrowhead(tip: NSPoint, wingA: NSPoint, wingB: NSPoint) {
    let arrowhead = NSBezierPath()
    arrowhead.move(to: tip)
    arrowhead.line(to: wingA)
    arrowhead.line(to: wingB)
    arrowhead.close()
    NSColor.white.setFill()
    arrowhead.fill()
}

private func drawIcon() throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: canvas,
        pixelsHigh: canvas,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "CalendarSyncIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create the icon canvas."])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let bounds = NSRect(x: 0, y: 0, width: canvas, height: canvas)

    // A quiet, nearly white gradient gives the icon a soft macOS tile without
    // competing with the blue calendar mark.
    let background = NSGradient(colors: [color(0xFFFFFF), color(0xF0F2F5)])!
    background.draw(in: bounds, angle: 270)

    let blue = color(0x287DB9)
    let deepBlue = color(0x205B89)

    // Calendar body and header.
    let calendarRect = NSRect(x: 228, y: 220, width: 568, height: 566)
    let calendar = NSBezierPath(roundedRect: calendarRect, xRadius: 34, yRadius: 34)
    blue.setFill()
    calendar.fill()

    let headerRect = NSRect(x: 228, y: 674, width: 568, height: 76)
    deepBlue.setFill()
    NSBezierPath(rect: headerRect).fill()

    // Round only the two upper corners of the calendar header.
    let headerTop = NSBezierPath()
    headerTop.move(to: NSPoint(x: 228, y: 674))
    headerTop.line(to: NSPoint(x: 228, y: 750))
    headerTop.curve(to: NSPoint(x: 262, y: 786), controlPoint1: NSPoint(x: 228, y: 770), controlPoint2: NSPoint(x: 242, y: 786))
    headerTop.line(to: NSPoint(x: 762, y: 786))
    headerTop.curve(to: NSPoint(x: 796, y: 750), controlPoint1: NSPoint(x: 782, y: 786), controlPoint2: NSPoint(x: 796, y: 770))
    headerTop.line(to: NSPoint(x: 796, y: 674))
    headerTop.close()
    deepBlue.setFill()
    headerTop.fill()

    // Binder rings with the white cutouts used by the reference mark.
    for centerX in [350.0, 674.0] {
        let ring = NSBezierPath(roundedRect: NSRect(x: centerX - 15, y: 762, width: 30, height: 104), xRadius: 15, yRadius: 15)
        blue.setFill()
        ring.fill()
        let cutout = NSBezierPath(roundedRect: NSRect(x: centerX - 6, y: 778, width: 12, height: 62), xRadius: 6, yRadius: 6)
        NSColor.white.setFill()
        cutout.fill()
    }

    // Two restrained curved arrows form the sync mark.
    let upperArrow = NSBezierPath()
    upperArrow.move(to: NSPoint(x: 412, y: 493))
    upperArrow.curve(to: NSPoint(x: 596, y: 521), controlPoint1: NSPoint(x: 392, y: 594), controlPoint2: NSPoint(x: 530, y: 619))
    stroke(upperArrow, color: .white, width: 20)
    fillArrowhead(tip: NSPoint(x: 596, y: 521), wingA: NSPoint(x: 558, y: 558), wingB: NSPoint(x: 546, y: 503))

    let lowerArrow = NSBezierPath()
    lowerArrow.move(to: NSPoint(x: 614, y: 457))
    lowerArrow.curve(to: NSPoint(x: 430, y: 429), controlPoint1: NSPoint(x: 634, y: 356), controlPoint2: NSPoint(x: 496, y: 331))
    stroke(lowerArrow, color: .white, width: 20)
    fillArrowhead(tip: NSPoint(x: 430, y: 429), wingA: NSPoint(x: 468, y: 392), wingB: NSPoint(x: 480, y: 447))

    // Clock badge overlaps the lower-right corner of the calendar.
    let clockCenter = NSPoint(x: 714, y: 314)
    let clockRadius: CGFloat = 104
    let clock = NSBezierPath(ovalIn: NSRect(x: clockCenter.x - clockRadius, y: clockCenter.y - clockRadius, width: clockRadius * 2, height: clockRadius * 2))
    deepBlue.setFill()
    clock.fill()
    stroke(clock, color: .white, width: 13)

    let hands = NSBezierPath()
    hands.move(to: clockCenter)
    hands.line(to: NSPoint(x: clockCenter.x, y: clockCenter.y + 54))
    hands.move(to: clockCenter)
    hands.line(to: NSPoint(x: clockCenter.x + 43, y: clockCenter.y))
    stroke(hands, color: .white, width: 12)

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CalendarSyncIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode the icon as PNG."])
    }
    let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/CalendarSyncIcon.png")
    try png.write(to: output, options: .atomic)
}

try drawIcon()
