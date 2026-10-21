import AppKit
import Carbon.HIToolbox

/// An app window that can be picked in window mode, in global Cocoa coordinates.
struct WindowTarget {
    let windowID: CGWindowID
    let frame: CGRect

    /// Front-to-back list of normal app windows. Reading bounds needs no Screen Recording permission.
    static func onScreen() -> [WindowTarget] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width > 40, height > 40 else { return nil }
            // Window-server bounds are y-down from the top of the primary display.
            return WindowTarget(windowID: w[kCGWindowNumber as String] as? CGWindowID ?? 0,
                                frame: CGRect(x: x, y: primaryHeight - y - height, width: width, height: height))
        }
    }
}

/// One overlay window per display; resolves to the chosen pixels or nil when cancelled.
@MainActor
final class SelectionSession {
    enum Mode { case area, window }

    private(set) var mode: Mode
    let screens: [FrozenScreen]
    let targets: [WindowTarget]
    private var overlays: [SelectionOverlayWindow] = []
    private var continuation: CheckedContinuation<GrabResult?, Never>?
    private var keyTap: Any?
    private(set) var hideLoupe = false
    /// The app the user was in gets focus back afterwards.
    private var previousApp: NSRunningApplication?

    init(mode: Mode, screens: [FrozenScreen]) {
        self.mode = mode
        self.screens = screens
        self.targets = WindowTarget.onScreen()
    }

    func run() async -> GrabResult? {
        await withCheckedContinuation { cont in
            continuation = cont
            present()
        }
    }

    private func present() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        NSApp.activate(ignoringOtherApps: true)
        for screen in screens {
            let w = SelectionOverlayWindow(screen: screen, session: self)
            overlays.append(w)
            w.orderFrontRegardless()
        }
        let mouse = NSEvent.mouseLocation
        (overlays.first { $0.frame.contains(mouse) } ?? overlays.first)?.makeKey()
        NSCursor.crosshair.push()
        keyTap = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                self.hideLoupe = event.modifierFlags.contains(.option)
                self.redraw()
                return event
            }
            switch Int(event.keyCode) {
            case kVK_Escape:
                self.finish(nil)
            case kVK_Space:
                self.mode = self.mode == .area ? .window : .area
                self.redraw()
            default:
                break
            }
            return nil
        }
    }

    func redraw() {
        for w in overlays { w.overlay.needsDisplay = true }
    }

    func target(at globalPoint: CGPoint) -> WindowTarget? {
        targets.first { $0.frame.contains(globalPoint) }
    }

    func complete(localRect: CGRect, on screen: FrozenScreen) {
        let pixels = CGRect(x: localRect.minX * screen.scale, y: localRect.minY * screen.scale,
                            width: localRect.width * screen.scale, height: localRect.height * screen.scale).integral
        guard pixels.width >= 2, pixels.height >= 2, let cropped = screen.image.cropping(to: pixels) else {
            finish(nil)
            return
        }
        finish(GrabResult(image: cropped, scale: screen.scale))
    }

    func finish(_ result: GrabResult?) {
        guard let cont = continuation else { return }
        continuation = nil
        if let keyTap { NSEvent.removeMonitor(keyTap) }
        keyTap = nil
        NSCursor.pop()
        for w in overlays { w.orderOut(nil) }
        overlays.removeAll()
        if NSApp.windows.allSatisfy({ !$0.isVisible || $0 is NSPanel || !$0.canBecomeMain }) {
            previousApp?.activate()
        }
        cont.resume(returning: result)
    }
}

final class SelectionOverlayWindow: NSWindow {
    let overlay: SelectionOverlayView

    init(screen: FrozenScreen, session: SelectionSession) {
        overlay = SelectionOverlayView(screen: screen, session: session)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = overlay
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Draws the frozen screen image, the selection, the loupe and the hint line for one display.
final class SelectionOverlayView: NSView {
    private let screen: FrozenScreen
    private unowned let session: SelectionSession
    private var cursor: CGPoint?
    private var anchor: CGPoint?
    private var current: CGPoint?
    private var isDragging = false
    private var trackingArea: NSTrackingArea?

    init(screen: FrozenScreen, session: SelectionSession) {
        self.screen = screen
        self.session = session
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        let mouse = NSEvent.mouseLocation
        if screen.frame.contains(mouse) {
            cursor = CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // MARK: Coordinates

    private func global(_ local: CGPoint) -> CGPoint {
        CGPoint(x: screen.frame.minX + local.x, y: screen.frame.maxY - local.y)
    }

    private func local(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - screen.frame.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    private var selection: CGRect? {
        guard let a = anchor, let b = current, isDragging else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).intersection(bounds)
    }

    private var hoveredWindow: CGRect? {
        guard let p = cursor, let t = session.target(at: global(p)) else { return nil }
        return local(t.frame).intersection(bounds)
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        if window?.isKeyWindow == false { window?.makeKey() }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        cursor = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursor = p
        anchor = p
        current = p
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard session.mode == .area, let anchor else { return }
        let p = convert(event.locationInWindow, from: nil)
        cursor = p
        current = p
        if hypot(p.x - anchor.x, p.y - anchor.y) > 3 { isDragging = true }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            anchor = nil
            current = nil
            isDragging = false
        }
        if session.mode == .area, let rect = selection {
            session.complete(localRect: rect, on: screen)
        } else if let rect = hoveredWindow {
            // A click without dragging takes the window under the pointer.
            session.complete(localRect: rect, on: screen)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        session.finish(nil)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Renderer.drawFlipped(ctx, screen.image, in: bounds)
        let dim = NSColor.black.withAlphaComponent(0.32).cgColor

        if let sel = selection {
            cutOut(ctx, sel, dim: dim)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(sel.insetBy(dx: -0.5, dy: -0.5))
            drawSizeTag(for: sel)
        } else if session.mode == .window, let w = hoveredWindow {
            cutOut(ctx, w, dim: dim)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(w.insetBy(dx: 1, dy: 1))
        } else {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.12).cgColor)
            ctx.fill(bounds)
            if session.mode == .area, let p = cursor { drawGuides(ctx, at: p) }
        }

        if let p = cursor, session.mode == .area, !session.hideLoupe {
            drawLoupe(ctx, at: p)
        }
        drawHints()
    }

    private func cutOut(_ ctx: CGContext, _ rect: CGRect, dim: CGColor) {
        ctx.setFillColor(dim)
        ctx.addRect(bounds)
        ctx.addRect(rect)
        ctx.fillPath(using: .evenOdd)
    }

    private func drawGuides(_ ctx: CGContext, at p: CGPoint) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1)
        let x = p.x.rounded() + 0.5, y = p.y.rounded() + 0.5
        ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: bounds.maxX, y: y))
        ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: bounds.maxY))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func tag(_ text: String, at origin: CGPoint, fontSize: CGFloat = 11) -> CGRect {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = CGRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 3), withAttributes: attrs)
        return rect
    }

    private func drawSizeTag(for sel: CGRect) {
        let w = Int((sel.width * screen.scale).rounded()), h = Int((sel.height * screen.scale).rounded())
        var origin = CGPoint(x: sel.minX, y: sel.maxY + 6)
        if origin.y + 24 > bounds.maxY { origin.y = sel.maxY - 30 }
        origin.x = min(max(origin.x, 4), bounds.maxX - 100)
        _ = tag("\(w) × \(h)", at: origin)
    }

    /// Magnified pixels around the pointer, a pixel grid and the colour under the pointer.
    private func drawLoupe(_ ctx: CGContext, at p: CGPoint) {
        let side: CGFloat = 112
        let across = 15
        let px = Int((p.x * screen.scale).rounded(.down)), py = Int((p.y * screen.scale).rounded(.down))
        let half = across / 2
        guard let crop = screen.image.cropping(to: CGRect(x: px - half, y: py - half, width: across, height: across)) else { return }

        var origin = CGPoint(x: p.x + 20, y: p.y + 20)
        if origin.x + side > bounds.maxX { origin.x = p.x - 20 - side }
        if origin.y + side + 30 > bounds.maxY { origin.y = p.y - 20 - side - 30 }
        let box = CGRect(origin: origin, size: CGSize(width: side, height: side))
        let path = CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 10, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.interpolationQuality = .none
        let cell = side / CGFloat(across)
        // At screen edges the sample is clipped; keep the pointer's pixel in the centre cell.
        let offX = CGFloat(max(0, -(px - half))) * cell
        let offY = CGFloat(max(0, -(py - half))) * cell
        Renderer.drawFlipped(ctx, crop, in: CGRect(x: box.minX + offX, y: box.minY + offY,
                                                   width: CGFloat(crop.width) * cell, height: CGFloat(crop.height) * cell))
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
        ctx.setLineWidth(0.5)
        for i in 1..<across {
            let o = CGFloat(i) * cell
            ctx.move(to: CGPoint(x: box.minX + o, y: box.minY)); ctx.addLine(to: CGPoint(x: box.minX + o, y: box.maxY))
            ctx.move(to: CGPoint(x: box.minX, y: box.minY + o)); ctx.addLine(to: CGPoint(x: box.maxX, y: box.minY + o))
        }
        ctx.strokePath()
        let center = CGRect(x: box.minX + CGFloat(half) * cell, y: box.minY + CGFloat(half) * cell, width: cell, height: cell)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(center)
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        let g = global(p)
        _ = tag("\(Int(g.x)), \(Int(screen.frame.maxY - g.y))   \(hexColor(x: px, y: py))", at: CGPoint(x: box.minX, y: box.maxY + 6))
    }

    private func hexColor(x: Int, y: Int) -> String {
        guard let px = screen.image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return "" }
        var data = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "" }
        ctx.draw(px, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return String(format: "#%02X%02X%02X", data[0], data[1], data[2])
    }

    /// One line of keycaps at the bottom of the display under the pointer.
    private func drawHints() {
        guard cursor != nil else { return }
        let hints: [(String, String)] = session.mode == .area
            ? [("drag", "area"), ("click", "window"), ("space", "pick windows"), ("⌥", "no magnifier"), ("esc", "cancel")]
            : [("click", "window"), ("space", "draw an area"), ("esc", "cancel")]
        let keyFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let textFont = NSFont.systemFont(ofSize: 12)
        let gap: CGFloat = 16
        let sizes = hints.map { key, text -> (CGSize, CGSize) in
            ((key as NSString).size(withAttributes: [.font: keyFont]), (text as NSString).size(withAttributes: [.font: textFont]))
        }
        let total = sizes.reduce(0) { $0 + $1.0.width + 10 + 6 + $1.1.width } + gap * CGFloat(hints.count - 1)
        let bar = CGRect(x: bounds.midX - total / 2 - 12, y: bounds.maxY - 64, width: total + 24, height: 30)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 8, yRadius: 8).fill()
        var x = bar.minX + 12
        for (i, (key, text)) in hints.enumerated() {
            let (ks, ts) = sizes[i]
            let cap = CGRect(x: x, y: bar.midY - 9, width: ks.width + 10, height: 18)
            NSColor.white.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: cap, xRadius: 4, yRadius: 4).fill()
            (key as NSString).draw(at: CGPoint(x: cap.minX + 5, y: cap.midY - ks.height / 2),
                                   withAttributes: [.font: keyFont, .foregroundColor: NSColor.white])
            x = cap.maxX + 6
            (text as NSString).draw(at: CGPoint(x: x, y: bar.midY - ts.height / 2),
                                    withAttributes: [.font: textFont, .foregroundColor: NSColor.white.withAlphaComponent(0.8)])
            x += ts.width + gap
        }
    }
}
