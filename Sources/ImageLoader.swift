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
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let props = Props(src)
        log("full", url)
        return thumbnail(src, props, maxPixel: min(props.longSide, maxDecodedSide))
    }

    /// The image at the smallest size that still fills `box` (device pixels) when fitted,
    /// with EXIF orientation applied. JPEG decodes much faster at exact power-of-two fractions,
    /// so sizes are rounded up to one of those unless the format scales freely.
    static func screenImage(_ url: URL, fitting box: CGSize) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let props = Props(src)
        log("screen", url)
        let long = min(props.longSide, maxDecodedSide)
        let needed = neededLongSide(props.orientedSize, box: box)
        guard needed < long else { return thumbnail(src, props, maxPixel: long) }
        let type = CGImageSourceGetType(src).map { $0 as String } ?? ""
        if freelyScaledTypes.contains(type) { return thumbnail(src, props, maxPixel: needed) }
        var factor = 1
        while props.longSide / (factor * 2) >= needed { factor *= 2 }
        // Subsampling skips the transform and the scaler, and needs far less scratch memory.
        if props.orientation == 1, factor <= 8, subsampledTypes.contains(type), props.longSide / factor <= maxDecodedSide,
           let img = CGImageSourceCreateImageAtIndex(src, props.index, [
               kCGImageSourceSubsampleFactor: factor,
               kCGImageSourceShouldCacheImmediately: true,
           ] as CFDictionary) {
            return img
        }
        return thumbnail(src, props, maxPixel: min(props.longSide / factor, maxDecodedSide))
    }

    /// Long side, in pixels, of `size` fitted into `box`, never enlarged.
    static func neededLongSide(_ size: CGSize, box: CGSize) -> Int {
        guard size.width > 0, size.height > 0 else { return 0 }
        let scale = min(box.width / size.width, box.height / size.height, 1)
        return Int((max(size.width, size.height) * scale).rounded(.up))
    }

    private static let freelyScaledTypes: Set<String> = ["public.heic", "public.heif", "public.avif"]
    private static let subsampledTypes: Set<String> = ["public.jpeg", "public.png", "public.tiff"]

    private struct Props {
        let index: Int
        let width: Int, height: Int, orientation: Int

        init(_ src: CGImageSource) {
            index = CGImageSourceGetPrimaryImageIndex(src)
            let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
            width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        }

        var longSide: Int { max(width, height) }
        var orientedSize: CGSize {
            orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
    }

    private static func thumbnail(_ src: CGImageSource, _ props: Props, maxPixel: Int) -> CGImage? {
        if maxPixel > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let img = CGImageSourceCreateThumbnailAtIndex(src, props.index, opts as CFDictionary) { return img }
        }
        return CGImageSourceCreateImageAtIndex(src, props.index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private static func log(_ tier: String, _ url: URL) {
        #if DEBUG
        FileHandle.standardError.write("decode \(tier) \(url.lastPathComponent)\n".data(using: .utf8)!)
        #endif
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
