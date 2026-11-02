import AppKit

/// Picasa-style filmstrip: a row of thumbnails with the current photo kept in the middle.
final class FilmstripView: NSView {
    var count = 0 { didSet { needsDisplay = true } }
    var current = 0 { didSet { needsDisplay = true } }
    var thumbnail: ((Int) -> CGImage?)?
    var onSelect: ((Int) -> Void)?

    private let slot: CGFloat = 60
    private let gap: CGFloat = 6

    // As in Picasa Photo Viewer, thumbnails pop in one at a time, outward from the current
    // photo: each grows out of its middle while fading in, a little after the one before.
    private static let popDuration: CFTimeInterval = 0.3
    private static let popStagger: CFTimeInterval = 0.08
    private var appearTimes: [Int: CFTimeInterval] = [:]
    private var lastAppear: CFTimeInterval = 0
    private var popTimer: Timer?

    private func slotRects() -> [(index: Int, rect: NSRect)] {
        guard count > 0 else { return [] }
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

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        let slots = slotRects()
        var images: [Int: CGImage] = [:]
        for (i, _) in slots { images[i] = thumbnail?(i) }

        let now = CACurrentMediaTime()
        for (i, _) in slots.sorted(by: { abs($0.index - current) < abs($1.index - current) })
        where images[i] != nil && appearTimes[i] == nil {
            lastAppear = max(now, lastAppear + Self.popStagger)
            appearTimes[i] = lastAppear
        }

        var popping = false
        for (i, r) in slots {
            // A slot stays empty until its thumbnail is ready.
            guard let img = images[i] else { continue }
            let isCurrent = i == current
            let p = min(max((now - (appearTimes[i] ?? now)) / Self.popDuration, 0), 1)
            let shown = 1 - pow(1 - p, 3)  // ease-out cubic
            if p < 1 { popping = true }
            guard shown > 0 else { continue }
            let full = aspectFit(CGSize(width: img.width, height: img.height), in: r.insetBy(dx: 2, dy: 2))
            let frame = full.insetBy(dx: full.width * (1 - shown) / 2, dy: full.height * (1 - shown) / 2)
            ctx.saveGState()
            ctx.setAlpha((isCurrent ? 1 : 0.55) * shown)
            ctx.draw(img, in: frame)
            ctx.restoreGState()
            if isCurrent {
                NSColor.white.withAlphaComponent(shown).setStroke()
                let path = NSBezierPath(rect: frame.insetBy(dx: -1.5, dy: -1.5))
                path.lineWidth = 2
                path.stroke()
            }
        }
        setPopping(popping)
    }

    /// Redraws every frame while a thumbnail is still popping in.
    private func setPopping(_ popping: Bool) {
        if popping, popTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.needsDisplay = true }
            RunLoop.main.add(timer, forMode: .common)
            popTimer = timer
        } else if !popping {
            popTimer?.invalidate()
            popTimer = nil
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { setPopping(false) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = slotRects().first(where: { $0.rect.contains(p) }) { onSelect?(hit.index) }
    }
}
