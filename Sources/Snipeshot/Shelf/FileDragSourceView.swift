import AppKit
import SwiftUI

/// AppKit drag source for a capture file. Works in non-activating panels where SwiftUI's
/// `onDrag` and hover are unreliable, and hands other apps a real file URL
/// (Finder folders, Notion, terminals, Slack, mail…).
final class FileDragSourceNSView: NSView, NSDraggingSource {
    var fileURL: URL?
    var preview: NSImage?
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDragEnded: ((Bool) -> Void)?

    private var mouseDownPoint: CGPoint?
    private var dragStarted = false
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let start = mouseDownPoint, let url = fileURL else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        dragStarted = true

        let dragURL = DragExport.fileForDrag(url)
        let item = NSDraggingItem(pasteboardWriter: dragURL as NSURL)
        let image = preview ?? NSWorkspace.shared.icon(forFile: dragURL.path)
        let maxSide: CGFloat = 180
        let ratio = min(maxSide / max(image.size.width, 1), maxSide / max(image.size.height, 1), 1)
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        item.setDraggingFrame(CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    override func mouseUp(with event: NSEvent) {
        if !dragStarted { onClick?() }
        mouseDownPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy only: dropping on a Finder folder must never move the capture out of the library.
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragStarted = false
        mouseDownPoint = nil
        onDragEnded?(operation != [])
    }
}

struct FileDragSource: NSViewRepresentable {
    let url: URL
    let preview: NSImage?
    var onClick: () -> Void
    var onHover: (Bool) -> Void
    var onDragEnded: (Bool) -> Void

    func makeNSView(context: Context) -> FileDragSourceNSView {
        let v = FileDragSourceNSView()
        update(v)
        return v
    }

    func updateNSView(_ nsView: FileDragSourceNSView, context: Context) { update(nsView) }

    private func update(_ v: FileDragSourceNSView) {
        v.fileURL = url
        v.preview = preview
        v.onClick = onClick
        v.onHover = onHover
        v.onDragEnded = onDragEnded
    }
}

/// Hosting view that reacts to the first click even when the app is in the background.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
