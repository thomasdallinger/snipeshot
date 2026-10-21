import AppKit
import Combine
import SwiftUI

enum SettingsTab: String, Hashable {
    case general, shortcuts, saving
}

final class SettingsModel: ObservableObject {
    @Published var tab: SettingsTab = .shortcuts
    /// Bumped to re-read state that changes outside the app (permission, system shortcuts).
    @Published var tick = 0
}

final class SettingsController: NSWindowController, NSWindowDelegate {
    let model = SettingsModel()
    private var timer: Timer?

    init(prefs: Preferences, onShortcutsChanged: @escaping () -> Void, blockedShortcuts: @escaping () -> Set<CaptureKind>) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(AppIdentity.name) Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: SettingsTabs(prefs: prefs, model: model,
                                                                      onShortcutsChanged: onShortcutsChanged,
                                                                      blockedShortcuts: blockedShortcuts))
        window.center()
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(tab: SettingsTab? = nil) {
        if let tab { model.tab = tab }
        model.tick += 1
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.model.tick += 1 }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}

struct SettingsTabs: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: SettingsModel
    let onShortcutsChanged: () -> Void
    let blockedShortcuts: () -> Set<CaptureKind>

    var body: some View {
        TabView(selection: $model.tab) {
            GeneralTab(prefs: prefs)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ShortcutsTab(prefs: prefs, model: model, onShortcutsChanged: onShortcutsChanged, blockedShortcuts: blockedShortcuts)
                .tabItem { Label("Shortcuts", systemImage: "command") }
                .tag(SettingsTab.shortcuts)
            SavingTab(prefs: prefs)
                .tabItem { Label("Saving", systemImage: "folder") }
                .tag(SettingsTab.saving)
        }
        .frame(width: 520, height: 460)
    }
}

/// A single problem line with one way to fix it.
struct NoticeRow: View {
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(Color(nsColor: .systemOrange)).frame(width: 7, height: 7)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(button, action: action)
        }
    }
}

struct GeneralTab: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $prefs.openAtLogin)
                Picker("Appearance", selection: $prefs.appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("After a capture") {
                Toggle("Show it in the corner of the screen", isOn: $prefs.showShelf)
                Toggle("Put it on the clipboard", isOn: $prefs.copyAfterCapture)
                Toggle("Open it in the editor", isOn: $prefs.editAfterCapture)
                Toggle("Play a sound", isOn: $prefs.captureSound)
                Toggle("Remove the card once it has been dragged out", isOn: $prefs.closeShelfItemAfterDrag)
            }
        }
        .formStyle(.grouped)
    }
}

struct SavingTab: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text(prefs.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Change…") { chooseFolder() }
                    }
                }
                Picker("Format", selection: $prefs.fileFormat) {
                    ForEach(FileFormat.allCases) { Text($0.title).tag($0) }
                }
                if prefs.fileFormat == .jpeg {
                    LabeledContent("Quality") {
                        Slider(value: $prefs.jpegQuality, in: 0.5...1)
                    }
                }
            } footer: {
                Text("Originals are never changed. Edits are kept in a small hidden file next to each capture.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Show Folder in Finder") { NSWorkspace.shared.open(prefs.saveFolder) }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.saveFolder
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { prefs.saveFolder = url }
    }
}

struct ShortcutsTab: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: SettingsModel
    let onShortcutsChanged: () -> Void
    let blockedShortcuts: () -> Set<CaptureKind>
    @State private var takeoverFailed = false

    var body: some View {
        let _ = model.tick
        let systemConflicts = CaptureKind.allCases.flatMap { SystemShortcuts.conflicts(with: prefs.shortcut(for: $0)) }
        let blocked = blockedShortcuts()
        Form {
            if !ScreenGrabber.hasPermission {
                Section {
                    NoticeRow(text: "\(AppIdentity.name) can’t see your screen yet. Allow it under Screen Recording, then reopen the app.",
                              button: "Open Privacy Settings") {
                        ScreenGrabber.requestPermission()
                        ScreenGrabber.openScreenRecordingSettings()
                    }
                }
            }
            if !systemConflicts.isEmpty {
                Section {
                    NoticeRow(text: "macOS still answers \(systemConflicts.count == 1 ? "one of these keys" : "\(systemConflicts.count) of these keys") with its own screenshot tool.",
                              button: "Turn Off in macOS") {
                        takeoverFailed = !SystemShortcuts.disable(ids: systemConflicts.map(\.id))
                        onShortcutsChanged()
                        model.tick += 1
                    }
                    if takeoverFailed {
                        HStack {
                            Text("That didn’t work here. Turn them off under Keyboard Shortcuts, Screenshots.")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Keyboard Settings…") { SystemShortcuts.openKeyboardSettings() }
                        }
                    }
                }
            }
            if !blocked.isEmpty {
                Section {
                    Text("Another app registered \(blocked.compactMap { prefs.shortcut(for: $0)?.displayString }.sorted().joined(separator: ", ")) first. Quit it or choose different keys. \(AppIdentity.name) tries again whenever an app quits.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                ForEach(CaptureKind.allCases) { kind in
                    LabeledContent(kind.title) {
                        ShortcutRecorder(combo: Binding(
                            get: { prefs.shortcut(for: kind) },
                            set: { prefs.setShortcut($0, for: kind); onShortcutsChanged() }
                        ))
                    }
                }
            } footer: {
                HStack(alignment: .top) {
                    Text("Click a shortcut and type the new keys. Delete clears it. If another screenshot app uses the same keys, both will react, so quit it or pick different keys.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Use Defaults") {
                        prefs.resetShortcuts()
                        onShortcutsChanged()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then type a key combination. Global shortcuts pause while recording.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(isRecording ? "Type shortcut" : (combo?.displayString ?? "None"))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 96)
                .foregroundStyle(isRecording ? Color.accentColor : (combo == nil ? .secondary : .primary))
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        NotificationCenter.default.post(name: .shortcutRecordingBegan, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: // Esc keeps the old value
                stop()
            case 51, 117: // Delete clears it
                combo = nil
                stop()
            default:
                if let c = KeyCombo(event: event) {
                    combo = c
                    stop()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.post(name: .shortcutRecordingEnded, object: nil)
    }
}
