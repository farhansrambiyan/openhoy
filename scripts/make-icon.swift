// Renders the OpenHoy app icon (1024px PNG). Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let inset: CGFloat = 100
let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let squircle = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// Shadow + gradient tile
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
squircle.addClip()
NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.36, blue: 0.16, alpha: 1),
                    NSColor(srgbRed: 0.93, green: 0.12, blue: 0.55, alpha: 1),
                    NSColor(srgbRed: 0.45, green: 0.18, blue: 0.95, alpha: 1)])!.draw(in: tile, angle: -60)
// soft glow blob
NSGradient(colors: [NSColor.white.withAlphaComponent(0.45), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSBezierPath(ovalIn: NSRect(x: 160, y: 520, width: 620, height: 520)), relativeCenterPosition: .zero)
NSGraphicsContext.restoreGraphicsState()

// Dark glass bubbles
func bubble(_ rect: NSRect, alpha: CGFloat) {
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
    NSColor.black.withAlphaComponent(alpha).setFill()
    path.fill()
    NSColor.white.withAlphaComponent(0.35).setStroke()
    path.lineWidth = 4
    path.stroke()
}
bubble(NSRect(x: 230, y: 560, width: 470, height: 150), alpha: 0.55)
bubble(NSRect(x: 330, y: 360, width: 470, height: 150), alpha: 0.72)
// dots in front bubble
NSColor.white.withAlphaComponent(0.95).setFill()
for i in 0..<3 {
    NSBezierPath(ovalIn: NSRect(x: 455 + CGFloat(i) * 80, y: 412, width: 46, height: 46)).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
