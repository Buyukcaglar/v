import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A colour the pen draws in.
struct MarkColor: Equatable {
    let name: String
    let rgb: UInt32

    init(_ name: String, _ rgb: UInt32) {
        self.name = name
        self.rgb = rgb
    }

    private var components: (CGFloat, CGFloat, CGFloat) {
        (CGFloat(rgb >> 16 & 0xFF) / 255, CGFloat(rgb >> 8 & 0xFF) / 255, CGFloat(rgb & 0xFF) / 255)
    }

    var cgColor: CGColor {
        let (r, g, b) = components
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    var nsColor: NSColor {
        let (r, g, b) = components
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    static let palette: [MarkColor] = [
        MarkColor("Red", 0xFF0000), MarkColor("Orange", 0xFF8000), MarkColor("Yellow", 0xFFFF00),
        MarkColor("Green", 0x00FF00), MarkColor("Cyan", 0x00FFFF), MarkColor("Blue", 0x0000FF),
        MarkColor("Purple", 0x8000FF), MarkColor("Magenta", 0xFF00FF), MarkColor("Pink", 0xFF80C0),
        MarkColor("Brown", 0x804000), MarkColor("Dark Green", 0x008000), MarkColor("Teal", 0x008080),
        MarkColor("Navy", 0x000080), MarkColor("White", 0xFFFFFF), MarkColor("Gray", 0x808080),
        MarkColor("Black", 0x000000),
    ]
}

/// How thick the pen draws, in screen pixels at the zoom it draws at. At actual size that is the
/// photo's own pixels.
enum MarkWidth: Int, CaseIterable {
    case thin = 1, medium = 3, thick = 5

    var name: String {
        switch self {
        case .thin: return "Thin (1 px)"
        case .medium: return "Medium (3 px)"
        case .thick: return "Thick (5 px)"
        }
    }
}

/// An ellipse drawn on a photo. It is kept in the photo's own pixels, upright and with y up, so it
/// stays on its spot as the photo is zoomed or turned.
struct Mark: Equatable {
    var rect: CGRect
    var color: MarkColor
    /// In the photo's pixels.
    var lineWidth: CGFloat
}

/// Saves a copy of a photo with its marks drawn in, next to it: "IMG_1234.JPG" becomes
/// "IMG_1234_marked.JPG". Formats ImageIO can't write, such as camera RAW and WebP, are saved as
/// JPEG, or as PNG when they have transparency.
enum MarkupWriter {
    /// Copies still being written. The app waits for them before it quits.
    @MainActor private(set) static var pending = 0
    /// Called once, when nothing is left to write.
    @MainActor static var onIdle: (() -> Void)?

    /// Writes the copy off the main thread and reports where it went.
    @MainActor static func save(_ marks: [Mark], on url: URL, markedSize: CGSize, turns: Int,
                                completion: @escaping (Result<URL, Error>) -> Void) {
        pending += 1
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try write(marks, on: url, markedSize: markedSize, turns: turns) }
            DispatchQueue.main.async {
                pending -= 1
                completion(result)
                if pending == 0, let idle = onIdle {
                    onIdle = nil
                    idle()
                }
            }
        }
    }

    /// Where the copy of `url` goes; `ext` replaces its extension, in the same case.
    static func destination(for url: URL, ext: String? = nil) -> URL {
        let original = url.pathExtension
        var newExt = original
        if let ext { newExt = !original.isEmpty && original == original.uppercased() ? ext.uppercased() : ext }
        let copy = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_marked")
        return newExt.isEmpty ? copy : copy.appendingPathExtension(newExt)
    }

    /// Draws `marks` on the photo at full resolution, turned by `turns` quarter turns as on screen,
    /// and writes the copy. `markedSize` is the photo's upright size the marks were drawn on.
    static func write(_ marks: [Mark], on url: URL, markedSize: CGSize, turns: Int) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url]) }
        let index = CGImageSourceGetPrimaryImageIndex(src)
        guard let photo = CGImageSourceCreateImageAtIndex(src, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url]) }
        var props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1

        let stored = CGSize(width: photo.width, height: photo.height)
        let upright = orientation >= 5 ? CGSize(width: stored.height, height: stored.width) : stored
        let size = turns % 2 == 0 ? upright : CGSize(width: upright.height, height: upright.width)
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(photo.alphaInfo)
        let context = { (space: CGColorSpace) in
            CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: (hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)
        }
        // The photo's own colour space keeps wide-gamut colours; grey, CMYK and HDR ones become sRGB.
        guard let ctx = photo.colorSpace.flatMap({ $0.model == .rgb && $0.supportsOutput ? context($0) : nil })
                ?? context(CGColorSpace(name: CGColorSpace.sRGB)!)
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination(for: url)]) }

        // The photo and the marks turn about the middle, as on the canvas.
        let turn = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            .rotated(by: -CGFloat(turns) * .pi / 2)
        ctx.saveGState()
        ctx.concatenate(turn)
        ctx.concatenate(ImageCanvasView.transform(forOrientation: orientation))
        ctx.translateBy(x: -stored.width / 2, y: -stored.height / 2)
        ctx.draw(photo, in: CGRect(origin: .zero, size: stored))
        ctx.restoreGState()

        ctx.concatenate(turn)
        ctx.translateBy(x: -upright.width / 2, y: -upright.height / 2)
        ctx.scaleBy(x: upright.width / markedSize.width, y: upright.height / markedSize.height)
        for mark in marks {
            ctx.setStrokeColor(mark.color.cgColor)
            ctx.setLineWidth(mark.lineWidth)
            ctx.strokeEllipse(in: mark.rect)
        }
        guard let marked = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination(for: url)]) }

        // The copy keeps the photo's metadata, but its pixels are now upright.
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = Int(size.width)
            exif[kCGImagePropertyExifPixelYDimension] = Int(size.height)
            props[kCGImagePropertyExifDictionary] = exif
        }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                    kCGImagePropertyHasAlpha, kCGImagePropertyColorModel, kCGImagePropertyProfileName] {
            props[key] = nil
        }
        props[kCGImageDestinationLossyCompressionQuality] = 0.92

        // The photo's own format where ImageIO can write it, otherwise JPEG or PNG.
        let type = CGImageSourceGetType(src).map { $0 as String }
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        var attempts: [(type: String, url: URL)] = []
        if let type, writable.contains(type) { attempts.append((type, destination(for: url))) }
        let fallback = hasAlpha ? (type: UTType.png.identifier, ext: "png") : (type: UTType.jpeg.identifier, ext: "jpg")
        if type != fallback.type { attempts.append((fallback.type, destination(for: url, ext: fallback.ext))) }
        for attempt in attempts {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, attempt.type as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, marked, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { continue }
            try data.write(to: attempt.url, options: .atomic)
            return attempt.url
        }
        throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination(for: url)])
    }
}
