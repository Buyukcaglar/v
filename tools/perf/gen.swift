// Generates the synthetic photo set the perf tools run against (no personal photos involved).
// Usage: gen <output dir>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default

struct RNG {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
}

func makeImage(w: Int, h: Int, seed: UInt64, screenshot: Bool = false) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    var r = RNG(s: seed &* 0x9E37_79B9_7F4A_7C15 | 1)
    func rnd() -> CGFloat { CGFloat(r.next() % 10_000) / 10_000 }
    if screenshot {
        ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for _ in 0..<400 {
            ctx.setFillColor(CGColor(red: rnd(), green: rnd(), blue: rnd(), alpha: 1))
            ctx.fill(CGRect(x: rnd() * CGFloat(w), y: rnd() * CGFloat(h), width: rnd() * 600 + 20, height: rnd() * 40 + 8))
        }
        return ctx.makeImage()!
    }
    let colors = [CGColor(red: rnd(), green: rnd(), blue: rnd(), alpha: 1), CGColor(red: rnd(), green: rnd(), blue: rnd(), alpha: 1)]
    ctx.drawLinearGradient(CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!,
                           start: .zero, end: CGPoint(x: w, y: h), options: [])
    for _ in 0..<160 {
        ctx.setFillColor(CGColor(red: rnd(), green: rnd(), blue: rnd(), alpha: 0.5))
        let d = rnd() * CGFloat(min(w, h)) / 3 + 40
        ctx.fillEllipse(in: CGRect(x: rnd() * CGFloat(w), y: rnd() * CGFloat(h), width: d, height: d * (0.5 + rnd())))
    }
    // Sensor-like noise so JPEG and HEIC sizes and decode times resemble real photos.
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let n = ctx.bytesPerRow * h
    var i = 0
    while i < n {
        let v = r.next()
        for k in 0..<4 where i + k < n { p[i + k] = UInt8(clamping: Int(p[i + k]) + Int((v >> (k * 8)) & 0x0F) - 8) }
        i += 4
    }
    return ctx.makeImage()!
}

func write(_ img: CGImage, to url: URL, type: UTType, props: [CFString: Any]) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    precondition(CGImageDestinationFinalize(dest), "couldn’t write \(url.lastPathComponent)")
}

func dir(_ name: String) -> URL {
    let d = root.appendingPathComponent(name)
    try? fm.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

// 24 camera-style 24 MP JPEGs with an EXIF thumbnail; every 6th is stored sideways (orientation 6).
let photos = dir("photos")
for i in 1...24 {
    let sideways = i % 6 == 0
    let img = makeImage(w: sideways ? 4000 : 6000, h: sideways ? 6000 : 4000, seed: UInt64(i))
    var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85, kCGImageDestinationEmbedThumbnail: true]
    if sideways { props[kCGImagePropertyOrientation] = 6 }
    write(img, to: photos.appendingPathComponent(String(format: "IMG_%04d.jpg", i)), type: .jpeg, props: props)
}
// Conforms to public.image, but ImageIO can’t decode it.
try! "<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'/>"
    .write(to: photos.appendingPathComponent("logo.svg"), atomically: true, encoding: .utf8)

// 48 MP iPhone-style HEICs.
let heic = dir("heic")
for i in 1...4 {
    write(makeImage(w: 8064, h: 6048, seed: UInt64(100 + i)), to: heic.appendingPathComponent(String(format: "IMG_%04d.heic", i)),
          type: .heic, props: [kCGImageDestinationLossyCompressionQuality: 0.8, kCGImageDestinationEmbedThumbnail: true])
}

// 5K screenshots, which have no embedded thumbnail.
let png = dir("png")
for i in 1...6 {
    write(makeImage(w: 5120, h: 2880, seed: UInt64(200 + i), screenshot: true),
          to: png.appendingPathComponent("Screenshot \(i).png"), type: .png, props: [:])
}

// A 60-frame animated GIF.
let gifURL = dir("gif").appendingPathComponent("anim.gif")
let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, 60, nil)!
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for f in 0..<60 {
    CGImageDestinationAddImage(gif, makeImage(w: 800, h: 600, seed: UInt64(300 + f)),
                               [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
}
precondition(CGImageDestinationFinalize(gif))

// A 10,000-photo folder made of hard links to one JPEG, so it costs no disk space.
let many = dir("many")
let source = photos.appendingPathComponent("IMG_0001.jpg")
for i in 1...10_000 { try? fm.linkItem(at: source, to: many.appendingPathComponent("IMG_\(i).jpg")) }
print("Generated test photos in \(root.path)")
