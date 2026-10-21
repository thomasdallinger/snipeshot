import AppKit
import Combine
import SwiftUI

/// What can be done with a capture file; implemented by the app delegate.
struct CaptureCommands {
    var edit: (URL) -> Void
    var copy: (URL) -> Void
    var export: (URL) -> Void
    var pin: (URL) -> Void
    var showInFinder: (URL) -> Void
    var delete: (URL) -> Void
}

final class ShelfItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    @Published var preview: NSImage?
    @Published var copied = false
    let aspect: CGFloat

    init(url: URL, pixelSize: CGSize) {
        self.url = url
        aspect = pixelSize.width > 0 ? pixelSize.height / pixelSize.width : 0.6
    }

    static let width: CGFloat = 200
    var height: CGFloat { min(max(Self.width * aspect, 72), 150) }
}

final class ShelfModel: ObservableObject {
    @Published var items: [ShelfItem] = []
}

/// Recent captures stacked in the bottom-left corner. Each card is a file you can drag anywhere.
final class ShelfController {
    private let commands: CaptureCommands
    private let prefs: Preferences
    private let previews: PreviewCache
    private let model = ShelfModel()
    private var panel: NSPanel?
    private var anchorFrame: CGRect?

    static let maxItems = 5
    private let margin: CGFloat = 16
    private let spacing: CGFloat = 10
    /// Room around the cards so their shadows are not clipped by the panel.
    private let shadowRoom: CGFloat = 18

    init(commands: CaptureCommands, prefs: Preferences, previews: PreviewCache) {
        self.commands = commands
        self.prefs = prefs
        self.previews = previews
    }

    var itemURLs: [URL] { model.items.map(\.url) }
    var debugPanel: NSPanel? { panel }

    func show(url: URL, pixelSize: CGSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        if model.items.isEmpty || anchorFrame != screen.visibleFrame { anchorFrame = screen.visibleFrame }
        let item = ShelfItem(url: url, pixelSize: pixelSize)
        previews.preview(for: url, modDate: Date()) { [weak item] in item?.preview = $0 }
        withAnimation(Motion.standard) {
            model.items.append(item)
            if model.items.count > Self.maxItems { model.items.removeFirst(model.items.count - Self.maxItems) }
        }
        ensurePanel()
        layoutPanel()
        panel?.orderFrontRegardless()
    }

    func remove(_ url: URL) {
        withAnimation(Motion.standard) { model.items.removeAll { $0.url == url } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.layoutPanel() }
    }

    func refreshPreview(for url: URL) {
        for item in model.items where item.url == url {
            previews.preview(for: url, modDate: Date()) { [weak item] in item?.preview = $0 }
        }
    }

    private func markCopied(_ url: URL) {
        for item in model.items where item.url == url {
            item.copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak item] in item?.copied = false }
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isMovable = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        let actions = ShelfCard.Actions(
            edit: { [weak self] url in self?.remove(url); self?.commands.edit(url) },
            copy: { [weak self] url in self?.commands.copy(url); self?.markCopied(url) },
            pin: { [weak self] url in self?.remove(url); self?.commands.pin(url) },
            showInFinder: { [weak self] url in self?.commands.showInFinder(url) },
            delete: { [weak self] url in self?.remove(url); self?.commands.delete(url) },
            close: { [weak self] url in self?.remove(url) },
            dragEnded: { [weak self] url, dropped in
                if dropped, self?.prefs.closeShelfItemAfterDrag ?? true { self?.remove(url) }
            }
        )
        p.contentView = FirstMouseHostingView(rootView: ShelfView(model: model, actions: actions))
        panel = p
    }

    private func layoutPanel() {
        guard let panel else { return }
        if model.items.isEmpty {
            panel.orderOut(nil)
            return
        }
        let screen = anchorFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let content = model.items.map(\.height).reduce(0, +) + spacing * CGFloat(model.items.count - 1)
        let height = min(content + shadowRoom * 2, screen.height - margin)
        let frame = CGRect(x: screen.minX + margin - shadowRoom, y: screen.minY + margin - shadowRoom,
                           width: ShelfItem.width + shadowRoom * 2, height: height)
        panel.setFrame(frame, display: true)
    }
}

enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// 160 ms ease-out, or nothing when Reduce motion is on.
    static var standard: Animation? { reduce ? nil : .easeOut(duration: 0.16) }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    let actions: ShelfCard.Actions

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            ForEach(model.items) { item in
                ShelfCard(item: item, actions: actions)
                    .transition(Motion.reduce ? .identity : .move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

struct ShelfCard: View {
    struct Actions {
        var edit: (URL) -> Void
        var copy: (URL) -> Void
        var pin: (URL) -> Void
        var showInFinder: (URL) -> Void
        var delete: (URL) -> Void
        var close: (URL) -> Void
        var dragEnded: (URL, Bool) -> Void
    }

    @ObservedObject var item: ShelfItem
    let actions: Actions
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let preview = item.preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(nsColor: .windowBackgroundColor)
                }
            }
            .frame(width: ShelfItem.width, height: item.height)
            .clipped()

            // The card itself is the drag handle; a click opens the editor.
            FileDragSource(url: item.url, preview: item.preview,
                           onClick: { actions.edit(item.url) },
                           onHover: { h in withAnimation(Motion.standard) { hovering = h } },
                           onDragEnded: { dropped in actions.dragEnded(item.url, dropped) })

            if item.copied {
                ZStack {
                    Color.black.opacity(0.45)
                    Label("Copied", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .allowsHitTesting(false)
            } else if hovering {
                actionBar
            }
        }
        .frame(width: ShelfItem.width, height: item.height)
        .overlay(alignment: .topLeading) {
            if hovering && !item.copied {
                ShelfIconButton(symbol: "xmark", help: "Close", onImage: true) { actions.close(item.url) }
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.black.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .help("Drag to share, click to edit")
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            ShelfIconButton(symbol: "doc.on.doc", help: "Copy") { actions.copy(item.url) }
            ShelfIconButton(symbol: "pencil", help: "Edit") { actions.edit(item.url) }
            ShelfIconButton(symbol: "pin", help: "Pin to Screen") { actions.pin(item.url) }
            ShelfIconButton(symbol: "folder", help: "Show in Finder") { actions.showInFinder(item.url) }
            Spacer(minLength: 0)
            ShelfIconButton(symbol: "trash", help: "Move to Trash") { actions.delete(item.url) }
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
        .background(Color.black.opacity(0.62))
    }
}

struct ShelfIconButton: View {
    let symbol: String
    let help: String
    /// Sits directly on the screenshot, so it needs its own dark plate to stay visible.
    var onImage = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(onImage ? Color.black.opacity(hovering ? 0.75 : 0.6) : Color.white.opacity(hovering ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}
