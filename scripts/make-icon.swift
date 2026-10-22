// Renders the app icon (1024×1024 PNG). Usage: swift scripts/make-icon.swift <out.png>
// Corner brackets marking a square capture area, with a small crosshair on the pixel in the middle.
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

// Corner brackets of a square selection.
let half: CGFloat = 270, arm: CGFloat = 150
ctx.setLineWidth(36)
ctx.setLineCap(.butt)
ctx.setLineJoin(.miter)
for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
    let corner = CGPoint(x: center.x + sx * half, y: center.y + sy * half)
    ctx.move(to: CGPoint(x: corner.x - sx * arm, y: corner.y))
    ctx.addLine(to: corner)
    ctx.addLine(to: CGPoint(x: corner.x, y: corner.y - sy * arm))
}
ctx.strokePath()

// Small crosshair in the middle.
let reach: CGFloat = 100
ctx.setLineWidth(22)
ctx.move(to: CGPoint(x: center.x - reach, y: center.y)); ctx.addLine(to: CGPoint(x: center.x + reach, y: center.y))
ctx.move(to: CGPoint(x: center.x, y: center.y - reach)); ctx.addLine(to: CGPoint(x: center.x, y: center.y + reach))
ctx.strokePath()

// The pixel being aimed at.
let pixel: CGFloat = 56
ctx.fill(CGRect(x: center.x - pixel / 2, y: center.y - pixel / 2, width: pixel, height: pixel))
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
