import AppKit
import SwiftUI

/// Floats a capture above all windows. Drag to move, scroll or pinch to resize, Esc or ✕ to close.
final class PinnedImage: NSObject, NSWindowDelegate {
    private let window: PinnedPanel
    private let image: NSImage
    private let baseSize: CGSize
    private var scale: CGFloat = 1
    var onClose: ((PinnedImage) -> Void)?

    init(image: CGImage, pointScale: CGFloat) {
        let size = CGSize(width: CGFloat(image.width) / pointScale, height: CGFloat(image.height) / pointScale)
        self.image = NSImage(cgImage: image, size: size)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let maxSize = CGSize(width: screen.visibleFrame.width * 0.6, height: screen.visibleFrame.height * 0.6)
        let fit = min(1, maxSize.width / size.width, maxSize.height / size.height)
        baseSize = CGSize(width: size.width * fit, height: size.height * fit)
        let frame = CGRect(x: screen.visibleFrame.midX - baseSize.width / 2, y: screen.visibleFrame.midY - baseSize.height / 2,
                           width: baseSize.width, height: baseSize.height)
        window = PinnedPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        super.init()
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.aspectRatio = baseSize
        window.delegate = self
        window.onScale = { [weak self] factor in self?.rescale(by: factor) }
        window.onClose = { [weak self] in self?.close() }
        let view = PinnedImageView(image: self.image, onClose: { [weak self] in self?.close() }, onCopy: { [weak self] in
            guard let self, let cg = self.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            Clipboard.copy(image: cg, scale: pointScale)
        })
        window.contentView = FirstMouseHostingView(rootView: view)
    }

    func show() {
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 1
        }
    }

    func close() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.window.orderOut(nil)
            self.onClose?(self)
        })
    }

    private func rescale(by factor: CGFloat) {
        scale = min(max(scale * factor, 0.15), 4)
        let old = window.frame
        let size = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
        let frame = CGRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2, width: size.width, height: size.height)
        window.setFrame(frame, display: true)
    }
}

final class PinnedPanel: NSPanel {
    var onScale: ((CGFloat) -> Void)?
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
        onScale?(1 + delta)
    }

    override func magnify(with event: NSEvent) {
        onScale?(1 + event.magnification)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onClose?() } else { super.mouseDown(with: event) }
    }
}

struct PinnedImageView: View {
    let image: NSImage
    let onClose: () -> Void
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.black.opacity(0.2), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if hovering {
                    HStack(spacing: 6) {
                        ShelfIconButton(symbol: "xmark", help: "Close  esc", onImage: true, action: onClose)
                        ShelfIconButton(symbol: "doc.on.doc", help: "Copy", onImage: true, action: onCopy)
                    }
                    .padding(6)
                }
            }
            .onHover { hovering = $0 }
            .help("Drag to move. Scroll to resize. Double-click or press esc to close.")
    }
}
