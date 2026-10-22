// Renders the app icon (1024×1024 PNG). Usage: swift scripts/make-icon.swift <out.png>
// A capture area with a crosshair aimed at a single pixel: precise capture, nothing else.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// macOS icon grid: an 824 pt rounded square centred on the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
let center = CGPoint(x: tile.midX, y: tile.midY)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.28))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0xE5342E))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

// Hairline along the edge, the only depth cue.
ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
ctx.setLineWidth(6)
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
ctx.strokePath()

let white = rgb(0xFFFFFF)
ctx.setStrokeColor(white)
ctx.setFillColor(white)

// The capture area: a landscape rectangle, like a selection on screen.
let area = CGRect(x: center.x - 270, y: center.y - 200, width: 540, height: 400)
ctx.setLineWidth(34)
ctx.setLineJoin(.miter)
ctx.stroke(area)

// Crosshair ticks crossing each edge at its midpoint, stopping short of the centre.
ctx.setLineCap(.butt)
let inner: CGFloat = 110, overshoot: CGFloat = 70
for (dx, dy, edge) in [(0.0, 1.0, area.height / 2), (0.0, -1.0, area.height / 2), (1.0, 0.0, area.width / 2), (-1.0, 0.0, area.width / 2)] {
    ctx.move(to: CGPoint(x: center.x + dx * inner, y: center.y + dy * inner))
    ctx.addLine(to: CGPoint(x: center.x + dx * (edge + overshoot), y: center.y + dy * (edge + overshoot)))
}
ctx.strokePath()

// The pixel being aimed at.
let pixel: CGFloat = 64
ctx.fill(CGRect(x: center.x - pixel / 2, y: center.y - pixel / 2, width: pixel, height: pixel))
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
