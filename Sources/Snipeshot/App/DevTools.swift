import AppKit
import ImageIO

/// Launch flags for development and verification (see docs/DEVELOPMENT.md):
///
///   --self-test                  Logic checks: edit-file format, canvas tools, crop, export, drag file.
///   --simulate-capture <image>   Run the after-capture steps (save, clipboard, shelf) with an existing image.
///   --snapshot-ui <dir> <image>  Treat <image> as a capture, mark it up and render the shelf, library window,
///                                selector, settings and the flattened export into <dir>, then quit.
///                                Needs no Screen Recording permission.
///
/// Dev runs use throwaway preferences and delete the captures they create.
enum DevTools {
    static var isDevRun: Bool {
        let args = CommandLine.arguments
        return args.contains("--self-test") || args.contains("--snapshot-ui")
    }

    static func scratchDefaults() -> UserDefaults {
        let suite = "\(AppIdentity.bundleID).devtools"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite) ?? .standard
    }

    /// Returns true when a flag took over the launch.
    static func handleLaunchArguments(_ app: AppDelegate) -> Bool {
        let args = CommandLine.arguments
        if args.contains("--self-test") {
            exit(SelfTest.run(app))
        }
        if let i = args.firstIndex(of: "--simulate-capture"), args.indices.contains(i + 1) {
            if let result = loadImage(args[i + 1]) { app.didGrab(result) }
            return true
        }
        if let i = args.firstIndex(of: "--snapshot-ui"), args.indices.contains(i + 2) {
            MainActor.assumeIsolated { snapshotUI(app, outDir: URL(fileURLWithPath: args[i + 1]), sample: args[i + 2]) }
            return true
        }
        return false
    }

    static func loadImage(_ path: String) -> GrabResult? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            log("unreadable image at \(path)")
            return nil
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = props?[kCGImagePropertyDPIWidth] as? Double ?? 144
        return GrabResult(image: image, scale: CGFloat(max(1, (dpi / 72).rounded())))
    }

    @MainActor
    private static func snapshotUI(_ app: AppDelegate, outDir: URL, sample: String) {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        guard let result = loadImage(sample) else { exit(2) }
        app.prefs.copyAfterCapture = false
        app.prefs.captureSound = false
        app.didGrab(result)

        after(1) {
            render(app.shelf.debugPanel?.contentView, to: outDir.appendingPathComponent("shelf.png"))
            guard let url = app.shelf.itemURLs.last else { exit(3) }
            app.openLibrary(opening: url)

            after(1) {
                guard let session = app.libraryModel.session else { exit(4) }
                markUp(session)
                session.selectTool(.select)
                session.document.selectionID = session.document.annotations.first?.id
                session.layoutChanged()

                after(1) {
                    render(app.libraryWindow?.window?.contentView, to: outDir.appendingPathComponent("library.png"))
                    if let flat = session.document.flattened() {
                        try? ImageWriter.write(flat, to: outDir.appendingPathComponent("export.png"), format: .png, quality: 1, scale: session.document.scale)
                    }
                    renderSelector(sample: result.image, to: outDir.appendingPathComponent("selector.png"))
                    app.openSettings(tab: .shortcuts)
                    app.libraryModel.closeSession()
                    // Leave no test capture behind.
                    try? FileManager.default.removeItem(at: url)
                    EditFileStore.remove(for: url)

                    after(1) {
                        render(NSApp.windows.first { $0.title.hasSuffix("Settings") }?.contentView, to: outDir.appendingPathComponent("settings.png"))
                        log("snapshots written to \(outDir.path)")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    private static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { body() } }
    }

    /// Renders the area selector over a fake frozen screen with a drag in progress.
    @MainActor
    private static func renderSelector(sample: CGImage, to url: URL) {
        guard let screen = NSScreen.main else { return }
        let stills = FrozenScreen(screen: screen, image: sample, scale: CGFloat(sample.width) / screen.frame.width)
        let session = SelectionSession(mode: .area, screens: [stills])
        let window = SelectionOverlayWindow(screen: stills, session: session)
        let view = window.overlay
        func ev(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let size = screen.frame.size
        view.mouseDown(with: ev(.leftMouseDown, CGPoint(x: size.width * 0.25, y: size.height * 0.75)))
        view.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: size.width * 0.6, y: size.height * 0.35)))
        render(view, to: url)
    }

    private static func markUp(_ session: EditSession) {
        let doc = session.document
        let w = doc.pointSize.width, h = doc.pointSize.height
        doc.registerUndo()
        var box = Annotation(type: .rectangle)
        box.frame = CGRect(x: w * 0.08, y: h * 0.1, width: w * 0.35, height: h * 0.22)
        var arrow = Annotation(type: .arrow)
        arrow.points = [CGPoint(x: w * 0.75, y: h * 0.7), CGPoint(x: w * 0.46, y: h * 0.3)]
        var label = Annotation(type: .text)
        label.text = "Check this"
        label.frame = CGRect(origin: CGPoint(x: w * 0.55, y: h * 0.75), size: Renderer.measure("Check this", textSize: 28))
        var step = Annotation(type: .step)
        step.frame = CGRect(x: w * 0.06, y: h * 0.6, width: 28, height: 28)
        var redaction = Annotation(type: .redaction)
        redaction.frame = CGRect(x: w * 0.1, y: h * 0.75, width: w * 0.3, height: h * 0.12)
        var marker = Annotation(type: .highlighter)
        marker.color = .yellow
        marker.points = stride(from: 0.0, through: 1.0, by: 0.05).map { t in
            CGPoint(x: w * (0.5 + 0.4 * t), y: h * (0.12 + 0.03 * sin(t * 12)))
        }
        doc.annotations = [box, arrow, label, step, redaction, marker]
        doc.backdrop = Backdrop(enabled: true, fill: .preset(.mist), padding: 40, radius: 10, shadow: true)
        doc.didChange()
    }

    private static func render(_ view: NSView?, to url: URL) {
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            log("could not render \(url.lastPathComponent)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
