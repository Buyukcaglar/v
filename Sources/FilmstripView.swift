import AppKit
import QuartzCore

/// Picasa-style filmstrip: a row of thumbnails with the current photo kept in the middle.
final class FilmstripView: NSView {
    var urls: [URL] = [] {
        didSet {
            popped.formIntersection(urls)
            needsLayout = true
        }
    }
    var current = 0 { didSet { needsLayout = true } }
    /// The thumbnail for an index, if it is ready.
    var thumbnail: ((Int) -> CGImage?)?
    /// The slots on screen, whose thumbnails are wanted, nearest the current photo first.
    var onVisibleRange: ((Range<Int>) -> Void)?
    var onSelect: ((Int) -> Void)?

    /// Side of the square a thumbnail fits in, in points.
    static let thumbnailSide: CGFloat = 56
    private let slot: CGFloat = 60
    private let gap: CGFloat = 6

    // As in Picasa Photo Viewer, thumbnails pop in one at a time, outward from the current
    // photo: each grows out of its middle while fading in, a little after the one before.
    private static let popDuration: CFTimeInterval = 0.3
    private static let popStagger: CFTimeInterval = 0.08
    private static let popEasing = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)  // ease-out cubic
    private var popped = Set<URL>()
    private var lastAppear: CFTimeInterval = 0
    private var slotLayers: [URL: CALayer] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Places thumbnails that have become ready.
    func thumbnailsChanged() { needsLayout = true }

    /// The next thumbnails to appear pop in again, as when the viewer opens.
    func resetPopIn() { popped.removeAll() }

    private func slotRects() -> [(index: Int, rect: NSRect)] {
        guard !urls.isEmpty else { return [] }
        let count = urls.count
        let step = slot + gap
        // Fill the strip: show everything when it fits, otherwise keep the current photo
        // as central as possible without leaving empty slots at either end.
        let n = min(max(Int((bounds.width + gap) / step), 1), count)
        let first = min(max(current - n / 2, 0), count - n)
        let x0 = bounds.midX - (CGFloat(n) * step - gap) / 2
        let y = bounds.midY - slot / 2
        return (0..<n).map { k in
            (first + k, NSRect(x: x0 + CGFloat(k) * step, y: y, width: slot, height: slot))
        }
    }

    private func aspectFit(_ size: CGSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let s = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * s, h = size.height * s
        return NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h).integral
    }

    override func layout() {
        super.layout()
        let slots = slotRects()
        onVisibleRange?((slots.first?.index ?? 0)..<((slots.last?.index ?? -1) + 1))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var shown = Set<URL>()
        let now = CACurrentMediaTime()
        for (i, r) in slots.sorted(by: { abs($0.index - current) < abs($1.index - current) }) {
            let url = urls[i]
            // A slot stays empty until its thumbnail is ready.
            guard let image = thumbnail?(i) ?? slotLayers[url].flatMap({ $0.contents as! CGImage? }) else { continue }
            shown.insert(url)
            let layer = slotLayers[url] ?? makeSlotLayer(for: url)
            layer.contents = image
            layer.frame = aspectFit(CGSize(width: image.width, height: image.height), in: r.insetBy(dx: 2, dy: 2))
            layer.opacity = i == current ? 1 : 0.55
            let border = layer.sublayers![0]
            border.frame = layer.bounds.insetBy(dx: -2.5, dy: -2.5)
            border.isHidden = i != current
            if popped.insert(url).inserted {
                lastAppear = max(now, lastAppear + Self.popStagger)
                popIn(layer, at: lastAppear)
            }
        }
        for (url, layer) in slotLayers where !shown.contains(url) {
            layer.removeFromSuperlayer()
            slotLayers[url] = nil
        }
        CATransaction.commit()
    }

    private func makeSlotLayer(for url: URL) -> CALayer {
        let layer = CALayer()
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        let border = CALayer()
        border.borderColor = NSColor.white.cgColor
        border.borderWidth = 2
        layer.addSublayer(border)
        self.layer?.addSublayer(layer)
        slotLayers[url] = layer
        return layer
    }

    /// Grows the slot out of its middle while it fades in. Both animations run towards the
    /// model values, so a slot that becomes current meanwhile still ends up opaque.
    private func popIn(_ layer: CALayer, at time: CFTimeInterval) {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = Self.popDuration
        group.timingFunction = Self.popEasing
        group.beginTime = layer.convertTime(time, from: nil)
        group.fillMode = .backwards
        layer.add(group, forKey: "pop")
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = slotRects().first(where: { $0.rect.contains(p) }) { onSelect?(hit.index) }
    }
}
