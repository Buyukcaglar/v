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
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src).flatMap({ UTType($0 as String) }) else { return nil }
        // Counting frames scans the whole file, so only formats that can animate pay for it.
        let animatable = animatableTypes.contains { type.conforms(to: $0) }
        let count = animatable ? CGImageSourceGetCount(src) : 1
        guard count > 0 else { return nil }
        let props = Props(src)
        guard props.width > 0, props.height > 0 else { return nil }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return ImageInfo(pixelSize: props.orientedSize, frameCount: count, fileSize: fileSize, isAnimatable: count > 1)
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

    /// Every image type ImageIO can decode on this Mac (JPEG, PNG, HEIC, WebP, camera RAW, …).
    static let decodableTypes: [UTType] = ((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        .compactMap(UTType.init)
        .filter { $0.conforms(to: .image) }
    private static let decodableIDs = Set(decodableTypes.map(\.identifier))

    private static let animatableTypes: [UTType] = [.gif, .png, .webP, UTType("public.heics")].compactMap { $0 }

    /// Images in a folder, in Finder order.
    static func images(inDirectory dir: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .isRegularFileKey, .fileSizeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }
        return autoreleasepool {
            var named: [(name: String, url: URL)] = []
            named.reserveCapacity(items.count)
            for url in items {
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                      let type = values.contentType?.identifier, decodableIDs.contains(type) else { continue }
                named.append((url.lastPathComponent, url))
            }
            named.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return named.map(\.url)
        }
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// The photos in `file`'s folder with `file` itself in its place, or just `file` when the
    /// folder doesn't list it.
    static func siblings(of file: URL) -> (files: [URL], start: Int) {
        var siblings = images(inDirectory: file.deletingLastPathComponent())
        let name = file.lastPathComponent
        guard let start = siblings.firstIndex(where: { $0.lastPathComponent == name }) else { return ([file], 0) }
        siblings[start] = file
        return (siblings, start)
    }

    /// Resolves what the viewer should browse for a set of opened items, and where to start.
    static func browseList(for urls: [URL]) -> (files: [URL], start: Int) {
        if urls.count == 1, let only = urls.first {
            return isDirectory(only) ? (images(inDirectory: only), 0) : siblings(of: only)
        }
        let files = urls.flatMap { isDirectory($0) ? images(inDirectory: $0) : [$0] }
        return (files, 0)
    }
}
