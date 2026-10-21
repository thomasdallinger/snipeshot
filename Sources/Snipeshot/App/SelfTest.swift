import AppKit
import Carbon.HIToolbox

/// `--self-test`: logic checks that run inside the real app binary
/// (the Command Line Tools toolchain ships without XCTest). Exits 0 when everything passes.
enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        print("\(condition ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        if !condition { failures += 1 }
    }

    static func run(blocked: Set<CaptureKind>) -> Int32 {
        editFileFormat()
        keyCombos()
        canvasTools()
        dragFile()
        print("INFO  shortcuts held by another app: \(blocked.isEmpty ? "none" : blocked.map(\.rawValue).sorted().joined(separator: ", "))")
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    private static func editFileFormat() {
        var arrow = Annotation(type: .arrow)
        arrow.points = [CGPoint(x: 1, y: 2), CGPoint(x: 30, y: 40)]
        var box = Annotation(type: .rectangle)
        box.frame = CGRect(x: 5, y: 6, width: 70, height: 80)
        box.color = RGBA(hex: "#2F6FEB")!
        let edits = EditFile(scale: 2, annotations: [arrow, box], crop: CGRect(x: 1, y: 2, width: 3, height: 4),
                             backdrop: Backdrop(enabled: true, fill: .preset(.sky)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(edits)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("edit file has a format version", json.contains("\"format\":1"))
        check("colours are stored as hex", json.contains("\"color\":\"#2F6FEB\""))
        check("rects are stored as [x,y,w,h]", json.contains("\"crop\":[1,2,3,4]") && json.contains("\"frame\":[5,6,70,80]"))
        check("arrows only store their points", !json.contains("\"frame\":[0,0,0,0]"))
        check("backdrop stores a preset name", json.contains("\"preset\":\"sky\""))
        let decoded = try? JSONDecoder().decode(EditFile.self, from: Data(json.utf8))
        check("edit file round-trips", decoded == edits)
    }

    private static func keyCombos() {
        check("⇧⌘4 is shown in macOS order", KeyCombo.area.displayString == "⇧⌘4", KeyCombo.area.displayString)
        check("⇧⌘4 matches the system shortcut mask", KeyCombo.area.cocoaModifierMask == 1_179_648)
        let systemArea = SystemShortcuts.current().first { $0.id == 30 }
        check("reads the macOS area shortcut", systemArea?.keyCode == kVK_ANSI_4, "enabled=\(systemArea?.enabled.description ?? "?")")
    }

    /// Drives the real canvas with synthesized mouse events.
    private static func canvasTools() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-canvas.png")
        defer {
            try? FileManager.default.removeItem(at: url)
            EditFileStore.remove(for: url)
        }
        let ctx = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        try? ImageWriter.write(ctx.makeImage()!, to: url, format: FileFormat.png, quality: 1, scale: 2)
        guard let doc = MarkupDocument.load(url: url) else { return check("load test image", false) }
        check("Retina DPI gives the point size", doc.pointSize == CGSize(width: 400, height: 300), "\(doc.pointSize)")

        let session = EditSession(document: doc)
        let canvas = CanvasView(session: session)
        session.canvas = canvas
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas

        func drag(_ from: CGPoint, _ to: CGPoint) {
            // The canvas is flipped; window coordinates are y-up.
            func ev(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: 300 - p.y), modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            canvas.mouseDown(with: ev(.leftMouseDown, from))
            for t in stride(from: 0.25, through: 1.0, by: 0.25) {
                canvas.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)))
            }
            canvas.mouseUp(with: ev(.leftMouseUp, to))
        }

        session.selectTool(.rectangle)
        drag(CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 120))
        let rect = doc.annotations.first
        check("rectangle tool draws a rectangle", rect?.type == .rectangle && rect?.frame == CGRect(x: 50, y: 50, width: 100, height: 70),
              "\(String(describing: rect?.frame))")
        check("new shapes use the default style", rect?.stroke == 4 && rect?.color == .red)

        session.selectTool(.arrow)
        drag(CGPoint(x: 200, y: 200), CGPoint(x: 300, y: 250))
        check("arrow tool draws an arrow", doc.annotations.last?.type == .arrow && doc.annotations.last?.points.last == CGPoint(x: 300, y: 250))

        session.selectTool(.select)
        drag(CGPoint(x: 50, y: 80), CGPoint(x: 70, y: 100)) // grab the rectangle's edge
        check("select tool moves an annotation", doc.annotations.first?.frame.origin == CGPoint(x: 70, y: 70),
              "\(String(describing: doc.annotations.first?.frame.origin))")

        session.setStroke(StrokePreset.large.rawValue)
        check("inspector style applies to the selection", doc.annotations.first?.stroke == 8)

        session.undo()
        session.undo()
        check("undo reverts style and move", doc.annotations.first?.frame.origin == CGPoint(x: 50, y: 50) && doc.annotations.first?.stroke == 4)
        session.redo()
        check("redo re-applies the move", doc.annotations.first?.frame.origin == CGPoint(x: 70, y: 70))

        session.selectTool(.step)
        drag(CGPoint(x: 350, y: 40), CGPoint(x: 350, y: 40))
        drag(CGPoint(x: 350, y: 120), CGPoint(x: 350, y: 120))
        let steps = doc.annotations.filter { $0.type == .step }.map(\.step)
        check("step tool numbers in order", steps == [1, 2], "\(steps)")

        session.selectTool(.crop)
        check("crop is a tool", session.tools.isCropping)
        drag(CGPoint(x: 20, y: 20), CGPoint(x: 220, y: 170))
        session.selectTool(.arrow) // switching tools keeps the crop
        check("crop applies when leaving the tool", doc.crop == CGRect(x: 20, y: 20, width: 200, height: 150), "\(String(describing: doc.crop))")
        check("export size follows the crop", doc.outputPixelSize == CGSize(width: 400, height: 300), "\(doc.outputPixelSize)")

        session.updateBackdrop { $0.enabled = true; $0.padding = 50 }
        check("backdrop padding grows the export", doc.outputPixelSize == CGSize(width: 600, height: 500), "\(doc.outputPixelSize)")
        let flat = doc.flattened()
        check("flattening renders", flat?.width == 600 && flat?.height == 500)

        doc.saveNow()
        let reloaded = MarkupDocument.load(url: url)
        check("edits survive a reload", reloaded?.annotations == doc.annotations && reloaded?.crop == doc.crop && reloaded?.backdrop == doc.backdrop)
    }

    private static func dragFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-drag.png")
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        try? ImageWriter.write(ctx.makeImage()!, to: url, format: FileFormat.png, quality: 1, scale: 1)
        defer {
            try? FileManager.default.removeItem(at: url)
            EditFileStore.remove(for: url)
        }
        check("an unedited capture drags the original", DragExport.fileForDrag(url) == url)
        var a = Annotation(type: .rectangle)
        a.frame = CGRect(x: 10, y: 10, width: 50, height: 50)
        EditFileStore.save(EditFile(scale: 1, annotations: [a], crop: nil, backdrop: Backdrop()), for: url)
        let dragged = DragExport.fileForDrag(url)
        check("an edited capture drags a flattened copy", dragged != url && FileManager.default.fileExists(atPath: dragged.path), dragged.lastPathComponent)
        let types = (url as NSURL).writableTypes(for: NSPasteboard.general)
        check("the drag offers a file URL", types.contains(.fileURL), types.map(\.rawValue).joined(separator: ","))
    }
}
