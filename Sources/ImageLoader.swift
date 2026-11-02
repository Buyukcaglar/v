import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ImageInfo {
    /// Pixel size after applying the EXIF orientation.
    let pixelSize: CGSize
    let frameCount: Int
    let fileSize: Int64?
    let isAnimatable: Bool
}

enum ImageLoader {
    /// Longest side we decode to; keeps very large panoramas within GPU texture limits.
    static let maxDecodedSide = 12_000

    static func info(_ url: URL) -> ImageInfo? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        let idx = CGImageSourceGetPrimaryImageIndex(src)
        let props = CGImageSourceCopyPropertiesAtIndex(src, idx, nil) as? [CFString: Any] ?? [:]
        var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation >= 5 { swap(&w, &h) }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return ImageInfo(pixelSize: CGSize(width: w, height: h),
                         frameCount: count,
                         fileSize: fileSize,
                         isAnimatable: count > 1 && isAnimatableType(url))
    }

    /// Full-resolution image with EXIF orientation applied.
    static func fullImage(_ url: URL) -> CGImage? {
        #if DEBUG
        FileHandle.standardError.write("decode full \(url.lastPathComponent)\n".data(using: .utf8)!)
        #endif
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let idx = CGImageSourceGetPrimaryImageIndex(src)
        let props = CGImageSourceCopyPropertiesAtIndex(src, idx, nil) as? [CFString: Any] ?? [:]
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let side = min(max(w, h), maxDecodedSide)
        if side > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let img = CGImageSourceCreateThumbnailAtIndex(src, idx, opts as CFDictionary) { return img }
        }
        return CGImageSourceCreateImageAtIndex(src, idx, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), opts as CFDictionary)
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
        return type.conforms(to: .image)
    }

    private static func isAnimatableType(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
        let animatable: [UTType] = [.gif, .png, .webP, UTType("public.heics")].compactMap { $0 }
        return animatable.contains { type.conforms(to: $0) }
    }

    /// Images in a folder, in Finder order.
    static func images(inDirectory dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentTypeKey, .isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && isImage($0) }
            .map { $0.standardizedFileURL }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Resolves what the viewer should browse for a set of opened items, and where to start.
    static func browseList(for urls: [URL]) -> (files: [URL], start: Int) {
        let urls = urls.map { $0.standardizedFileURL }
        if urls.count == 1, let only = urls.first {
            if isDirectory(only) {
                return (images(inDirectory: only), 0)
            }
            var siblings = images(inDirectory: only.deletingLastPathComponent())
            if !siblings.contains(only) { siblings = [only] }
            return (siblings, siblings.firstIndex(of: only) ?? 0)
        }
        let files = urls.flatMap { isDirectory($0) ? images(inDirectory: $0) : [$0] }
        return (files, 0)
    }
}
