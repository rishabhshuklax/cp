#!/usr/bin/env swift
//
// Draws the app icon and writes Resources/AppIcon.icns.
//
//     swift Scripts/make-icon.swift
//
// The icon is drawn in code rather than kept as a design file so that anyone
// can change it and rebuild it with nothing but the toolchain. The glyph is
// cp's own clipboard, not an SF Symbol: Apple's licence does not allow SF
// Symbols in app icons.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("cp-AppIcon.iconset")
let output = root.appendingPathComponent("Resources/AppIcon.icns")

/// Draws the icon into a square of `size` pixels. Everything is measured on
/// Apple's 1024-point grid, where the plate is 824 points with 100 of margin.
func drawIcon(size: CGFloat) {
    let unit = size / 1_024
    func scaled(_ value: CGFloat) -> CGFloat { value * unit }

    let plate = NSRect(x: scaled(100), y: scaled(100), width: scaled(824), height: scaled(824))
    let platePath = NSBezierPath(roundedRect: plate, xRadius: scaled(186), yRadius: scaled(186))

    // The plate: graphite, lit from above, with the soft shadow every Mac icon sits on.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -scaled(12))
    shadow.shadowBlurRadius = scaled(28)
    shadow.set()
    NSColor.black.setFill()
    platePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(srgbRed: 0.24, green: 0.26, blue: 0.33, alpha: 1),
        NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1),
    ])!.draw(in: platePath, angle: -90)

    // A hairline of light along the top edge, inside the plate.
    NSGraphicsContext.saveGraphicsState()
    platePath.addClip()
    let rim = NSBezierPath(roundedRect: plate.insetBy(dx: scaled(3), dy: scaled(3)), xRadius: scaled(183), yRadius: scaled(183))
    rim.lineWidth = scaled(6)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0.02)])!
        .draw(in: rim.strokedOutline(width: scaled(6)), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The clipboard: a board, the clip that holds the page, and two lines —
    // the second one the accent, because the second clip is what cp is for.
    let ink = NSColor.white.withAlphaComponent(0.96)
    let stroke = scaled(44)

    let board = NSBezierPath(roundedRect: NSRect(x: scaled(322), y: scaled(240), width: scaled(380), height: scaled(500)),
                             xRadius: scaled(84), yRadius: scaled(84))
    board.lineWidth = stroke
    ink.setStroke()
    board.stroke()

    let clip = NSBezierPath(roundedRect: NSRect(x: scaled(422), y: scaled(694), width: scaled(180), height: scaled(100)),
                            xRadius: scaled(40), yRadius: scaled(40))
    NSColor(srgbRed: 0.13, green: 0.14, blue: 0.19, alpha: 1).setFill()
    clip.fill()
    clip.lineWidth = stroke
    clip.stroke()

    func line(y: CGFloat, width: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: scaled(418), y: scaled(y)))
        path.line(to: NSPoint(x: scaled(418 + width), y: scaled(y)))
        path.lineWidth = stroke
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }
    line(y: 540, width: 188, color: ink)
    line(y: 420, width: 120, color: NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1))
}

extension NSBezierPath {
    /// The outline of this path stroked at `width`, as a fillable path.
    func strokedOutline(width: CGFloat) -> NSBezierPath {
        let cgPath = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<elementCount {
            switch element(at: index, associatedPoints: &points) {
            case .moveTo: cgPath.move(to: points[0])
            case .lineTo: cgPath.addLine(to: points[0])
            case .curveTo, .cubicCurveTo: cgPath.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: cgPath.addQuadCurve(to: points[1], control: points[0])
            case .closePath: cgPath.closeSubpath()
            @unknown default: break
            }
        }
        let stroked = cgPath.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        let result = NSBezierPath()
        stroked.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: result.move(to: p[0])
            case .addLineToPoint: result.line(to: p[0])
            case .addQuadCurveToPoint: result.curve(to: p[1], controlPoint1: p[0], controlPoint2: p[0])
            case .addCurveToPoint: result.curve(to: p[2], controlPoint1: p[0], controlPoint2: p[1])
            case .closeSubpath: result.close()
            @unknown default: break
            }
        }
        return result
    }
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(at: iconset)
print("wrote \(output.path)")
