import AppKit
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    let prefs = Preferences(defaults: DevTools.isDevRun ? DevTools.scratchDefaults() : .standard)
    lazy var library = CaptureLibrary(settings: prefs)
    let previews = PreviewCache()
    lazy var libraryModel = LibraryModel(prefs: prefs, library: library, previews: previews)
    private let grabber = ScreenGrabber()
    private let shortcuts = GlobalShortcuts()
    private var menuBarItem: MenuBarItem?
    private(set) var shelf: ShelfController!
    private(set) var libraryWindow: LibraryWindowController?
    private var settingsWindow: SettingsController?
    private var pins: [PinnedImage] = []

    /// Shortcuts another app registered before us.
    private(set) var blockedShortcuts: Set<CaptureKind> = []
    private var appQuitObserver: NSObjectProtocol?

    private lazy var captureSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true)

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = prefs.appearance.nsAppearance
        NSApp.mainMenu = buildMainMenu()
        library.ensureDirectory()
        library.refresh()

        let commands = makeCommands()
        libraryModel.commands = commands
        libraryModel.onCapture = { [weak self] kind in self?.capture(kind) }
        libraryModel.onOpenSettings = { [weak self] in self?.openSettings() }
        libraryModel.onEditsSaved = { [weak self] url in
            self?.shelf.refreshPreview(for: url)
            self?.library.refresh()
        }
        shelf = ShelfController(commands: commands, prefs: prefs, previews: previews)

        menuBarItem = MenuBarItem(actions: MenuBarActions(
            capture: { [weak self] in self?.capture($0) },
            captureScreenLater: { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.capture(.screen) }
            },
            pinClipboard: { [weak self] in self?.pinClipboard() },
            openLibrary: { [weak self] in self?.openLibrary() },
            openSettings: { [weak self] in self?.openSettings() }
        ), prefs: prefs)

        registerShortcuts()
        NotificationCenter.default.addObserver(forName: .shortcutRecordingBegan, object: nil, queue: .main) { [weak self] _ in
            self?.shortcuts.unregisterAll()
        }
        NotificationCenter.default.addObserver(forName: .shortcutRecordingEnded, object: nil, queue: .main) { [weak self] _ in
            self?.registerShortcuts()
        }

        if DevTools.handleLaunchArguments(self) { return }

        // Used by scripts/install.sh: a login item has to be registered by the app itself.
        if CommandLine.arguments.contains("--enable-launch-at-login") {
            prefs.openAtLogin = true
            log("open at login: \(SMAppService.mainApp.status == .enabled ? "on" : "status \(SMAppService.mainApp.status.rawValue)")")
        }

        if !prefs.didShowWelcome {
            prefs.didShowWelcome = true
            openSettings(tab: .shortcuts)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openLibrary()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        libraryModel.closeSession()
        DragExport.cleanUp()
    }

    // MARK: - Shortcuts

    func registerShortcuts() {
        var bindings: [(id: UInt32, combo: KeyCombo, handler: () -> Void)] = []
        for (i, kind) in CaptureKind.allCases.enumerated() {
            guard let combo = prefs.shortcut(for: kind) else { continue }
            bindings.append((UInt32(i + 1), combo, { [weak self] in self?.capture(kind) }))
        }
        let failed = shortcuts.register(bindings)
        blockedShortcuts = Set(CaptureKind.allCases.enumerated().filter { failed[UInt32($0.offset + 1)] != nil }.map(\.element))
        let active = CaptureKind.allCases.filter { prefs.shortcut(for: $0) != nil && !blockedShortcuts.contains($0) }
        log("shortcuts active: \(active.compactMap { prefs.shortcut(for: $0)?.displayString }.joined(separator: " ")); blocked: \(blockedShortcuts.isEmpty ? "none" : blockedShortcuts.map(\.rawValue).sorted().joined(separator: ","))")
        // Try again as soon as some other app quits and frees its keys.
        if !blockedShortcuts.isEmpty, appQuitObserver == nil {
            appQuitObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.registerShortcuts() }
            }
        } else if blockedShortcuts.isEmpty, let observer = appQuitObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appQuitObserver = nil
        }
    }

    // MARK: - Capture

    func capture(_ kind: CaptureKind) {
        Task { @MainActor in
            do {
                let result: GrabResult?
                switch kind {
                case .area: result = try await grabber.pick(mode: .area)
                case .window: result = try await grabber.pick(mode: .window)
                case .screen: result = try await grabber.grabScreen()
                }
                if let result { didGrab(result) }
            } catch GrabError.permissionDenied {
                askForPermission()
            } catch {
                log("capture stopped: \(error)")
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Everything that happens once the pixels are in: save, clipboard, sound, shelf, editor.
    func didGrab(_ result: GrabResult) {
        let url: URL
        do {
            url = try library.saveCapture(result.image, scale: result.scale)
        } catch {
            log("capture not written to disk: \(error)")
            NSAlert(error: error).runModal()
            return
        }
        if prefs.copyAfterCapture { Clipboard.copy(image: result.image, scale: result.scale) }
        if prefs.captureSound { captureSound?.stop(); captureSound?.play() }
        if prefs.showShelf { shelf.show(url: url, pixelSize: CGSize(width: result.image.width, height: result.image.height)) }
        if prefs.editAfterCapture { openLibrary(opening: url) }
    }

    private func askForPermission() {
        NSApp.activate(ignoringOtherApps: true)
        ScreenGrabber.requestPermission()
        let alert = NSAlert()
        alert.messageText = "Allow \(AppIdentity.name) to see your screen"
        alert.informativeText = "Turn on \(AppIdentity.name) in System Settings › Privacy & Security › Screen Recording, then quit and reopen it."
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { ScreenGrabber.openScreenRecordingSettings() }
    }

    // MARK: - Commands on capture files

    private func makeCommands() -> CaptureCommands {
        CaptureCommands(
            edit: { [weak self] url in self?.openLibrary(opening: url) },
            copy: { [weak self] url in self?.copy(url) },
            export: { url in
                guard let doc = MarkupDocument.load(url: url), let image = doc.flattened() else { return }
                Exporter.save(image, scale: doc.scale, suggestedName: url.deletingPathExtension().lastPathComponent,
                              edited: doc.hasEdits) { _ in }
            },
            pin: { [weak self] url in self?.pin(url) },
            showInFinder: { url in NSWorkspace.shared.activateFileViewerSelecting([url]) },
            delete: { [weak self] url in self?.delete(url) }
        )
    }

    private func openDocument(_ url: URL) -> MarkupDocument? {
        if let session = libraryModel.session, session.document.url == url { return session.document }
        return MarkupDocument.load(url: url)
    }

    private func copy(_ url: URL) {
        guard let doc = openDocument(url), let image = doc.flattened() else { return }
        Clipboard.copy(image: image, scale: doc.scale)
    }

    func pin(_ url: URL) {
        guard let doc = openDocument(url), let image = doc.flattened() else { return }
        showPin(image, scale: doc.scale)
    }

    private func showPin(_ image: CGImage, scale: CGFloat) {
        let pin = PinnedImage(image: image, pointScale: scale)
        pin.onClose = { [weak self] p in self?.pins.removeAll { $0 === p } }
        pins.append(pin)
        pin.show()
    }

    private func pinClipboard() {
        guard let image = NSImage(pasteboard: NSPasteboard.general),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            NSSound.beep()
            return
        }
        let scale = image.size.width > 0 ? CGFloat(cg.width) / image.size.width : 1
        showPin(cg, scale: max(scale, 1))
    }

    private func delete(_ url: URL) {
        libraryModel.openNeighbor(of: url)
        shelf.remove(url)
        library.trash(url)
    }

    // MARK: - Windows

    func openLibrary(opening url: URL? = nil) {
        if libraryWindow == nil { libraryWindow = LibraryWindowController(model: libraryModel) }
        if let url, library.capture(for: url) == nil {
            library.refresh { [weak self] in self?.libraryWindow?.show(opening: url) }
        } else {
            libraryWindow?.show(opening: url)
        }
    }

    func openSettings(tab: SettingsTab? = nil) {
        if settingsWindow == nil {
            settingsWindow = SettingsController(
                prefs: prefs,
                onShortcutsChanged: { [weak self] in self?.registerShortcuts() },
                blockedShortcuts: { [weak self] in self?.blockedShortcuts ?? [] })
        }
        settingsWindow?.show(tab: tab)
    }

    /// Menu-bar apps have no visible menu bar, but ⌘W, ⌘Q and text editing still route through it.
    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(AppIdentity.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    @objc private func menuOpenSettings() { openSettings() }
}
