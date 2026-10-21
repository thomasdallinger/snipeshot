import AppKit
import ImageIO

/// Downscaled previews keyed by file + modification date; edited captures show their annotations.
final class PreviewCache {
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).previews", qos: .userInitiated, attributes: .concurrent)

    init() { cache.countLimit = 400 }

    private func key(_ url: URL, _ modDate: Date) -> NSString {
        "\(url.path)|\(modDate.timeIntervalSince1970)" as NSString
    }

    func cached(_ url: URL, modDate: Date) -> NSImage? {
        cache.object(forKey: key(url, modDate))
    }

    func preview(for url: URL, modDate: Date, maxPixel: Int = 640, completion: @escaping (NSImage?) -> Void) {
        let k = key(url, modDate)
        if let hit = cache.object(forKey: k) {
            completion(hit)
            return
        }
        queue.async { [cache] in
            let image = Self.render(url: url, maxPixel: maxPixel)
            if let image { cache.setObject(image, forKey: k) }
            DispatchQueue.main.async { completion(image) }
        }
    }

    static func render(url: URL, maxPixel: Int) -> NSImage? {
        if let edits = EditFileStore.load(for: url), edits.hasEdits,
           let doc = MarkupDocument.load(url: url), let flat = doc.flattened() {
            return downscale(flat, maxPixel: maxPixel)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }

    private static func downscale(_ image: CGImage, maxPixel: Int) -> NSImage? {
        let scale = min(1, CGFloat(maxPixel) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage().map { NSImage(cgImage: $0, size: CGSize(width: w, height: h)) }
    }
}

/// Produces the file that gets handed to other apps on drag: the original, or a flattened copy if edited.
enum DragExport {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(AppIdentity.bundleID)/Drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileForDrag(_ url: URL) -> URL {
        guard let edits = EditFileStore.load(for: url), edits.hasEdits,
              let doc = MarkupDocument.load(url: url), let flat = doc.flattened() else { return url }
        let out = directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png")
        do {
            try ImageWriter.write(flat, to: out, format: .png, quality: 1, scale: doc.scale)
            return out
        } catch {
            log("drag copy not written: \(error)")
            return url
        }
    }

    static func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
