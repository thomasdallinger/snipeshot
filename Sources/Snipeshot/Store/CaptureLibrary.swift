import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

struct CaptureFile: Identifiable, Equatable {
    let url: URL
    let createdAt: Date
    let modDate: Date
    let pixelSize: CGSize
    let hasEdits: Bool

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Edit files sit next to the image as hidden JSON: `.<file>.<editFileSuffix>`.
enum EditFileStore {
    static func url(for image: URL) -> URL {
        image.deletingLastPathComponent().appendingPathComponent(".\(image.lastPathComponent).\(AppIdentity.editFileSuffix)")
    }

    static func load(for image: URL) -> EditFile? {
        guard let data = try? Data(contentsOf: url(for: image)) else { return nil }
        return try? JSONDecoder().decode(EditFile.self, from: data)
    }

    static func save(_ edits: EditFile, for image: URL) {
        let target = url(for: image)
        guard edits.hasEdits else {
            try? FileManager.default.removeItem(at: target)
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(edits).write(to: target, options: .atomic)
        } catch {
            log("could not write edits for \(image.lastPathComponent): \(error)")
        }
    }

    static func remove(for image: URL) {
        try? FileManager.default.removeItem(at: url(for: image))
    }
}

/// The capture library: every image file in the save folder, newest first, kept fresh by a folder watcher.
final class CaptureLibrary: ObservableObject {
    @Published private(set) var captures: [CaptureFile] = []

    private let settings: Preferences
    private var folderWatcher: DispatchSourceFileSystemObject?
    private var refreshWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private let ioQueue = DispatchQueue(label: "\(AppIdentity.bundleID).library", qos: .userInitiated)

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]

    init(settings: Preferences) {
        self.settings = settings
        settings.$saveFolder
            .removeDuplicates()
            .sink { [weak self] dir in self?.directoryChanged(dir) }
            .store(in: &cancellables)
    }

    var directory: URL { settings.saveFolder }

    func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func directoryChanged(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        watch(dir)
        refresh()
    }

    private func watch(_ dir: URL) {
        folderWatcher?.cancel()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleRefresh() }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderWatcher = source
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    func refresh(completion: (() -> Void)? = nil) {
        let dir = directory
        ioQueue.async { [weak self] in
            let items = Self.scan(dir)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.captures != items { self.captures = items }
                completion?()
            }
        }
    }

    private static func scan(_ dir: URL) -> [CaptureFile] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var result: [CaptureFile] = []
        for url in urls where imageExtensions.contains(url.pathExtension.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let editDate = (try? EditFileStore.url(for: url).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let modDate = max(values.contentModificationDate ?? .distantPast, editDate ?? .distantPast)
            result.append(CaptureFile(
                url: url,
                createdAt: values.creationDate ?? values.contentModificationDate ?? Date(),
                modDate: modDate,
                pixelSize: pixelSize(of: url),
                hasEdits: editDate != nil
            ))
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    static func pixelSize(of url: URL) -> CGSize {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return .zero }
        return CGSize(width: w, height: h)
    }

    func capture(for url: URL) -> CaptureFile? {
        captures.first { $0.url == url }
    }

    // MARK: - Writing

    /// Writes a fresh capture into the library. Returns the file URL.
    func saveCapture(_ image: CGImage, scale: CGFloat) throws -> URL {
        ensureDirectory()
        let url = uniqueURL(base: Self.captureName(date: Date()), ext: settings.fileFormat.fileExtension)
        try ImageWriter.write(image, to: url, format: settings.fileFormat, quality: settings.jpegQuality, scale: scale)
        insertOptimistically(url: url, pixelSize: CGSize(width: image.width, height: image.height))
        return url
    }

    /// Copies external image files into the library (drag & drop or the import button).
    func importFiles(_ urls: [URL]) -> [URL] {
        ensureDirectory()
        var imported: [URL] = []
        for src in urls where Self.imageExtensions.contains(src.pathExtension.lowercased()) {
            let dest = uniqueURL(base: src.deletingPathExtension().lastPathComponent, ext: src.pathExtension.lowercased())
            do {
                try FileManager.default.copyItem(at: src, to: dest)
                imported.append(dest)
            } catch {
                log("skipped \(src.lastPathComponent) while importing: \(error)")
            }
        }
        refresh()
        return imported
    }

    func trash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            log("moving \(url.lastPathComponent) to the Trash failed: \(error)")
        }
        EditFileStore.remove(for: url)
        captures.removeAll { $0.url == url }
    }

    /// Show the new capture immediately instead of waiting for the folder watcher.
    private func insertOptimistically(url: URL, pixelSize: CGSize) {
        let now = Date()
        captures.insert(CaptureFile(url: url, createdAt: now, modDate: now, pixelSize: pixelSize, hasEdits: false), at: 0)
    }

    private func uniqueURL(base: String, ext: String) -> URL {
        var url = directory.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    static func captureName(date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Capture \(f.string(from: date))"
    }
}

enum ImageWriter {
    static func write(_ image: CGImage, to url: URL, format: FileFormat, quality: Double, scale: CGFloat) throws {
        let type = (format == .png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // DPI metadata makes Retina captures open at their on-screen size in other apps.
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
