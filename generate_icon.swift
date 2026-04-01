#!/usr/bin/env swift
import Cocoa

func generateIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }

    // Flip coordinate system
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)

    // Background rounded rect
    let margin = s * 0.08
    let bgRect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
    ctx.addPath(bgPath)
    ctx.fillPath()

    // Battery body
    let bx = s * 0.22, by = s * 0.30, bw = s * 0.56, bh = s * 0.48
    let battRect = CGRect(x: bx, y: by, width: bw, height: bh)
    let battPath = CGPath(roundedRect: battRect, cornerWidth: s * 0.06, cornerHeight: s * 0.06, transform: nil)
    ctx.setFillColor(CGColor(red: 0.24, green: 0.24, blue: 0.28, alpha: 1))
    ctx.addPath(battPath)
    ctx.fillPath()
    ctx.setStrokeColor(CGColor(red: 0.55, green: 0.55, blue: 0.63, alpha: 1))
    ctx.setLineWidth(max(1, s / 100))
    ctx.addPath(battPath)
    ctx.strokePath()

    // Battery terminal nub
    let tx = s * 0.40, ty = s * 0.22, tw = s * 0.20, th = s * 0.10
    let termRect = CGRect(x: tx, y: ty, width: tw, height: th)
    let termPath = CGPath(roundedRect: termRect, cornerWidth: s * 0.03, cornerHeight: s * 0.03, transform: nil)
    ctx.setFillColor(CGColor(red: 0.24, green: 0.24, blue: 0.28, alpha: 1))
    ctx.addPath(termPath)
    ctx.fillPath()
    ctx.setStrokeColor(CGColor(red: 0.55, green: 0.55, blue: 0.63, alpha: 1))
    ctx.addPath(termPath)
    ctx.strokePath()

    // Flame - outer (orange)
    let cx = s * 0.50, cy = s * 0.54
    ctx.beginPath()
    ctx.move(to: CGPoint(x: cx, y: cy - s * 0.20))
    ctx.addCurve(to: CGPoint(x: cx + s * 0.14, y: cy + s * 0.04),
                 control1: CGPoint(x: cx + s * 0.04, y: cy - s * 0.16),
                 control2: CGPoint(x: cx + s * 0.14, y: cy - s * 0.06))
    ctx.addCurve(to: CGPoint(x: cx, y: cy + s * 0.18),
                 control1: CGPoint(x: cx + s * 0.14, y: cy + s * 0.12),
                 control2: CGPoint(x: cx + s * 0.06, y: cy + s * 0.18))
    ctx.addCurve(to: CGPoint(x: cx - s * 0.14, y: cy + s * 0.04),
                 control1: CGPoint(x: cx - s * 0.06, y: cy + s * 0.18),
                 control2: CGPoint(x: cx - s * 0.14, y: cy + s * 0.12))
    ctx.addCurve(to: CGPoint(x: cx, y: cy - s * 0.20),
                 control1: CGPoint(x: cx - s * 0.14, y: cy - s * 0.06),
                 control2: CGPoint(x: cx - s * 0.04, y: cy - s * 0.16))
    ctx.closePath()
    ctx.setFillColor(CGColor(red: 1.0, green: 0.47, blue: 0.08, alpha: 1))
    ctx.fillPath()

    // Flame - inner (yellow)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: cx, y: cy - s * 0.10))
    ctx.addCurve(to: CGPoint(x: cx + s * 0.08, y: cy + s * 0.04),
                 control1: CGPoint(x: cx + s * 0.02, y: cy - s * 0.06),
                 control2: CGPoint(x: cx + s * 0.08, y: cy - s * 0.02))
    ctx.addCurve(to: CGPoint(x: cx, y: cy + s * 0.12),
                 control1: CGPoint(x: cx + s * 0.08, y: cy + s * 0.08),
                 control2: CGPoint(x: cx + s * 0.03, y: cy + s * 0.12))
    ctx.addCurve(to: CGPoint(x: cx - s * 0.08, y: cy + s * 0.04),
                 control1: CGPoint(x: cx - s * 0.03, y: cy + s * 0.12),
                 control2: CGPoint(x: cx - s * 0.08, y: cy + s * 0.08))
    ctx.addCurve(to: CGPoint(x: cx, y: cy - s * 0.10),
                 control1: CGPoint(x: cx - s * 0.08, y: cy - s * 0.02),
                 control2: CGPoint(x: cx - s * 0.02, y: cy - s * 0.06))
    ctx.closePath()
    ctx.setFillColor(CGColor(red: 1.0, green: 0.86, blue: 0.20, alpha: 1))
    ctx.fillPath()

    img.unlockFocus()
    return img
}

func savePNG(_ image: NSImage, to path: String, pixelSize: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let basePath = "/Users/hongjunwu/Documents/Git/battery-burner/BatteryBurner/BatteryBurner/Assets.xcassets/AppIcon.appiconset"
let sizes = [16, 32, 64, 128, 256, 512, 1024]

for size in sizes {
    let icon = generateIcon(size: size)
    savePNG(icon, to: "\(basePath)/icon_\(size).png", pixelSize: size)
    print("Generated \(size)x\(size)")
}
print("Done!")
