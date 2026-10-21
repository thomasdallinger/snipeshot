import AppKit

struct MenuBarActions {
    var capture: (CaptureKind) -> Void
    var captureScreenLater: () -> Void
    var pinClipboard: () -> Void
    var openLibrary: () -> Void
    var openSettings: () -> Void
}

/// The menu bar icon and its menu. Key hints follow the configured shortcuts.
final class MenuBarItem: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let actions: MenuBarActions
    private let prefs: Preferences
    private var captureItems: [CaptureKind: NSMenuItem] = [:]

    init(actions: MenuBarActions, prefs: Preferences) {
        self.actions = actions
        self.prefs = prefs
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "scope", accessibilityDescription: AppIdentity.name)
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        for kind in CaptureKind.allCases {
            let item = NSMenuItem(title: kind.menuTitle, action: #selector(captureChosen(_:)), keyEquivalent: "")
            item.representedObject = kind.rawValue
            item.target = self
            menu.addItem(item)
            captureItems[kind] = item
        }
        menu.addItem(item("Capture Screen in 5 Seconds", #selector(captureScreenLater)))
        menu.addItem(.separator())
        menu.addItem(item("Open Library", #selector(openLibrary), key: "l"))
        menu.addItem(item("Pin Clipboard Image", #selector(pinClipboard)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("About \(AppIdentity.name)", #selector(showAbout)))
        menu.addItem(item("Quit \(AppIdentity.name)", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        for (kind, item) in captureItems {
            if let combo = prefs.shortcut(for: kind), let key = combo.menuKeyEquivalent {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = combo.menuModifierMask
            } else {
                item.keyEquivalent = ""
            }
        }
    }

    @objc private func captureChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = CaptureKind(rawValue: raw) else { return }
        // Give the menu time to close before the screen freezes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.actions.capture(kind) }
    }

    @objc private func captureScreenLater() { actions.captureScreenLater() }
    @objc private func pinClipboard() { actions.pinClipboard() }
    @objc private func openLibrary() { actions.openLibrary() }
    @objc private func openSettings() { actions.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Capture, mark up and drag screenshots anywhere."),
        ])
    }
}
