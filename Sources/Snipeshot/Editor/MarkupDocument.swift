import AppKit
import Combine
import ImageIO

/// A capture being edited: the untouched original pixels plus a list of edits.
final class MarkupDocument: ObservableObject {
    let url: URL
    let image: CGImage
    /// Pixels per point (2 on Retina).
    let scale: CGFloat
    /// Image size in points; annotations live in this space.
    let pointSize: CGSize
    let redactions = RedactionCache()

    @Published var annotations: [Annotation]
    @Published var selectionID: UUID?
    @Published var crop: CGRect?
    @Published var backdrop: Backdrop
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isSaved = true

    private struct State: Equatable {
        var annotations: [Annotation]
        var crop: CGRect?
        var backdrop: Backdrop
    }

    private var past: [State] = []
    private var future: [State] = []
    private var pendingSave: DispatchWorkItem?

    init(url: URL, image: CGImage, scale: CGFloat, edits: EditFile?) {
        self.url = url
        self.image = image
        self.scale = max(scale, 1)
        self.pointSize = CGSize(width: CGFloat(image.width) / self.scale, height: CGFloat(image.height) / self.scale)
        self.annotations = edits?.annotations ?? []
        self.crop = edits?.crop
        self.backdrop = edits?.backdrop ?? Backdrop()
    }

    static func load(url: URL) -> MarkupDocument? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let edits = EditFileStore.load(for: url)
        return MarkupDocument(url: url, image: image, scale: edits?.scale ?? dpiScale(of: src), edits: edits)
    }

    /// Retina captures are written at 144 DPI; that recovers their point size.
    private static func dpiScale(of src: CGImageSource) -> CGFloat {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 72 else { return 1 }
        return CGFloat((dpi / 72).rounded())
    }

    var source: Renderer.Source {
        Renderer.Source(image: image, pointSize: pointSize, scale: scale, redactions: redactions)
    }

    var editFile: EditFile {
        EditFile(scale: scale, annotations: annotations, crop: crop, backdrop: backdrop)
    }

    var hasEdits: Bool { editFile.hasEdits }

    func layout(showFullImage: Bool = false) -> CanvasLayout {
        CanvasLayout.make(pointSize: pointSize, crop: crop, backdrop: backdrop, showFullImage: showFullImage)
    }

    /// Pixel size of the exported image.
    var outputPixelSize: CGSize {
        let size = layout().canvasSize
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    func flattened() -> CGImage? {
        guard hasEdits else { return image }
        return Renderer.flatten(source: source, layout: layout(), annotations: annotations)
    }

    // MARK: - Undo

    /// Call before every user-visible change so it can be undone.
    func registerUndo() {
        past.append(state)
        if past.count > 200 { past.removeFirst() }
        future.removeAll()
        updateUndoFlags()
    }

    /// Call when a change is finished (end of a drag, a toggle) to persist it.
    func didChange() {
        scheduleSave()
    }

    func undo() {
        guard let previous = past.popLast() else { return }
        future.append(state)
        restore(previous)
    }

    func redo() {
        guard let next = future.popLast() else { return }
        past.append(state)
        restore(next)
    }

    private var state: State { State(annotations: annotations, crop: crop, backdrop: backdrop) }

    private func restore(_ s: State) {
        annotations = s.annotations
        crop = s.crop
        backdrop = s.backdrop
        if let sel = selectionID, !annotations.contains(where: { $0.id == sel }) { selectionID = nil }
        updateUndoFlags()
        scheduleSave()
    }

    private func updateUndoFlags() {
        canUndo = !past.isEmpty
        canRedo = !future.isEmpty
    }

    // MARK: - Annotations

    func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return annotations.firstIndex { $0.id == id }
    }

    var selectedItem: Annotation? {
        index(of: selectionID).map { annotations[$0] }
    }

    func update(_ id: UUID, _ body: (inout Annotation) -> Void) {
        guard let i = index(of: id) else { return }
        body(&annotations[i])
    }

    func add(_ a: Annotation) {
        annotations.append(a)
    }

    func delete(_ id: UUID) {
        registerUndo()
        annotations.removeAll { $0.id == id }
        if selectionID == id { selectionID = nil }
        didChange()
    }

    func duplicate(_ id: UUID) {
        guard let original = annotations.first(where: { $0.id == id }) else { return }
        registerUndo()
        var copy = original
        copy.id = UUID()
        copy.offset(by: CGVector(dx: 16, dy: 16))
        if copy.type == .step { copy.step = nextStep }
        annotations.append(copy)
        selectionID = copy.id
        didChange()
    }

    func bringToFront(_ id: UUID) {
        guard let i = index(of: id), i != annotations.count - 1 else { return }
        registerUndo()
        annotations.append(annotations.remove(at: i))
        didChange()
    }

    func sendToBack(_ id: UUID) {
        guard let i = index(of: id), i != 0 else { return }
        registerUndo()
        annotations.insert(annotations.remove(at: i), at: 0)
        didChange()
    }

    var nextStep: Int {
        (annotations.filter { $0.type == .step }.map(\.step).max() ?? 0) + 1
    }

    // MARK: - Persistence

    func scheduleSave() {
        pendingSave?.cancel()
        isSaved = false
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        EditFileStore.save(editFile, for: url)
        isSaved = true
    }
}
