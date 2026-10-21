import AppKit
import Combine
import UniformTypeIdentifiers

/// One open capture: connects the SwiftUI chrome (header, inspector, status bar) with the AppKit canvas.
final class EditSession: ObservableObject {
    let document: MarkupDocument
    let tools = ToolSettings()
    @Published var zoomPercent = 100

    weak var canvas: CanvasView?
    weak var scrollView: NSScrollView?
    var onPin: ((URL) -> Void)?
    var onDelete: ((URL) -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var lastContinuousEdit = Date.distantPast
    private var toolBeforeCrop: Tool = .arrow

    init(document: MarkupDocument) {
        self.document = document
        // Forward nested changes so views observing the session refresh.
        document.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        tools.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    // MARK: - Tools

    func selectTool(_ tool: Tool) {
        guard tool != tools.tool else { return }
        canvas?.endTextSession()
        if tools.isCropping { applyCrop(switchingTo: tool) }
        if tool == .crop {
            beginCrop()
            return
        }
        tools.tool = tool
        if tool != .select { document.selectionID = nil }
        focusCanvas()
    }

    func focusCanvas() {
        canvas?.window?.makeFirstResponder(canvas)
        canvas?.needsDisplay = true
    }

    // MARK: - Style (also applied to the selection)

    /// What the inspector should show: the selection's type, or what the current tool would create.
    var styleTarget: AnnotationType? {
        document.selectedItem?.type ?? tools.tool.annotationType
    }

    var currentColor: RGBA { document.selectedItem?.color ?? tools.color }
    var currentStroke: CGFloat { document.selectedItem?.stroke ?? tools.stroke }
    var currentTextSize: CGFloat { document.selectedItem?.textSize ?? tools.textSize }
    var currentFilled: Bool { document.selectedItem?.filled ?? tools.filled }
    var currentRedaction: Redaction { document.selectedItem?.redaction ?? tools.redaction }

    func setColor(_ c: RGBA) {
        tools.color = c
        applyToSelection { $0.color = c }
    }

    func setStroke(_ w: CGFloat) {
        tools.stroke = w
        applyToSelection { a in if a.type.usesStroke { a.stroke = w } }
    }

    func setTextSize(_ size: CGFloat) {
        tools.textSize = size
        applyToSelection { a in
            guard a.type.usesTextSize else { return }
            let center = CGPoint(x: a.frame.midX, y: a.frame.midY)
            a.textSize = size
            if a.type == .text {
                a.frame.size = Renderer.measure(a.text, textSize: size)
            } else {
                a.frame = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            }
        }
    }

    func setFilled(_ filled: Bool) {
        tools.filled = filled
        applyToSelection { a in if a.type.canFill { a.filled = filled } }
    }

    func setRedaction(_ r: Redaction) {
        tools.redaction = r
        applyToSelection { a in if a.type == .redaction { a.redaction = r } }
    }

    private func applyToSelection(_ body: (inout Annotation) -> Void) {
        guard let id = document.selectionID else { return }
        document.registerUndo()
        document.update(id, body)
        document.didChange()
        canvas?.needsDisplay = true
    }

    // MARK: - Crop

    private func beginCrop() {
        toolBeforeCrop = tools.tool
        document.selectionID = nil
        tools.pendingCrop = document.crop ?? CGRect(origin: .zero, size: document.pointSize)
        tools.tool = .crop
        layoutChanged()
        focusCanvas()
    }

    /// Keeps the drafted crop and leaves crop mode.
    func applyCrop(switchingTo next: Tool? = nil) {
        guard tools.isCropping else { return }
        let full = CGRect(origin: .zero, size: document.pointSize)
        var newCrop = tools.pendingCrop?.standardized.integral.intersection(full)
        if let c = newCrop, c.width < 4 || c.height < 4 || c == full { newCrop = nil }
        if newCrop != document.crop {
            document.registerUndo()
            document.crop = newCrop
            document.didChange()
        }
        leaveCrop(to: next)
    }

    func cancelCrop() {
        guard tools.isCropping else { return }
        leaveCrop(to: nil)
    }

    private func leaveCrop(to next: Tool?) {
        tools.pendingCrop = nil
        tools.tool = next ?? (toolBeforeCrop == .crop ? .select : toolBeforeCrop)
        layoutChanged()
    }

    func resetCropDraft() {
        tools.pendingCrop = CGRect(origin: .zero, size: document.pointSize)
        canvas?.needsDisplay = true
    }

    func removeCrop() {
        guard document.crop != nil else { return }
        document.registerUndo()
        document.crop = nil
        document.didChange()
        layoutChanged()
    }

    // MARK: - Backdrop

    /// `continuous` edits (slider drags) collapse into one undo step per gesture.
    func updateBackdrop(continuous: Bool = false, _ body: (inout Backdrop) -> Void) {
        if !continuous || Date().timeIntervalSince(lastContinuousEdit) > 0.6 { document.registerUndo() }
        if continuous { lastContinuousEdit = Date() }
        body(&document.backdrop)
        document.didChange()
        layoutChanged()
    }

    // MARK: - Undo

    func undo() {
        canvas?.endTextSession()
        document.undo()
        layoutChanged()
    }

    func redo() {
        canvas?.endTextSession()
        document.redo()
        layoutChanged()
    }

    // MARK: - Output

    func copyToClipboard() {
        canvas?.endTextSession()
        guard let image = document.flattened() else { return }
        Clipboard.copy(image: image, scale: document.scale)
        tools.notify("Copied")
    }

    func export() {
        canvas?.endTextSession()
        guard let image = document.flattened() else { return }
        Exporter.save(image, scale: document.scale, suggestedName: document.url.deletingPathExtension().lastPathComponent,
                      edited: document.hasEdits) { [weak self] name in self?.tools.notify("Exported \(name)") }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([document.url])
    }

    func pin() {
        canvas?.endTextSession()
        document.saveNow()
        onPin?(document.url)
    }

    func delete() {
        onDelete?(document.url)
    }

    /// Persist everything before the session goes away.
    func close() {
        canvas?.endTextSession()
        if tools.isCropping { applyCrop() }
        document.saveNow()
    }

    // MARK: - Zoom

    func zoomIn() { setMagnification((scrollView?.magnification ?? 1) * 1.25) }
    func zoomOut() { setMagnification((scrollView?.magnification ?? 1) / 1.25) }
    func zoomActualSize() { setMagnification(1) }

    func zoomToFit() {
        guard let scrollView, let canvas else { return }
        let visible = CGSize(width: scrollView.contentView.bounds.width * scrollView.magnification,
                             height: scrollView.contentView.bounds.height * scrollView.magnification)
        let size = canvas.frame.size
        guard size.width > 0, size.height > 0 else { return }
        let fit = min((visible.width - 64) / size.width, (visible.height - 64) / size.height)
        setMagnification(min(max(fit, 0.05), 1))
    }

    func setMagnification(_ m: CGFloat) {
        guard let scrollView else { return }
        let clamped = min(max(m, scrollView.minMagnification), scrollView.maxMagnification)
        let center = CGPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY)
        scrollView.setMagnification(clamped, centeredAt: center)
        zoomPercent = Int((clamped * 100).rounded())
    }

    /// Canvas size depends on crop and backdrop; resize and refit when they change.
    func layoutChanged() {
        guard let canvas else { return }
        let newSize = canvas.displayLayout.canvasSize
        if canvas.frame.size != newSize {
            canvas.setFrameSize(newSize)
            DispatchQueue.main.async { self.zoomToFit() }
        }
        canvas.needsDisplay = true
    }
}

enum Clipboard {
    static func copy(image: CGImage, scale: CGFloat) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let item = NSPasteboardItem()
        if let png = rep.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item])
    }
}

/// "Export…" writes a flattened copy anywhere the user picks.
enum Exporter {
    static func save(_ image: CGImage, scale: CGFloat, suggestedName: String, edited: Bool, completion: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = edited ? "\(suggestedName) edited.png" : "\(suggestedName).png"
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        let key = "lastExportFolder"
        if let last = UserDefaults.standard.string(forKey: key) {
            panel.directoryURL = URL(fileURLWithPath: last)
        } else {
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: key)
        let format: FileFormat = url.pathExtension.lowercased().hasPrefix("jp") ? .jpeg : .png
        do {
            try ImageWriter.write(image, to: url, format: format, quality: 0.92, scale: scale)
            completion(url.lastPathComponent)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
