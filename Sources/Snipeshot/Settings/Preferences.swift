import AppKit
import Combine
import ServiceManagement

enum FileFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var title: String { self == .png ? "PNG" : "JPEG" }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { self == .system ? "Match system" : rawValue.capitalized }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum CaptureKind: String, CaseIterable, Identifiable {
    case area, window, screen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .area: return "Area"
        case .window: return "Window"
        case .screen: return "Whole screen"
        }
    }
    var menuTitle: String {
        switch self {
        case .area: return "Capture Area"
        case .window: return "Capture Window"
        case .screen: return "Capture Screen"
        }
    }
    var symbol: String {
        switch self {
        case .area: return "rectangle.dashed"
        case .window: return "macwindow"
        case .screen: return "display"
        }
    }
}

/// Preferences backed by UserDefaults. Every value publishes so SwiftUI and AppKit stay in sync.
final class Preferences: ObservableObject {
    private let defaults: UserDefaults

    private enum Key {
        static let saveFolder = "saveFolder", fileFormat = "fileFormat", jpegQuality = "jpegQuality"
        static let showShelf = "showShelf", copyAfterCapture = "copyAfterCapture", editAfterCapture = "editAfterCapture"
        static let captureSound = "captureSound", closeShelfItemAfterDrag = "closeShelfItemAfterDrag"
        static let appearance = "appearance", didShowWelcome = "didShowWelcome"
        static func shortcut(_ kind: CaptureKind) -> String { "shortcut.\(kind.rawValue)" }
    }

    @Published var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: Key.saveFolder) } }
    @Published var fileFormat: FileFormat { didSet { defaults.set(fileFormat.rawValue, forKey: Key.fileFormat) } }
    @Published var jpegQuality: Double { didSet { defaults.set(jpegQuality, forKey: Key.jpegQuality) } }
    @Published var showShelf: Bool { didSet { defaults.set(showShelf, forKey: Key.showShelf) } }
    @Published var copyAfterCapture: Bool { didSet { defaults.set(copyAfterCapture, forKey: Key.copyAfterCapture) } }
    @Published var editAfterCapture: Bool { didSet { defaults.set(editAfterCapture, forKey: Key.editAfterCapture) } }
    @Published var captureSound: Bool { didSet { defaults.set(captureSound, forKey: Key.captureSound) } }
    @Published var closeShelfItemAfterDrag: Bool { didSet { defaults.set(closeShelfItemAfterDrag, forKey: Key.closeShelfItemAfterDrag) } }
    @Published var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            NSApp.appearance = appearance.nsAppearance
        }
    }
    @Published private(set) var shortcuts: [CaptureKind: KeyCombo] = [:]
    @Published var didShowWelcome: Bool { didSet { defaults.set(didShowWelcome, forKey: Key.didShowWelcome) } }

    /// Login items belong to ServiceManagement, not UserDefaults.
    @Published var openAtLogin: Bool {
        didSet {
            guard openAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                log("could not change the login item: \(error)")
            }
        }
    }

    static var defaultSaveFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.folderName, isDirectory: true)
    }

    static let defaultShortcuts: [CaptureKind: KeyCombo] = [.area: .area, .window: .window, .screen: .screen]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        saveFolder = defaults.string(forKey: Key.saveFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Preferences.defaultSaveFolder
        fileFormat = FileFormat(rawValue: defaults.string(forKey: Key.fileFormat) ?? "") ?? .png
        jpegQuality = defaults.object(forKey: Key.jpegQuality) as? Double ?? 0.9
        showShelf = defaults.object(forKey: Key.showShelf) as? Bool ?? true
        copyAfterCapture = defaults.object(forKey: Key.copyAfterCapture) as? Bool ?? true
        editAfterCapture = defaults.object(forKey: Key.editAfterCapture) as? Bool ?? false
        captureSound = defaults.object(forKey: Key.captureSound) as? Bool ?? true
        closeShelfItemAfterDrag = defaults.object(forKey: Key.closeShelfItemAfterDrag) as? Bool ?? true
        appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        didShowWelcome = defaults.bool(forKey: Key.didShowWelcome)
        openAtLogin = SMAppService.mainApp.status == .enabled
        for kind in CaptureKind.allCases {
            if let combo = Self.loadShortcut(defaults, Key.shortcut(kind), fallback: Self.defaultShortcuts[kind]!) {
                shortcuts[kind] = combo
            }
        }
    }

    func shortcut(for kind: CaptureKind) -> KeyCombo? { shortcuts[kind] }

    func setShortcut(_ combo: KeyCombo?, for kind: CaptureKind) {
        shortcuts[kind] = combo
        // Empty data marks "cleared on purpose" so the default does not come back.
        defaults.set(combo.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: Key.shortcut(kind))
    }

    func resetShortcuts() {
        for kind in CaptureKind.allCases { setShortcut(Self.defaultShortcuts[kind], for: kind) }
    }

    private static func loadShortcut(_ defaults: UserDefaults, _ key: String, fallback: KeyCombo) -> KeyCombo? {
        guard let data = defaults.data(forKey: key) else { return fallback }
        if data.isEmpty { return nil }
        return (try? JSONDecoder().decode(KeyCombo.self, from: data)) ?? fallback
    }
}
