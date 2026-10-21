import AppKit
import ScreenCaptureKit

/// A still of one display, taken just before the selector appears.
struct FrozenScreen {
    let screen: NSScreen
    let image: CGImage
    let scale: CGFloat
    var frame: CGRect { screen.frame }
}

struct GrabResult {
    let image: CGImage
    let scale: CGFloat
}

enum GrabError: LocalizedError {
    case permissionDenied
    case noDisplay
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "\(AppIdentity.name) is not allowed to see the screen yet."
        case .noDisplay: return "There is no display to capture."
        case .failed(let message): return message
        }
    }
}

/// Wraps ScreenCaptureKit stills. The app's own windows (shelf cards, pins) are left out.
final class ScreenGrabber {
    private(set) var isBusy = false

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    func freezeScreens() async throws -> [FrozenScreen] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            log("listing shareable content failed: \(error)")
            throw ScreenGrabber.hasPermission ? GrabError.failed(error.localizedDescription) : GrabError.permissionDenied
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var result: [FrozenScreen] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }
            let scale = screen.backingScaleFactor
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int((screen.frame.width * scale).rounded())
            config.height = Int((screen.frame.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                result.append(FrozenScreen(screen: screen, image: image, scale: scale))
            } catch {
                log("still image of display \(displayID) not taken: \(error)")
            }
        }
        if result.isEmpty { throw ScreenGrabber.hasPermission ? GrabError.noDisplay : GrabError.permissionDenied }
        return result
    }

    /// Runs the interactive selector. Returns nil when the user cancels.
    @MainActor
    func pick(mode: SelectionSession.Mode) async throws -> GrabResult? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        let stills = try await freezeScreens()
        return await SelectionSession(mode: mode, screens: stills).run()
    }

    @MainActor
    func grabScreen() async throws -> GrabResult? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        let stills = try await freezeScreens()
        let mouse = NSEvent.mouseLocation
        guard let target = stills.first(where: { $0.frame.contains(mouse) }) ?? stills.first else { throw GrabError.noDisplay }
        return GrabResult(image: target.image, scale: target.scale)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
