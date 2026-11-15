// Renders README artwork: a hero banner and framed screenshots, plus the DMG background.
// Usage: swift scripts/make-readme-art.swift <screenshots-dir> <icon-png> <out-dir>
// Screenshots are real captures of UltaMac (taken with --redact). Nothing here is mocked.
import AppKit

let args = CommandLine.arguments
let shots = URL(fileURLWithPath: args[1])
let icon = NSImage(contentsOfFile: args[2])!
let out = URL(fileURLWithPath: args[3])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let teal = NSColor(calibratedRed: 0.13, green: 0.78, blue: 0.68, alpha: 1)
let blue = NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.95, alpha: 1)
let night = NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.13, alpha: 1)

func canvas(_ w: Int, _ h: Int, _ draw: (CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func backdrop(_ r: CGRect) {
    NSGradient(colors: [night, NSColor(calibratedRed: 0.07, green: 0.16, blue: 0.30, alpha: 1)])!.draw(in: r, angle: -35)
    // Soft brand glows.
    for (c, center, radius) in [(teal, CGPoint(x: r.width * 0.12, y: r.height * 0.15), r.width * 0.45),
                                (blue, CGPoint(x: r.width * 0.92, y: r.height * 0.95), r.width * 0.55)] {
        NSGradient(colors: [c.withAlphaComponent(0.35), c.withAlphaComponent(0)])!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }
}

func drawWindow(_ img: NSImage, in rect: CGRect) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = rect.width * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.012)
    shadow.set()
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at p: CGPoint, rounded: Bool = true) {
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if rounded, let d = font.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { font = f }
    (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
}

func load(_ name: String) -> NSImage { NSImage(contentsOf: shots.appendingPathComponent(name))! }

func fitted(_ img: NSImage, width: CGFloat) -> CGSize {
    let s = img.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? img.size
    return CGSize(width: width, height: width * s.height / s.width)
}

// 1. Hero banner (2560×1280)
let hero = canvas(2560, 1280) { r in
    backdrop(r)
    icon.draw(in: CGRect(x: 150, y: 800, width: 230, height: 230))
    text("UltaMac", size: 150, weight: .heavy, color: .white, at: CGPoint(x: 150, y: 580))
    text("The Ultimate Mac Toolkit", size: 58, weight: .semibold, color: NSColor.white.withAlphaComponent(0.85), at: CGPoint(x: 156, y: 490))
    text("Clean. Monitor. Optimise. Recover.", size: 46, weight: .medium, color: teal, at: CGPoint(x: 156, y: 405))
    for (i, chip) in ["100% offline", "No subscriptions", "Apple Silicon native", "Open source"].enumerated() {
        let font = NSFont.systemFont(ofSize: 30, weight: .semibold)
        let w = (chip as NSString).size(withAttributes: [.font: font]).width + 56
        let x = 156 + CGFloat([0, 290, 0, 400][i])
        let y = CGFloat(i < 2 ? 270 : 180)
        let rect = CGRect(x: x, y: y, width: w, height: 62)
        NSColor.white.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 31, yRadius: 31).fill()
        (chip as NSString).draw(at: CGPoint(x: x + 28, y: y + 14), withAttributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.9)])
    }
    let dash = load("dashboard.png")
    let size = fitted(dash, width: 1240)
    drawWindow(dash, in: CGRect(x: 1220, y: (r.height - size.height) / 2 - 20, width: size.width, height: size.height))
}
try hero.write(to: out.appendingPathComponent("hero.png"))

// 2. Framed screenshots (2400 wide)
for name in ["dashboard", "cleaner", "storage", "monitor", "uninstaller", "battery", "usb", "maintenance"] {
    let img = load("\(name).png")
    let size = fitted(img, width: 2160)
    let data = canvas(2400, Int(size.height) + 240) { r in
        backdrop(r)
        drawWindow(img, in: CGRect(x: 120, y: 120, width: size.width, height: size.height))
    }
    try data.write(to: out.appendingPathComponent("\(name).png"))
}

// 3. DMG background (1320×800 = 660×400 @2x)
let dmg = canvas(1320, 800) { r in
    backdrop(r)
    text("Drag UltaMac to Applications", size: 44, weight: .bold, color: .white, at: CGPoint(x: 330, y: 650))
    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: 560, y: 400)); arrow.line(to: CGPoint(x: 760, y: 400))
    arrow.move(to: CGPoint(x: 725, y: 435)); arrow.line(to: CGPoint(x: 762, y: 400)); arrow.line(to: CGPoint(x: 725, y: 365))
    arrow.lineWidth = 12; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    teal.setStroke(); arrow.stroke()
    text("Clean. Monitor. Optimise. Recover.", size: 28, weight: .medium, color: NSColor.white.withAlphaComponent(0.7), at: CGPoint(x: 432, y: 110))
}
try dmg.write(to: out.appendingPathComponent("dmg-background.png"))
print("art written to", out.path)
