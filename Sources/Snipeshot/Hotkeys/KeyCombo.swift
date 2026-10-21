import AppKit
import Carbon.HIToolbox

/// A global shortcut expressed in Carbon terms (what RegisterEventHotKey needs).
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let area = KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey))
    static let screen = KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey))
    static let window = KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        // A global shortcut without ⌘, ⌃ or ⌥ would swallow normal typing.
        guard mods & UInt32(cmdKey | controlKey | optionKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    /// Modifier mask in NSEvent terms, the format `com.apple.symbolichotkeys` uses.
    var cocoaModifierMask: Int {
        var m = 0
        if modifiers & UInt32(shiftKey) != 0 { m |= Int(NSEvent.ModifierFlags.shift.rawValue) }
        if modifiers & UInt32(controlKey) != 0 { m |= Int(NSEvent.ModifierFlags.control.rawValue) }
        if modifiers & UInt32(optionKey) != 0 { m |= Int(NSEvent.ModifierFlags.option.rawValue) }
        if modifiers & UInt32(cmdKey) != 0 { m |= Int(NSEvent.ModifierFlags.command.rawValue) }
        return m
    }

    var modifierSymbols: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    var keyName: String { KeyCombo.keyNames[Int(keyCode)] ?? "Key \(keyCode)" }

    var displayString: String { modifierSymbols + keyName }

    /// Key equivalent for NSMenuItem, when the key maps to a single character.
    var menuKeyEquivalent: String? {
        let name = keyName
        return name.count == 1 ? name.lowercased() : nil
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(cocoaModifierMask))
    }

    private static let keyNames: [Int: String] = {
        var m: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
        for (i, k) in fKeys.enumerated() { m[k] = "F\(i + 1)" }
        return m
    }()
}
