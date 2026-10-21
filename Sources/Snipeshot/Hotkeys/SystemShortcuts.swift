import AppKit

/// Reads and edits the macOS screenshot shortcuts in `com.apple.symbolichotkeys`.
/// While a system shortcut is enabled, macOS consumes the key combo before any app hotkey sees it,
/// so taking over ⌘⇧3/4/5 means switching the matching system entries off.
enum SystemShortcuts {
    struct Entry: Identifiable {
        let id: Int
        let title: String
        let keyCode: Int
        let modifierMask: Int
        let enabled: Bool

        func matches(_ hotkey: KeyCombo) -> Bool {
            keyCode == Int(hotkey.keyCode) && modifierMask == hotkey.cocoaModifierMask
        }
    }

    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString
    private static let shiftCmd = 1_179_648
    private static let ctrlShiftCmd = 1_441_792

    /// Screenshot-related symbolic hotkey ids with their factory bindings: (id, title, ascii, keyCode, modifiers).
    private static let known: [(Int, String, Int, Int, Int)] = [
        (28, "Whole screen to file", 51, 20, shiftCmd),
        (29, "Whole screen to clipboard", 51, 20, ctrlShiftCmd),
        (30, "Selected area to file", 52, 21, shiftCmd),
        (31, "Selected area to clipboard", 52, 21, ctrlShiftCmd),
        (184, "Screenshot toolbar", 53, 23, shiftCmd),
    ]

    private static func readAll() -> [String: Any] {
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]) ?? [:]
    }

    static func current() -> [Entry] {
        let all = readAll()
        return known.map { id, title, _, defKey, defMods in
            guard let entry = all[String(id)] as? [String: Any] else {
                return Entry(id: id, title: title, keyCode: defKey, modifierMask: defMods, enabled: true)
            }
            let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? true
            let params = ((entry["value"] as? [String: Any])?["parameters"] as? [NSNumber])?.map(\.intValue) ?? []
            let keyCode = params.count > 1 ? params[1] : defKey
            let mods = params.count > 2 ? params[2] : defMods
            return Entry(id: id, title: title, keyCode: keyCode, modifierMask: mods, enabled: enabled)
        }
    }

    /// Enabled system shortcuts that would swallow the given hotkey.
    static func conflicts(with hotkey: KeyCombo?) -> [Entry] {
        guard let hotkey else { return [] }
        return current().filter { $0.enabled && $0.matches(hotkey) }
    }

    /// Switches the given system shortcut ids off and asks macOS to reload them. Returns success.
    @discardableResult
    static func disable(ids: [Int]) -> Bool {
        guard !ids.isEmpty else { return true }
        var all = readAll()
        for id in ids {
            guard let def = known.first(where: { $0.0 == id }) else { continue }
            var entry = (all[String(id)] as? [String: Any]) ?? [
                "value": ["parameters": [def.2, def.3, def.4], "type": "standard"] as [String: Any],
            ]
            entry["enabled"] = false
            all[String(id)] = entry
        }
        CFPreferencesSetValue(key, all as CFDictionary, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return false }
        reloadSystemShortcuts()
        return current().filter { ids.contains($0.id) }.allSatisfy { !$0.enabled }
    }

    /// Without this, macOS keeps the old bindings until next login.
    private static func reloadSystemShortcuts() {
        let tool = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-u"]
        try? p.run()
        p.waitUntilExit()
    }

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
