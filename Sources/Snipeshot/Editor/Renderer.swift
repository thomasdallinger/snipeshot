import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Where the capture sits inside the rendered canvas (crop plus backdrop padding).
struct CanvasLayout {
    /// Visible part of the image, in document points.
    let contentRect: CGRect
    /// Backdrop padding around the content, 0 when the backdrop is off.
    let padding: CGFloat
    let backdrop: Backdrop?

    var canvasSize: CGSize {
        CGSize(width: contentRect.width + padding * 2, height: contentRect.height + padding * 2)
    }

    /// Content frame in canvas coordinates.
    var imageFrame: CGRect {
        CGRect(x: padding, y: padding, width: contentRect.width, height: contentRect.height)
    }

    func docToCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - contentRect.minX + padding, y: p.y - contentRect.minY + padding)
    }

    func canvasToDoc(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + contentRect.minX - padding, y: p.y + contentRect.minY - padding)
    }

    func docToCanvas(_ r: CGRect) -> CGRect {
        r.offsetBy(dx: padding - contentRect.minX, dy: padding - contentRect.minY)
    }

    static func make(pointSize: CGSize, crop: CGRect?, backdrop: Backdrop, showFullImage: Bool) -> CanvasLayout {
        if showFullImage {
            return CanvasLayout(contentRect: CGRect(origin: .zero, size: pointSize), padding: 0, backdrop: nil)
        }
        let content = (crop ?? CGRect(origin: .zero, size: pointSize)).integral
            .intersection(CGRect(origin: .zero, size: pointSize))
        let bd = backdrop.enabled ? backdrop : nil
        return CanvasLayout(contentRect: content, padding: bd?.padding ?? 0, backdrop: bd)
    }
}

/// Pixelated and blurred copies of the original image for redaction, built once per image.
final class RedactionCache {
    private var pixelated: [ObjectIdentifier: CGImage] = [:]
    private var blurred: [ObjectIdentifier: CGImage] = [:]
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func image(for style: Redaction, base: CGImage, scale: CGFloat) -> CGImage? {
        let key = ObjectIdentifier(base)
        switch style {
        case .blackout:
            return nil
        case .pixelate:
            if let cached = pixelated[key] { return cached }
            let input = CIImage(cgImage: base)
            let f = CIFilter.pixellate()
            f.inputImage = input.clampedToExtent()
            f.scale = Float(max(8, 12 * scale))
            f.center = .zero
            let out = f.outputImage?.cropped(to: input.extent)
            let img = out.flatMap { context.createCGImage($0, from: input.extent) }
            pixelated[key] = img
            return img
        case .blur:
            if let cached = blurred[key] { return cached }
            let input = CIImage(cgImage: base)
            let f = CIFilter.gaussianBlur()
            f.inputImage = input.clampedToExtent()
            f.radius = Float(max(10, 14 * scale))
            let out = f.outputImage?.cropped(to: input.extent)
            let img = out.flatMap { context.createCGImage($0, from: input.extent) }
            blurred[key] = img
            return img
        }
    }
}

enum Renderer {
    struct Source {
        let image: CGImage
        let pointSize: CGSize
        let scale: CGFloat
        let redactions: RedactionCache
    }

    // MARK: - Whole canvas

    /// Draws backdrop, image and annotations into a y-down context in canvas coordinates.
    static func drawCanvas(_ ctx: CGContext, source: Source, layout: CanvasLayout, annotations: [Annotation],
                           hiding hiddenID: UUID? = nil) {
        let frame = layout.imageFrame
        if let bd = layout.backdrop {
            drawBackdrop(ctx, fill: bd.fill, size: layout.canvasSize)
            if bd.shadow {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: NSColor.black.withAlphaComponent(0.22).cgColor)
                ctx.addPath(CGPath(roundedRect: frame, cornerWidth: bd.radius, cornerHeight: bd.radius, transform: nil))
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillPath()
                ctx.restoreGState()
            }
        }

        ctx.saveGState()
        if let bd = layout.backdrop, bd.radius > 0 {
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: bd.radius, cornerHeight: bd.radius, transform: nil))
            ctx.clip()
        } else {
            ctx.clip(to: frame)
        }
        // Move into document space: content origin lands on the image frame.
        ctx.translateBy(x: layout.padding - layout.contentRect.minX, y: layout.padding - layout.contentRect.minY)
        drawFlipped(ctx, source.image, in: CGRect(origin: .zero, size: source.pointSize))
        for a in annotations where a.id != hiddenID {
            draw(a, in: ctx, source: source)
        }
        ctx.restoreGState()
    }

    static func drawBackdrop(_ ctx: CGContext, fill: BackdropFill, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        switch fill {
        case .color(let c):
            ctx.setFillColor(c.cgColor)
            ctx.fill(rect)
        case .preset(let preset):
            let colors = preset.colors.map(\.cgColor) as CFArray
            guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) else { return }
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
    }

    /// CGContext.draw assumes y-up; flip locally so the image stays upright in y-down space.
    static func drawFlipped(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    // MARK: - Annotations

    static func draw(_ a: Annotation, in ctx: CGContext, source: Source) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch a.type {
        case .rectangle:
            let r = a.frame.standardized
            let radius = min(max(a.stroke, 4), min(r.width, r.height) / 2)
            if a.filled {
                ctx.setFillColor(a.color.cgColor)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
            } else {
                let inset = r.insetBy(dx: a.stroke / 2, dy: a.stroke / 2)
                guard inset.width > 0, inset.height > 0 else { break }
                ctx.setStrokeColor(a.color.cgColor)
                ctx.setLineWidth(a.stroke)
                let ir = max(0, min(radius - a.stroke / 2, min(inset.width, inset.height) / 2))
                ctx.addPath(CGPath(roundedRect: inset, cornerWidth: ir, cornerHeight: ir, transform: nil))
                ctx.strokePath()
            }
        case .ellipse:
            let r = a.frame.standardized
            if a.filled {
                ctx.setFillColor(a.color.cgColor)
                ctx.fillEllipse(in: r)
            } else {
                let inset = r.insetBy(dx: a.stroke / 2, dy: a.stroke / 2)
                guard inset.width > 0, inset.height > 0 else { break }
                ctx.setStrokeColor(a.color.cgColor)
                ctx.setLineWidth(a.stroke)
                ctx.strokeEllipse(in: inset)
            }
        case .line:
            guard a.points.count >= 2 else { break }
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.stroke)
            ctx.move(to: a.points[0])
            ctx.addLine(to: a.points[1])
            ctx.strokePath()
        case .arrow:
            guard a.points.count >= 2 else { break }
            ctx.setFillColor(a.color.cgColor)
            ctx.addPath(arrowPath(from: a.points[0], to: a.points[1], width: a.stroke))
            ctx.fillPath()
        case .pen, .highlighter:
            guard !a.points.isEmpty else { break }
            let highlighter = a.type == .highlighter
            ctx.setStrokeColor((highlighter ? a.color.withAlpha(0.38) : a.color).cgColor)
            ctx.setLineWidth(highlighter ? max(a.stroke * 3, 14) : a.stroke)
            if highlighter {
                ctx.setBlendMode(.multiply)
                ctx.setLineCap(.butt)
            }
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()
        case .text:
            drawText(a, in: ctx)
        case .step:
            let r = a.frame.standardized
            ctx.setFillColor(a.color.cgColor)
            ctx.fillEllipse(in: r)
            let label = "\(a.step)" as NSString
            let font = NSFont.monospacedDigitSystemFont(ofSize: r.height * 0.5, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: a.color.isLight ? NSColor.black : NSColor.white,
            ]
            let size = label.size(withAttributes: attrs)
            withNSContext(ctx) {
                label.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
            }
        case .redaction:
            let r = a.frame.standardized
            if a.redaction == .blackout {
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fill(r)
            } else if let effect = source.redactions.image(for: a.redaction, base: source.image, scale: source.scale) {
                ctx.clip(to: r)
                drawFlipped(ctx, effect, in: CGRect(origin: .zero, size: source.pointSize))
            }
        }
    }

    /// Tapered shaft plus a solid head, sized from the stroke width.
    static func arrowPath(from start: CGPoint, to end: CGPoint, width: CGFloat) -> CGPath {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        let headLength = min(max(width * 3.6, 14), length * 0.6)
        let headHalf = max(width * 2.0, 8)
        let base = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
        let tail = max(width * 0.25, 0.75)
        let neck = width * 0.6

        let path = CGMutablePath()
        path.move(to: CGPoint(x: start.x + nx * tail, y: start.y + ny * tail))
        path.addLine(to: CGPoint(x: base.x + nx * neck, y: base.y + ny * neck))
        path.addLine(to: CGPoint(x: base.x + nx * headHalf, y: base.y + ny * headHalf))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: base.x - nx * headHalf, y: base.y - ny * headHalf))
        path.addLine(to: CGPoint(x: base.x - nx * neck, y: base.y - ny * neck))
        path.addLine(to: CGPoint(x: start.x - nx * tail, y: start.y - ny * tail))
        path.addArc(center: start, radius: tail, startAngle: atan2(-ny, -nx), endAngle: atan2(ny, nx), clockwise: false)
        path.closeSubpath()
        return path
    }

    /// Quadratic smoothing through midpoints keeps freehand strokes from looking jagged.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
            return path
        }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    // MARK: - Text

    static func textAttributes(textSize: CGFloat, color: RGBA) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        // A faint halo keeps text readable on busy screenshots without looking like an effect.
        shadow.shadowColor = (color.isLight ? NSColor.black : NSColor.white).withAlphaComponent(0.35)
        shadow.shadowBlurRadius = max(1.5, textSize * 0.06)
        shadow.shadowOffset = .zero
        return [
            .font: NSFont.systemFont(ofSize: textSize, weight: .semibold),
            .foregroundColor: color.nsColor,
            .shadow: shadow,
        ]
    }

    static func measure(_ text: String, textSize: CGFloat) -> CGSize {
        let s = (text.isEmpty ? " " : text) as NSString
        let size = s.boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin],
                                  attributes: textAttributes(textSize: textSize, color: .red)).size
        return CGSize(width: ceil(size.width) + 4, height: ceil(size.height))
    }

    private static func drawText(_ a: Annotation, in ctx: CGContext) {
        guard !a.text.isEmpty else { return }
        let attrs = textAttributes(textSize: a.textSize, color: a.color)
        let frame = CGRect(x: a.frame.minX + 2, y: a.frame.minY, width: 10_000, height: 10_000)
        withNSContext(ctx) {
            (a.text as NSString).draw(with: frame, options: [.usesLineFragmentOrigin], attributes: attrs)
        }
    }

    /// Text drawing needs an NSGraphicsContext; wrap the CGContext as a flipped one.
    static func withNSContext(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Export

    /// Renders the edited capture at full pixel resolution.
    static func flatten(source: Source, layout: CanvasLayout, annotations: [Annotation]) -> CGImage? {
        let scale = source.scale
        let w = Int((layout.canvasSize.width * scale).rounded())
        let h = Int((layout.canvasSize.height * scale).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Bitmap contexts are y-up; flip into the canvas' y-down space.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        drawCanvas(ctx, source: source, layout: layout, annotations: annotations)
        return ctx.makeImage()
    }
}
