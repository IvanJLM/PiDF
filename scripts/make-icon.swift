// Draws PiDF's app icon (same family as Visor, TextDown and Vids) and writes
// every size into the asset catalog.
// Usage: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Background: the same dark squircle as Visor.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(starting: color(0x0F111A), ending: color(0x2C3350))!.draw(in: tilePath, angle: 90)

// A page with its top right corner folded.
let page = NSRect(x: 292, y: 210, width: 440, height: 580)
let fold: CGFloat = 120
let sheet = NSBezierPath()
sheet.move(to: NSPoint(x: page.minX + 34, y: page.minY))
sheet.line(to: NSPoint(x: page.maxX - 34, y: page.minY))
sheet.curve(to: NSPoint(x: page.maxX, y: page.minY + 34), controlPoint1: NSPoint(x: page.maxX - 15, y: page.minY),
            controlPoint2: NSPoint(x: page.maxX, y: page.minY + 15))
sheet.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
sheet.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
sheet.line(to: NSPoint(x: page.minX + 34, y: page.maxY))
sheet.curve(to: NSPoint(x: page.minX, y: page.maxY - 34), controlPoint1: NSPoint(x: page.minX + 15, y: page.maxY),
            controlPoint2: NSPoint(x: page.minX, y: page.maxY - 15))
sheet.line(to: NSPoint(x: page.minX, y: page.minY + 34))
sheet.curve(to: NSPoint(x: page.minX + 34, y: page.minY), controlPoint1: NSPoint(x: page.minX, y: page.minY + 15),
            controlPoint2: NSPoint(x: page.minX + 15, y: page.minY))
sheet.close()
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor(white: 0, alpha: 0.45).cgColor)
NSGradient(starting: color(0xDCE0EC), ending: color(0xFFFFFF))!.draw(in: sheet, angle: 90)
context.restoreGState()

// The folded corner, in Visor's sunset colors.
let sunset = NSGradient(colors: [color(0xF2A35E), color(0xDC5A75), color(0x8E55C2)])!
let corner = NSBezierPath()
corner.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
corner.line(to: NSPoint(x: page.maxX - fold + 10, y: page.maxY - fold + 22))
corner.curve(to: NSPoint(x: page.maxX - fold + 22, y: page.maxY - fold + 10),
             controlPoint1: NSPoint(x: page.maxX - fold + 12, y: page.maxY - fold + 14),
             controlPoint2: NSPoint(x: page.maxX - fold + 14, y: page.maxY - fold + 12))
corner.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
corner.close()
sunset.draw(in: corner, angle: -45)

// Lines of text, the first one in the sunset colors like a heading.
context.saveGState()
NSBezierPath(roundedRect: NSRect(x: page.minX + 60, y: 640, width: 230, height: 34), xRadius: 17, yRadius: 17).addClip()
sunset.draw(in: NSRect(x: page.minX + 60, y: 640, width: 230, height: 34), angle: 0)
context.restoreGState()
color(0x2C3350, 0.35).setFill()
for (index, width) in [320, 300, 320, 250, 320, 290, 180].enumerated() {
    let y = 572 - CGFloat(index) * 50
    NSBezierPath(roundedRect: NSRect(x: page.minX + 60, y: y, width: CGFloat(width), height: 22), xRadius: 11, yRadius: 11).fill()
}

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!

let folder = URL(fileURLWithPath: "App/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let master = folder.appendingPathComponent("icon_512x512@2x.png")
try png.write(to: master)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let pixels = points * scale
        if pixels != 1024 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            task.arguments = ["-z", "\(pixels)", "\(pixels)", master.path, "--out", folder.appendingPathComponent(name).path]
            task.standardOutput = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
        }
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: folder.appendingPathComponent("Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.write(
    to: folder.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Icon written to \(folder.path)")
