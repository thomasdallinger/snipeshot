import AppKit
import Carbon.HIToolbox
import Combine

/// The drawing surface. Coordinates are canvas points (image plus backdrop padding), y-down.
final class CanvasView: NSView, NSTextFieldDelegate {
    enum Handle: CaseIterable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight, lineStart, lineEnd
    }

    private enum Gesture {
        case none
        case pendingShape(anchor: CGPoint, tool: Tool)
        case drawingShape(id: UUID, anchor: CGPoint)
        case movingAnnotation(id: UUID, last: CGPoint, registered: Bool)
        case resizingAnnotation(id: UUID, handle: Handle, original: Annotation)
        case cropNew(anchor: CGPoint)
        case cropMove(start: CGPoint, original: CGRect)
        case cropResize(handle: Handle, original: CGRect)
    }

    let session: EditSession
    private var document: MarkupDocument { session.document }
    private var tools: ToolSettings { session.tools }
    private var gesture: Gesture = .none
    private var textField: NSTextField?
    private var textSessionID: UUID?
    private var textSessionIsNew = false
    private var isCommittingText = false
    private var cancellables = Set<AnyCancellable>()
    private var hoverArea: NSTrackingArea?

    init(session: EditSession) {
        self.session = session
        super.init(frame: CGRect(origin: .zero, size: session.document.layout().canvasSize))
        document.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }.store(in: &cancellables)
        tools.$tool.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.window?.invalidateCursorRects(for: self)
            }
        }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var displayLayout: CanvasLayout { document.layout(showFullImage: tools.isCropping) }

    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }
    /// A distance of `points` on screen, expressed in canvas units.
    private func screen(_ points: CGFloat) -> CGFloat { points / max(magnification, 0.01) }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let comp = displayLayout
        Renderer.drawCanvas(ctx, source: document.source, layout: comp, annotations: document.annotations, hiding: textSessionID)

        if tools.isCropping {
            drawCropOverlay(ctx, comp)
        } else if let sel = document.selectedItem, sel.id != textSessionID {
            drawSelection(ctx, sel, comp)
        }
    }

    private func drawSelection(_ ctx: CGContext, _ a: Annotation, _ comp: CanvasLayout) {
        ctx.saveGState()
        let accent = NSColor.controlAccentColor.cgColor
        if !a.type.isSegment {
            let outline = comp.docToCanvas(a.bounds).insetBy(dx: -screen(3), dy: -screen(3))
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(screen(1))
            ctx.stroke(outline)
        }
        for (_, rect) in handleRects(for: a, comp) {
            drawHandle(ctx, rect, accent: accent)
        }
        ctx.restoreGState()
    }

    private func drawHandle(_ ctx: CGContext, _ rect: CGRect, accent: CGColor) {
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(screen(1))
        ctx.stroke(rect.insetBy(dx: screen(0.5), dy: screen(0.5)))
    }

    private func drawCropOverlay(_ ctx: CGContext, _ comp: CanvasLayout) {
        guard let draft = tools.pendingCrop?.standardized else { return }
        let r = comp.docToCanvas(draft)
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.addRect(bounds)
        ctx.addRect(r)
        ctx.fillPath(using: .evenOdd)

        // Rule of thirds, faint.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(screen(1))
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3
            let y = r.minY + r.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: r.minY)); ctx.addLine(to: CGPoint(x: x, y: r.maxY))
            ctx.move(to: CGPoint(x: r.minX, y: y)); ctx.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        ctx.strokePath()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(screen(1))
        ctx.stroke(r)
        let s = screen(7)
        for (_, p) in rectHandles(r) {
            drawHandle(ctx, CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s), accent: NSColor.white.cgColor)
        }
        ctx.restoreGState()

        let label = "\(Int((draft.width * document.scale).rounded())) × \(Int((draft.height * document.scale).rounded()))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: screen(11), weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        let tag = CGRect(x: r.minX, y: r.maxY + screen(6), width: size.width + screen(10), height: size.height + screen(4))
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: tag, xRadius: screen(4), yRadius: screen(4)).fill()
        label.draw(at: CGPoint(x: tag.minX + screen(5), y: tag.minY + screen(2)), withAttributes: attrs)
    }

    // MARK: - Handles & hit testing

    private func handleRects(for a: Annotation, _ comp: CanvasLayout) -> [(Handle, CGRect)] {
        let s = screen(7)
        func box(_ p: CGPoint) -> CGRect { CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s) }
        if a.type.isSegment, a.points.count >= 2 {
            return [(.lineStart, box(comp.docToCanvas(a.points[0]))), (.lineEnd, box(comp.docToCanvas(a.points[1])))]
        }
        guard a.type.isBoxed else { return [] }
        return rectHandles(comp.docToCanvas(a.frame.standardized)).map { ($0.0, box($0.1)) }
    }

    private func rectHandles(_ r: CGRect) -> [(Handle, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)), (.topRight, CGPoint(x: r.maxX, y: r.minY)),
         (.left, CGPoint(x: r.minX, y: r.midY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)), (.bottomRight, CGPoint(x: r.maxX, y: r.maxY))]
    }

    private func handle(at p: CGPoint, for a: Annotation, _ comp: CanvasLayout) -> Handle? {
        handleRects(for: a, comp).first { $0.1.insetBy(dx: -screen(4), dy: -screen(4)).contains(p) }?.0
    }

    private func cropHandle(at canvasPoint: CGPoint, _ comp: CanvasLayout) -> Handle? {
        guard let draft = tools.pendingCrop?.standardized else { return nil }
        let r = comp.docToCanvas(draft)
        let tol = screen(10)
        return rectHandles(r).first { abs($0.1.x - canvasPoint.x) < tol && abs($0.1.y - canvasPoint.y) < tol }?.0
    }

    /// Topmost annotation under a document point.
    private func annotation(at p: CGPoint) -> Annotation? {
        let tol = screen(6)
        for a in document.annotations.reversed() {
            switch a.type {
            case .line, .arrow, .pen, .highlighter:
                let reach = max(a.stroke * (a.type == .highlighter ? 1.6 : 0.5), 0) + tol
                if a.points.count == 1, hypot(a.points[0].x - p.x, a.points[0].y - p.y) < reach { return a }
                for i in 0..<max(a.points.count - 1, 0) where distance(p, a.points[i], a.points[i + 1]) < reach { return a }
            case .rectangle, .ellipse:
                let r = a.frame.standardized
                if a.filled {
                    if r.insetBy(dx: -tol, dy: -tol).contains(p) { return a }
                } else {
                    let outer = r.insetBy(dx: -tol, dy: -tol)
                    let inner = r.insetBy(dx: a.stroke + tol, dy: a.stroke + tol)
                    if outer.contains(p) && (inner.isEmpty || !inner.contains(p)) { return a }
                }
            default:
                if a.bounds.insetBy(dx: -tol, dy: -tol).contains(p) { return a }
            }
        }
        return nil
    }

    private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - Mouse

    private func points(for event: NSEvent) -> (canvas: CGPoint, doc: CGPoint) {
        let c = convert(event.locationInWindow, from: nil)
        return (c, displayLayout.canvasToDoc(c))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if textSessionID != nil {
            endTextSession()
            return
        }
        let comp = displayLayout
        let (c, p) = points(for: event)

        if tools.isCropping {
            if let h = cropHandle(at: c, comp), let draft = tools.pendingCrop {
                gesture = .cropResize(handle: h, original: draft.standardized)
            } else if let draft = tools.pendingCrop, draft.standardized.contains(p),
                      draft.standardized != CGRect(origin: .zero, size: document.pointSize) {
                // An untouched full-image draft can't be moved; dragging draws a new crop instead.
                gesture = .cropMove(start: p, original: draft.standardized)
            } else {
                gesture = .cropNew(anchor: clampToImage(p))
            }
            return
        }

        // The selected annotation's handles win regardless of tool.
        if let sel = document.selectedItem, let h = handle(at: c, for: sel, comp) {
            gesture = .resizingAnnotation(id: sel.id, handle: h, original: sel)
            document.registerUndo()
            return
        }

        let tool = tools.tool
        let hit = annotation(at: p)

        if tool == .select || (hit != nil && hit?.id == document.selectionID) {
            guard let hit else {
                document.selectionID = nil
                return
            }
            document.selectionID = hit.id
            if event.clickCount == 2 && hit.type == .text {
                beginTextSession(editing: hit)
                return
            }
            gesture = .movingAnnotation(id: hit.id, last: p, registered: false)
            return
        }

        switch tool {
        case .text:
            if let hit, hit.type == .text {
                document.selectionID = hit.id
                beginTextSession(editing: hit)
            } else {
                beginNewTextSession(at: p)
            }
        case .step:
            document.registerUndo()
            var a = Annotation(type: .step)
            let d = tools.textSize
            a.frame = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
            a.color = tools.color
            a.textSize = d
            a.step = document.nextStep
            document.add(a)
            document.selectionID = a.id
            document.didChange()
        case .select:
            break
        default:
            document.selectionID = nil
            gesture = .pendingShape(anchor: p, tool: tool)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let (_, p) = points(for: event)
        let shift = event.modifierFlags.contains(.shift)
        switch gesture {
        case .none:
            break
        case let .pendingShape(anchor, tool):
            guard hypot(p.x - anchor.x, p.y - anchor.y) > screen(3), let type = tool.annotationType else { return }
            document.registerUndo()
            var a = Annotation(type: type)
            a.color = tools.color
            a.stroke = tools.stroke
            a.filled = tools.filled && type.canFill
            a.redaction = tools.redaction
            a.textSize = tools.textSize
            if type.isFreehand { a.points = [anchor] }
            if type.isSegment { a.points = [anchor, anchor] }
            document.add(a)
            document.selectionID = a.id
            gesture = .drawingShape(id: a.id, anchor: anchor)
            mouseDragged(with: event)
        case let .drawingShape(id, anchor):
            document.update(id) { a in
                switch a.type {
                case .pen, .highlighter:
                    if let last = a.points.last, hypot(last.x - p.x, last.y - p.y) >= screen(1) { a.points.append(p) }
                case .line, .arrow:
                    a.points = [anchor, shift ? snap45(from: anchor, to: p) : p]
                default:
                    a.frame = rectFrom(anchor, p, square: shift)
                }
            }
        case let .movingAnnotation(id, last, registered):
            if !registered { document.registerUndo() }
            document.update(id) { $0.offset(by: CGVector(dx: p.x - last.x, dy: p.y - last.y)) }
            gesture = .movingAnnotation(id: id, last: p, registered: true)
        case let .resizingAnnotation(id, handle, original):
            document.update(id) { a in
                switch handle {
                case .lineStart: a.points[0] = shift ? snap45(from: original.points[1], to: p) : p
                case .lineEnd: a.points[1] = shift ? snap45(from: original.points[0], to: p) : p
                default: a.frame = resize(original.frame.standardized, handle: handle, to: p)
                }
            }
        case let .cropNew(anchor):
            tools.pendingCrop = rectFrom(anchor, clampToImage(p), square: shift)
            needsDisplay = true
        case let .cropMove(start, original):
            let full = CGRect(origin: .zero, size: document.pointSize)
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(r.minX, 0), full.width - r.width)
            r.origin.y = min(max(r.minY, 0), full.height - r.height)
            tools.pendingCrop = r
            needsDisplay = true
        case let .cropResize(handle, original):
            tools.pendingCrop = resize(original, handle: handle, to: clampToImage(p))
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch gesture {
        case let .drawingShape(id, _):
            if let a = document.annotations.first(where: { $0.id == id }), isDegenerate(a) {
                document.annotations.removeAll { $0.id == id }
                document.selectionID = nil
            }
            document.didChange()
        case .movingAnnotation(_, _, true), .resizingAnnotation:
            document.didChange()
        default:
            break
        }
        gesture = .none
        needsDisplay = true
    }

    private func isDegenerate(_ a: Annotation) -> Bool {
        switch a.type {
        case .pen, .highlighter: return false
        case .line, .arrow: return a.points.count < 2 || hypot(a.points[0].x - a.points[1].x, a.points[0].y - a.points[1].y) < 3
        default: return a.frame.standardized.width < 3 || a.frame.standardized.height < 3
        }
    }

    private func rectFrom(_ a: CGPoint, _ b: CGPoint, square: Bool) -> CGRect {
        var w = b.x - a.x, h = b.y - a.y
        if square {
            let side = max(abs(w), abs(h))
            w = side * (w < 0 ? -1 : 1)
            h = side * (h < 0 ? -1 : 1)
        }
        return CGRect(x: a.x, y: a.y, width: w, height: h).standardized
    }

    private func snap45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let len = hypot(dx, dy)
        return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
    }

    private func resize(_ r: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .left: minX = p.x
        case .right: maxX = p.x
        case .bottomLeft: minX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomRight: maxX = p.x; maxY = p.y
        case .lineStart, .lineEnd: break
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), document.pointSize.width), y: min(max(p.y, 0), document.pointSize.height))
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let (_, p) = points(for: event)
        guard !tools.isCropping, let hit = annotation(at: p) else { return nil }
        document.selectionID = hit.id
        let menu = NSMenu()
        menu.addItem(withTitle: "Bring to Front", action: #selector(menuBringToFront(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Send to Back", action: #selector(menuSendToBack(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Duplicate", action: #selector(menuDuplicate(_:)), keyEquivalent: "d")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(menuDelete(_:)), keyEquivalent: "\u{8}")
        for item in menu.items { item.target = self }
        return menu
    }

    @objc private func menuBringToFront(_ sender: Any?) {
        if let id = document.selectionID { document.bringToFront(id) }
    }

    @objc private func menuSendToBack(_ sender: Any?) {
        if let id = document.selectionID { document.sendToBack(id) }
    }

    @objc private func menuDuplicate(_ sender: Any?) {
        if let id = document.selectionID { document.duplicate(id) }
    }

    @objc private func menuDelete(_ sender: Any?) {
        if let id = document.selectionID { document.delete(id) }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case kVK_Escape:
            if tools.isCropping { session.cancelCrop() }
            else if document.selectionID != nil { document.selectionID = nil }
            else if tools.tool != .select { session.selectTool(.select) }
            return
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if tools.isCropping { session.applyCrop(); return }
            if let sel = document.selectedItem, sel.type == .text { beginTextSession(editing: sel); return }
        case kVK_Delete, kVK_ForwardDelete:
            if let id = document.selectionID { document.delete(id) }
            return
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            nudge(event)
            return
        default:
            break
        }
        if flags.isDisjoint(with: [.command, .control, .option]), let chars = event.charactersIgnoringModifiers?.lowercased() {
            if let tool = Tool.allCases.first(where: { String($0.key) == chars }) {
                session.selectTool(tool)
                return
            }
        }
        super.keyDown(with: event)
    }

    private func nudge(_ event: NSEvent) {
        guard let id = document.selectionID else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var d = CGVector.zero
        switch Int(event.keyCode) {
        case kVK_LeftArrow: d.dx = -step
        case kVK_RightArrow: d.dx = step
        case kVK_UpArrow: d.dy = -step
        default: d.dy = step
        }
        document.registerUndo()
        document.update(id) { $0.offset(by: d) }
        document.didChange()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, textSessionID == nil,
              event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            switch key {
            case "z": session.undo(); return true
            case "c": session.copyToClipboard(); return true
            case "s": session.document.saveNow(); session.tools.notify("Saved"); return true
            case "d": if let id = document.selectionID { document.duplicate(id) }; return true
            case "=", "+": session.zoomIn(); return true
            case "-": session.zoomOut(); return true
            case "0": session.zoomToFit(); return true
            case "1": session.zoomActualSize(); return true
            default: break
            }
        }
        if flags == [.command, .shift], key == "z" { session.redo(); return true }
        if flags == [.command, .shift], key == "e" { session.export(); return true }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        let cursor: NSCursor
        if tools.isCropping { cursor = .crosshair }
        else {
            switch tools.tool {
            case .select: cursor = .arrow
            case .text: cursor = .iBeam
            default: cursor = .crosshair
            }
        }
        addCursorRect(visibleRect, cursor: cursor)
    }

    // MARK: - Text editing

    private func beginNewTextSession(at p: CGPoint) {
        var a = Annotation(type: .text)
        a.color = tools.color
        a.textSize = tools.textSize
        let size = Renderer.measure("", textSize: a.textSize)
        a.frame = CGRect(x: p.x, y: p.y - size.height / 2, width: size.width, height: size.height)
        document.registerUndo()
        document.add(a)
        document.selectionID = a.id
        textSessionIsNew = true
        startField(for: a)
    }

    private func beginTextSession(editing a: Annotation) {
        document.registerUndo()
        textSessionIsNew = false
        startField(for: a)
    }

    private func startField(for a: Annotation) {
        textSessionID = a.id
        let field = NSTextField(string: a.text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: a.textSize, weight: .bold)
        field.textColor = a.color.nsColor
        field.usesSingleLineMode = false
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.delegate = self
        addSubview(field)
        textField = field
        layoutTextField()
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    private func layoutTextField() {
        guard let field = textField, let id = textSessionID, let a = document.annotations.first(where: { $0.id == id }) else { return }
        let size = Renderer.measure(field.stringValue, textSize: a.textSize)
        let origin = displayLayout.docToCanvas(a.frame.origin)
        field.frame = CGRect(x: origin.x - 2 + 2, y: origin.y, width: size.width + a.textSize, height: size.height + 4)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField, let id = textSessionID else { return }
        document.update(id) { a in
            a.text = field.stringValue
            a.frame.size = Renderer.measure(field.stringValue, textSize: a.textSize)
        }
        layoutTextField()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endTextSession()
            return true
        }
        if commandSelector == #selector(NSResponder.insertLineBreak(_:)) || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endTextSession()
    }

    func endTextSession() {
        guard let id = textSessionID, !isCommittingText else { return }
        isCommittingText = true
        defer { isCommittingText = false }
        let text = textField?.stringValue ?? ""
        textField?.delegate = nil
        textField?.removeFromSuperview()
        textField = nil
        textSessionID = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.annotations.removeAll { $0.id == id }
            if document.selectionID == id { document.selectionID = nil }
        } else {
            document.update(id) { a in
                a.text = text
                a.frame.size = Renderer.measure(text, textSize: a.textSize)
            }
        }
        document.didChange()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}
