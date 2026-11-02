// Times ImageIO decode strategies on one file, in a fresh process so the peak footprint is clean.
// Usage: bench <mode> <file> [arg]    N=<runs> (default 5)
//   props            CGImageSource properties + frame count (what ImageLoader.info reads)
//   full             full size via the thumbnail API with the EXIF transform (what ImageLoader.fullImage does)
//   pow2 <needed>    thumbnail API at full/2^k, the smallest such size still ≥ needed px (JPEG DCT fast path)
//   fit <px>         thumbnail API at exactly px on the long side
//   sub <factor>     CGImageSourceCreateImageAtIndex with kCGImageSourceSubsampleFactor, no EXIF transform
//   thumb <px>       embedded thumbnail when present, else decoded (what the filmstrip does)
//   ql <pt>          QuickLook thumbnail service at pt × 2 (cached across launches)
import Foundation
import ImageIO
import QuickLookThumbnailing

func footprint() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
}

func ms(_ block: () -> Void) -> Double {
    let t = DispatchTime.now().uptimeNanoseconds
    block()
    return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
}

let args = CommandLine.arguments
let mode = args[1], url = URL(fileURLWithPath: args[2])
let arg = args.count > 3 ? Double(args[3])! : 0
let runs = Int(ProcessInfo.processInfo.environment["N"] ?? "5")!
let base = footprint().now
var times: [Double] = []
var kept: CGImage?
var note = ""

func source() -> CGImageSource { CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)! }

func longSide(_ src: CGImageSource) -> Int {
    let props = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [CFString: Any] ?? [:]
    return max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
}

func thumbnailAPI(_ src: CGImageSource, maxPixel: Int, always: Bool = true) -> CGImage? {
    var opts: [CFString: Any] = [kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                 kCGImageSourceShouldCacheImmediately: true]
    opts[always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
    return CGImageSourceCreateThumbnailAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), opts as CFDictionary)
}

for _ in 0..<runs {
    kept = nil
    times.append(ms {
        switch mode {
        case "props":
            let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
            note = "frames=\(CGImageSourceGetCount(src))"
            _ = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil)
        case "full":
            let src = source()
            kept = thumbnailAPI(src, maxPixel: min(longSide(src), 12_000))
        case "pow2":
            let src = source()
            var side = min(longSide(src), 12_000)
            while side / 2 >= Int(arg) { side /= 2 }
            kept = thumbnailAPI(src, maxPixel: side)
        case "fit":
            kept = thumbnailAPI(source(), maxPixel: Int(arg))
        case "sub":
            let src = source()
            var opts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            if arg > 1 { opts[kCGImageSourceSubsampleFactor] = Int(arg) }
            kept = CGImageSourceCreateImageAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), opts as CFDictionary)
        case "thumb":
            kept = thumbnailAPI(source(), maxPixel: Int(arg), always: false)
        case "ql":
            let done = DispatchSemaphore(value: 0)
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: arg, height: arg), scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in kept = rep?.cgImage; done.signal() }
            done.wait()
        default:
            fatalError("unknown mode \(mode)")
        }
    })
}

let f = footprint()
if let img = kept { note = "\(img.width)×\(img.height) = \(String(format: "%.1f", Double(img.bytesPerRow * img.height) / 1_048_576)) MB" }
if mode == "ql" { note += String(format: ", first call %.1f ms", times[0]) }
let sorted = times.sorted()
print(String(format: "%-6@ %-20@ median %6.1f ms  min %6.1f ms  peak +%4.0f MB  held +%4.0f MB  %@",
             mode as NSString, url.lastPathComponent as NSString, sorted[sorted.count / 2], sorted[0],
             f.peak - base, f.now - base, note as NSString))
withExtendedLifetime(kept) {}
