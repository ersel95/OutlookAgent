// Generates a 1024x1024 PNG icon for OutlookAgent.
// Run: swift icon_generator.swift <output.png>
import AppKit
import Foundation

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon-1024.png"

let size = NSSize(width: 1024, height: 1024)
let img = NSImage(size: size)

img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no context")
}

// Background — diagonal gradient (Agora-inspired blue → purple)
let bgPath = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                          xRadius: 224, yRadius: 224)
bgPath.addClip()

let grad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.10, green: 0.32, blue: 0.92, alpha: 1.0),  // deep blue top-left
        CGColor(red: 0.40, green: 0.18, blue: 0.85, alpha: 1.0),  // violet bottom-right
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(grad,
                       start: CGPoint(x: 0, y: size.height),
                       end: CGPoint(x: size.width, y: 0),
                       options: [])

// Soft inner highlight ring
let ring = NSBezierPath(roundedRect: NSRect(x: 24, y: 24,
                                            width: size.width - 48,
                                            height: size.height - 48),
                        xRadius: 200, yRadius: 200)
NSColor(white: 1.0, alpha: 0.06).setStroke()
ring.lineWidth = 6
ring.stroke()

// Envelope silhouette (centered)
// Body rectangle
let envW: CGFloat = 620
let envH: CGFloat = 420
let envX = (size.width - envW) / 2
let envY = (size.height - envH) / 2 - 40

let envBody = NSBezierPath(roundedRect: NSRect(x: envX, y: envY,
                                               width: envW, height: envH),
                           xRadius: 38, yRadius: 38)
NSColor.white.setFill()
envBody.fill()

// Envelope flap (V on top)
let flap = NSBezierPath()
flap.move(to: NSPoint(x: envX + 24, y: envY + envH - 24))
flap.line(to: NSPoint(x: envX + envW / 2, y: envY + envH * 0.42))
flap.line(to: NSPoint(x: envX + envW - 24, y: envY + envH - 24))
flap.lineWidth = 28
flap.lineCapStyle = .round
flap.lineJoinStyle = .round
NSColor(red: 0.10, green: 0.32, blue: 0.92, alpha: 1.0).setStroke()
flap.stroke()

// Bottom horizontal lines (suggesting message lines)
let lineY1 = envY + 90
let lineY2 = envY + 50
let lineL = envX + 130
let lineR = envX + envW - 130
NSColor(red: 0.10, green: 0.32, blue: 0.92, alpha: 0.18).setStroke()

let l1 = NSBezierPath()
l1.move(to: NSPoint(x: lineL, y: lineY1))
l1.line(to: NSPoint(x: lineR, y: lineY1))
l1.lineWidth = 14
l1.lineCapStyle = .round
l1.stroke()

let l2 = NSBezierPath()
l2.move(to: NSPoint(x: lineL + 60, y: lineY2))
l2.line(to: NSPoint(x: lineR - 60, y: lineY2))
l2.lineWidth = 14
l2.lineCapStyle = .round
l2.stroke()

// AI sparkle in upper-right corner of envelope (a 4-point star)
func sparkle(at center: CGPoint, radius: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: center.x, y: center.y + radius))
    path.curve(to: NSPoint(x: center.x + radius, y: center.y),
               controlPoint1: NSPoint(x: center.x + radius * 0.25, y: center.y + radius * 0.25),
               controlPoint2: NSPoint(x: center.x + radius * 0.25, y: center.y + radius * 0.25))
    path.curve(to: NSPoint(x: center.x, y: center.y - radius),
               controlPoint1: NSPoint(x: center.x + radius * 0.25, y: center.y - radius * 0.25),
               controlPoint2: NSPoint(x: center.x + radius * 0.25, y: center.y - radius * 0.25))
    path.curve(to: NSPoint(x: center.x - radius, y: center.y),
               controlPoint1: NSPoint(x: center.x - radius * 0.25, y: center.y - radius * 0.25),
               controlPoint2: NSPoint(x: center.x - radius * 0.25, y: center.y - radius * 0.25))
    path.curve(to: NSPoint(x: center.x, y: center.y + radius),
               controlPoint1: NSPoint(x: center.x - radius * 0.25, y: center.y + radius * 0.25),
               controlPoint2: NSPoint(x: center.x - radius * 0.25, y: center.y + radius * 0.25))
    path.close()
    color.setFill()
    path.fill()
}

// Three sparkles, varying sizes
sparkle(at: CGPoint(x: envX + envW - 60, y: envY + envH + 40),
        radius: 64, color: NSColor(red: 1.0, green: 0.85, blue: 0.30, alpha: 1.0))
sparkle(at: CGPoint(x: envX + envW + 30, y: envY + envH - 60),
        radius: 36, color: NSColor(red: 1.0, green: 0.95, blue: 0.55, alpha: 0.95))
sparkle(at: CGPoint(x: envX + envW - 110, y: envY + envH + 130),
        radius: 22, color: NSColor.white.withAlphaComponent(0.85))

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png encode failed")
}

let url = URL(fileURLWithPath: outPath)
try png.write(to: url)
print("✓ wrote \(url.path) (\(png.count) bytes)")
