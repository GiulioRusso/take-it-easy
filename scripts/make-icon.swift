// Renders the app icon (macOS icon grid: 824 pt rounded square on a 1024 canvas) into
// TakeItEasy/Assets.xcassets/AppIcon.appiconset. Run: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Drop shadow under the tile, as on Apple's icons.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = .black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

// Calm blue → indigo gradient, lighter at the top.
NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.72, blue: 1.00, alpha: 1),
                    NSColor(srgbRed: 0.27, green: 0.35, blue: 0.93, alpha: 1)])!.draw(in: shape, angle: -90)
// Soft top highlight.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [.white.withAlphaComponent(0.22), .white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// The multitool: same symbol as the menu bar icon, white with a soft shadow.
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
let symbol = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let size = symbol.size
NSGraphicsContext.saveGraphicsState()
let glyphShadow = NSShadow()
glyphShadow.shadowColor = .black.withAlphaComponent(0.25)
glyphShadow.shadowBlurRadius = 18
glyphShadow.shadowOffset = NSSize(width: 0, height: -8)
glyphShadow.set()
symbol.draw(in: NSRect(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2, width: size.width, height: size.height))
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.current = nil

let dir = URL(fileURLWithPath: "TakeItEasy/Assets.xcassets/AppIcon.appiconset")
let master = rep.representation(using: .png, properties: [:])!
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(data: master)!.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.current = nil
        try! small.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: dir.appendingPathComponent("Contents.json"))
print("Icon written to \(dir.path)")
