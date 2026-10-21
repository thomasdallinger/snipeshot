import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The library window: captures on the left, the editor on the right.
final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    private let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = AppIdentity.name
        window.minSize = CGSize(width: 860, height: 520)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("LibraryWindow")
        window.contentView = NSHostingView(rootView: LibraryRootView(model: model))
        if window.frame.origin == .zero { window.center() }
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(opening url: URL? = nil) {
        if let url { model.open(url) }
        else if model.openURL == nil, let first = model.library.captures.first { model.open(first.url) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.closeSession()
    }
}

struct LibraryRootView: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        HStack(spacing: 0) {
            if model.showSidebar {
                CaptureSidebar(model: model)
                    .frame(width: 244)
                    .transition(.move(edge: .leading))
                Divider()
            }
            Group {
                if let session = model.session {
                    EditorPane(session: session, showInspector: $model.showInspector)
                        .id(session.document.url)
                } else {
                    VStack(spacing: 0) {
                        HStack { Spacer() }.frame(height: 52).background(WindowDragArea()).background(Color(nsColor: .windowBackgroundColor))
                        Divider()
                        NoCaptureView(model: model)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if !model.showSidebar {
                    // Traffic lights sit here when the sidebar is hidden.
                    HeaderIconButton(symbol: "sidebar.left", help: "Show Sidebar") {
                        withAnimation(.easeOut(duration: 0.15)) { model.showSidebar = true }
                    }
                    .padding(.leading, 78)
                    .padding(.top, 12)
                }
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 860, minHeight: 520)
    }
}

// MARK: - Sidebar

struct CaptureSidebar: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var library: CaptureLibrary
    @State private var isDropTarget = false

    init(model: LibraryModel) {
        self.model = model
        self.library = model.library
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Spacer()
                ForEach(CaptureKind.allCases) { kind in
                    HeaderIconButton(symbol: kind.symbol, help: captureHelp(kind)) { model.onCapture?(kind) }
                }
                HeaderIconButton(symbol: "sidebar.left", help: "Hide Sidebar") {
                    withAnimation(.easeOut(duration: 0.15)) { model.showSidebar = false }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 52)
            .background(WindowDragArea())

            if library.captures.isEmpty {
                VStack(spacing: 6) {
                    Text("No captures yet").font(.system(size: 13, weight: .semibold))
                    Text("Drop images here to add them.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CaptureList(model: model, library: library)
            }

            Divider()
            HStack(spacing: 2) {
                HeaderIconButton(symbol: "plus", help: "Add Images…") { addImages() }
                HeaderIconButton(symbol: "folder", help: "Show Capture Folder") { NSWorkspace.shared.open(library.directory) }
                Spacer()
                HeaderIconButton(symbol: "gearshape", help: "Settings  ⌘,") { model.onOpenSettings?() }
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
        }
        .background(VisualEffectBackground(material: .sidebar))
        .overlay(RoundedRectangle(cornerRadius: 0).strokeBorder(Color.accentColor, lineWidth: 2).opacity(isDropTarget ? 1 : 0))
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            loadURLs(providers) { urls in
                let added = library.importFiles(urls)
                if let first = added.first { library.refresh { model.open(first) } }
            }
            return true
        }
    }

    private func captureHelp(_ kind: CaptureKind) -> String {
        guard let combo = model.prefs.shortcut(for: kind) else { return kind.menuTitle }
        return "\(kind.menuTitle)  \(combo.displayString)"
    }

    private func addImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let added = library.importFiles(panel.urls)
        if let first = added.first { library.refresh { model.open(first) } }
    }

    private func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}

/// Captures grouped by day, newest first.
struct CaptureList: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var library: CaptureLibrary

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups(now: context.date), id: \.title) { group in
                            Section {
                                ForEach(group.items) { capture in
                                    CaptureRow(capture: capture, isOpen: model.openURL == capture.url,
                                               previews: model.previews, commands: model.commands) {
                                        model.open(capture.url)
                                    }
                                    .id(capture.url)
                                }
                            } header: {
                                Text(group.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 14)
                                    .padding(.bottom, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(VisualEffectBackground(material: .sidebar))
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .onChange(of: model.openURL) { _, url in
                if let url { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(url) } }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { model.openAdjacent(-1); return .handled }
        .onKeyPress(.downArrow) { model.openAdjacent(1); return .handled }
        .onDeleteCommand {
            if let url = model.openURL { model.commands.delete(url) }
        }
    }

    private struct DayGroup {
        let title: String
        let items: [CaptureFile]
    }

    private func groups(now: Date) -> [DayGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [CaptureFile]] = [:]
        for capture in library.captures {
            let day = calendar.startOfDay(for: capture.createdAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(capture)
        }
        return order.map { DayGroup(title: Self.dayTitle($0, now: now, calendar: calendar), items: buckets[$0] ?? []) }
    }

    static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = calendar.isDate(day, equalTo: now, toGranularity: .year) ? "EEEE d MMMM" : "d MMMM yyyy"
        return f.string(from: day)
    }
}

struct CaptureRow: View {
    let capture: CaptureFile
    let isOpen: Bool
    let previews: PreviewCache
    let commands: CaptureCommands
    let onOpen: () -> Void
    @State private var preview: NSImage?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Group {
                    if let preview {
                        Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.primary.opacity(0.06)
                    }
                }
                .frame(width: 64, height: 44)
                .clipped()
                FileDragSource(url: capture.url, preview: preview, onClick: onOpen, onHover: { hovering = $0 }, onDragEnded: { _ in })
            }
            .frame(width: 64, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.time(capture.createdAt))
                    .font(.system(size: 13))
                    .foregroundStyle(isOpen ? Color.white : Color.primary)
                Text("\(Int(capture.pixelSize.width)) × \(Int(capture.pixelSize.height))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(isOpen ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer(minLength: 0)
            if capture.hasEdits {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isOpen ? Color.white.opacity(0.8) : Color.secondary)
                    .help("Edited")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isOpen ? Color.accentColor : Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { commands.copy(capture.url) }
            Button("Export…") { commands.export(capture.url) }
            Button("Pin to Screen") { commands.pin(capture.url) }
            Button("Show in Finder") { commands.showInFinder(capture.url) }
            Divider()
            Button("Move to Trash") { commands.delete(capture.url) }
        }
        .onAppear(perform: load)
        .onChange(of: capture.modDate) { _, _ in load() }
        .help(capture.name)
    }

    private func load() {
        if let cached = previews.cached(capture.url, modDate: capture.modDate) {
            preview = cached
            return
        }
        previews.preview(for: capture.url, modDate: capture.modDate, maxPixel: 240) { preview = $0 }
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

struct NoCaptureView: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        ZStack {
            Color.canvasBackdrop
            VStack(spacing: 10) {
                Text(model.library.captures.isEmpty ? "Nothing captured yet" : "Choose a capture")
                    .font(.system(size: 15, weight: .semibold))
                if let combo = model.prefs.shortcut(for: .area) {
                    HStack(spacing: 6) {
                        Text("Press").foregroundStyle(.secondary)
                        Keycap(text: combo.displayString)
                        Text("to capture an area.").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))
                }
            }
        }
    }
}

struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
    }
}

/// System material for the sidebar, like Finder or Mail.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
