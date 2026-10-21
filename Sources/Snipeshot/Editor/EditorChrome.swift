import AppKit
import SwiftUI

// MARK: - Canvas hosting

/// Keeps the canvas centered while it is smaller than the viewport.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

final class CanvasScrollView: NSScrollView {
    var onInitialLayout: (() -> Void)?
    private var hasLaidOut = false

    override func layout() {
        super.layout()
        if !hasLaidOut, bounds.width > 0 {
            hasLaidOut = true
            DispatchQueue.main.async { self.onInitialLayout?() }
        }
    }
}

struct CanvasHost: NSViewRepresentable {
    let session: EditSession

    func makeNSView(context: Context) -> CanvasScrollView {
        let scroll = CanvasScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 8
        scroll.drawsBackground = false

        let canvas = CanvasView(session: session)
        scroll.documentView = canvas
        session.canvas = canvas
        session.scrollView = scroll

        scroll.onInitialLayout = { [weak session] in
            session?.zoomToFit()
            session?.focusCanvas()
        }
        NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll, queue: .main) { [weak session, weak scroll] _ in
            guard let scroll else { return }
            session?.zoomPercent = Int((scroll.magnification * 100).rounded())
        }
        return scroll
    }

    func updateNSView(_ nsView: CanvasScrollView, context: Context) {}
}

extension Color {
    /// Neutral area behind the image, a step darker than the window.
    static let canvasBackdrop = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.102, green: 0.102, blue: 0.11, alpha: 1)
            : NSColor(srgbRed: 0.91, green: 0.91, blue: 0.918, alpha: 1)
    })
}

/// Lets an empty area inside the title bar drag (and double-click zoom) the window like a real title bar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Editor pane

/// Header, canvas, inspector and status bar for one capture.
struct EditorPane: View {
    @ObservedObject var session: EditSession
    @Binding var showInspector: Bool

    var body: some View {
        VStack(spacing: 0) {
            EditorHeader(session: session, showInspector: $showInspector)
            Divider()
            HStack(spacing: 0) {
                ZStack {
                    Color.canvasBackdrop
                    CanvasHost(session: session)
                        .id(session.document.url)
                }
                if showInspector {
                    Divider()
                    Inspector(session: session)
                        .frame(width: 272)
                        .transition(.move(edge: .trailing))
                }
            }
            Divider()
            EditorStatusBar(session: session)
        }
    }
}

// MARK: - Header

struct EditorHeader: View {
    @ObservedObject var session: EditSession
    @Binding var showInspector: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Tool.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { HeaderDivider() }
                ForEach(group) { tool in
                    ToolButton(tool: tool, isActive: session.tools.tool == tool) { session.selectTool(tool) }
                }
            }
            Spacer(minLength: 12)
            HeaderIconButton(symbol: "arrow.uturn.backward", help: "Undo  ⌘Z") { session.undo() }
                .disabled(!session.document.canUndo)
            HeaderIconButton(symbol: "arrow.uturn.forward", help: "Redo  ⇧⌘Z") { session.redo() }
                .disabled(!session.document.canRedo)
            HeaderDivider()
            Menu {
                Button("Export…") { session.export() }
                Button("Pin to Screen") { session.pin() }
                Button("Show in Finder") { session.revealInFinder() }
                if session.document.crop != nil {
                    Divider()
                    Button("Remove Crop") { session.removeCrop() }
                }
                Divider()
                Button("Move to Trash") { session.delete() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 30, height: 28)
            .help("More")
            Button("Copy") { session.copyToClipboard() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .help("Copy the edited image  ⌘C")
                .padding(.leading, 4)
            HeaderIconButton(symbol: "sidebar.right", help: showInspector ? "Hide Inspector" : "Show Inspector", isActive: showInspector) {
                withAnimation(.easeOut(duration: 0.15)) { showInspector.toggle() }
            }
            .padding(.leading, 4)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(WindowDragArea())
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct HeaderDivider: View {
    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 18).padding(.horizontal, 6)
    }
}

/// Flat square button; the active state is a neutral fill, not the accent colour.
struct ChromeButtonStyle: ButtonStyle {
    var isActive = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(nsColor: isActive ? .labelColor : .secondaryLabelColor))
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: isActive || configuration.isPressed ? .quaternaryLabelColor : (hovering ? .quinaryLabel : .clear)))
            )
            .onHover { hovering = $0 }
    }
}

struct ToolButton: View {
    let tool: Tool
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 14))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChromeButtonStyle(isActive: isActive))
        .help("\(tool.title)  \(String(tool.key).uppercased())")
        .accessibilityLabel(tool.title)
    }
}

struct HeaderIconButton: View {
    let symbol: String
    let help: String
    var isActive = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(ChromeButtonStyle(isActive: isActive))
        .help(help)
    }
}

// MARK: - Inspector

struct Inspector: View {
    @ObservedObject var session: EditSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if session.tools.isCropping {
                    CropSection(session: session)
                } else if let type = session.styleTarget {
                    StyleSection(session: session, type: type)
                } else {
                    Text("Pick a tool, or select something on the canvas to change its style.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let selected = session.document.selectedItem, !session.tools.isCropping {
                    ArrangeSection(session: session, id: selected.id)
                }
                if !session.tools.isCropping {
                    BackdropSection(session: session)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct InspectorSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                accessory()
            }
            content()
        }
    }
}

struct InspectorRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            content()
        }
    }
}

struct StyleSection: View {
    @ObservedObject var session: EditSession
    let type: AnnotationType

    var body: some View {
        InspectorSection(session.document.selectedItem == nil ? "New \(type.displayName.lowercased())" : type.displayName) {
            if type != .redaction {
                SwatchRow(selection: session.currentColor) { session.setColor($0) }
            }
            if type.usesStroke {
                InspectorRow(label: "Stroke") {
                    Picker("Stroke", selection: Binding(get: { StrokePreset.nearest(to: session.currentStroke) },
                                                        set: { session.setStroke($0.rawValue) })) {
                        ForEach(StrokePreset.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 132)
                }
            }
            if type.canFill {
                InspectorRow(label: "Fill") {
                    Toggle("Fill", isOn: Binding(get: { session.currentFilled }, set: { session.setFilled($0) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
            }
            if type.usesTextSize {
                InspectorRow(label: "Size") {
                    Picker("Size", selection: Binding(get: { TextSizePreset.nearest(to: session.currentTextSize) },
                                                      set: { session.setTextSize($0.rawValue) })) {
                        ForEach(TextSizePreset.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 100)
                }
            }
            if type == .redaction {
                Picker("Style", selection: Binding(get: { session.currentRedaction }, set: { session.setRedaction($0) })) {
                    ForEach(Redaction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

struct SwatchRow: View {
    let selection: RGBA
    let onPick: (RGBA) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(RGBA.palette, id: \.name) { item in
                Button { onPick(item.color) } label: {
                    Circle()
                        .fill(Color(nsColor: item.color.nsColor))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                        .frame(width: 17, height: 17)
                        .padding(2)
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: 1.5).opacity(item.color == selection ? 1 : 0))
                }
                .buttonStyle(.plain)
                .help(item.name)
                .accessibilityLabel(item.name)
            }
            ColorPicker("Custom colour", selection: Binding(
                get: { Color(nsColor: selection.nsColor) },
                set: { onPick(RGBA(NSColor($0))) }
            ), supportsOpacity: false)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 30)
            .help("Custom colour")
        }
    }
}

struct ArrangeSection: View {
    @ObservedObject var session: EditSession
    let id: UUID

    var body: some View {
        InspectorSection("Arrange") {
            HStack(spacing: 6) {
                Button("Front") { session.document.bringToFront(id) }.help("Bring to front")
                Button("Back") { session.document.sendToBack(id) }.help("Send to back")
                Button("Duplicate") { session.document.duplicate(id) }.help("Duplicate  ⌘D")
            }
            .controlSize(.small)
            Button("Delete", role: .destructive) { session.document.delete(id) }
                .controlSize(.small)
                .help("Delete  ⌫")
        }
    }
}

struct CropSection: View {
    @ObservedObject var session: EditSession

    var body: some View {
        InspectorSection("Crop") {
            if let draft = session.tools.pendingCrop?.standardized {
                Text("\(Int((draft.width * session.document.scale).rounded())) × \(Int((draft.height * session.document.scale).rounded())) px")
                    .font(.system(size: 12).monospacedDigit())
            }
            Text("Drag across the image or move the edges. Return keeps the crop, Esc leaves it as it was.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Done") { session.applyCrop() }.buttonStyle(.borderedProminent)
                Button("Reset") { session.resetCropDraft() }
                Button("Cancel") { session.cancelCrop() }
            }
            .controlSize(.small)
        }
    }
}

struct BackdropSection: View {
    @ObservedObject var session: EditSession
    private var backdrop: Backdrop { session.document.backdrop }

    var body: some View {
        InspectorSection("Backdrop", accessory: {
            Toggle("Backdrop", isOn: Binding(get: { backdrop.enabled }, set: { v in session.updateBackdrop { $0.enabled = v } }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }) {
            if backdrop.enabled {
                HStack(spacing: 5) {
                    ForEach(BackdropPreset.allCases, id: \.self) { preset in
                        Button {
                            session.updateBackdrop { $0.fill = .preset(preset) }
                        } label: {
                            LinearGradient(colors: preset.colors.map { Color(nsColor: $0.nsColor) }, startPoint: .top, endPoint: .bottom)
                                .frame(width: 22, height: 18)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                                .padding(2)
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Color.primary, lineWidth: 1.5).opacity(backdrop.fill == .preset(preset) ? 1 : 0))
                        }
                        .buttonStyle(.plain)
                        .help(preset.title)
                    }
                    ColorPicker("Backdrop colour", selection: Binding(
                        get: {
                            if case .color(let c) = backdrop.fill { return Color(nsColor: c.nsColor) }
                            return Color.white
                        },
                        set: { c in session.updateBackdrop(continuous: true) { $0.fill = .color(RGBA(NSColor(c))) } }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 30)
                    .help("Custom colour")
                }
                SliderRow(label: "Padding", value: backdrop.padding, range: 0...160) { v in session.updateBackdrop(continuous: true) { $0.padding = v } }
                SliderRow(label: "Corners", value: backdrop.radius, range: 0...32) { v in session.updateBackdrop(continuous: true) { $0.radius = v } }
                InspectorRow(label: "Shadow") {
                    Toggle("Shadow", isOn: Binding(get: { backdrop.shadow }, set: { v in session.updateBackdrop { $0.shadow = v } }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
            } else {
                Text("Puts the capture on a calm background with padding, for posts and docs.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SliderRow: View {
    let label: String
    let value: CGFloat
    let range: ClosedRange<Double>
    let set: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 12))
                Spacer()
                Text("\(Int(value))").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { Double(value) }, set: { set(CGFloat($0.rounded())) }), in: range)
                .controlSize(.small)
        }
    }
}

// MARK: - Status bar

struct EditorStatusBar: View {
    @ObservedObject var session: EditSession

    var body: some View {
        let size = session.document.outputPixelSize
        HStack(spacing: 14) {
            Text("\(Int(size.width)) × \(Int(size.height)) px")
                .monospacedDigit()
            Text(session.tools.notice ?? (session.document.isSaved ? "Saved" : "Saving…"))
                .foregroundStyle(.tertiary)
            Spacer()
            Button { session.zoomOut() } label: { Image(systemName: "minus") }
                .buttonStyle(.plain).help("Zoom out  ⌘−")
            Menu("\(session.zoomPercent)%") {
                Button("Fit in Window") { session.zoomToFit() }
                Divider()
                ForEach([50, 100, 200], id: \.self) { p in
                    Button("\(p)%") { session.setMagnification(CGFloat(p) / 100) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .monospacedDigit()
            Button { session.zoomIn() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).help("Zoom in  ⌘+")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Helpers

extension AnnotationType {
    var displayName: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .text: return "Text"
        case .step: return "Step number"
        case .redaction: return "Redaction"
        }
    }
}

extension StrokePreset {
    static func nearest(to value: CGFloat) -> StrokePreset {
        allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) } ?? .medium
    }
}

extension TextSizePreset {
    static func nearest(to value: CGFloat) -> TextSizePreset {
        allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) } ?? .medium
    }
}
