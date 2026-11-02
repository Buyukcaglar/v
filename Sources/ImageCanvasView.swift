import AppKit
import QuartzCore

/// Shows one image with zoom, pan and quarter-turn rotation.
/// Zoom is in image pixels per device pixel, so 1.0 is "actual size".
final class ImageCanvasView: NSView {
    /// Picasa's easing, smoothstep 3t² − 2t³. With x control points at 1/3 and 2/3 the
    /// cubic Bézier is exactly that polynomial.
    static let easing = CAMediaTimingFunction(controlPoints: 1.0 / 3, 0, 2.0 / 3, 1)

    // Timings measured from Picasa Photo Viewer at 25 fps: the photo grows out of the middle of
    // its place decelerating like an ease-out cubic over about half a second, and on close it
    // shrinks back into the middle in three to four frames. Switching photos is a plain cut.
    static let openDuration: TimeInterval = 0.5
    static let openEasing = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
    static let closeDuration: TimeInterval = 0.15
    static let closeEasing = CAMediaTimingFunction(controlPoints: 0.32, 0, 0.67, 0)

    var onKeyDown: ((NSEvent) -> Bool)?
    var onClick: ((_ insideImage: Bool) -> Void)?
    var onSwipe: ((_ direction: Int) -> Void)?
    var onViewChange: (() -> Void)?

    /// Space kept free for the surrounding chrome when fitting the image.
    var reservedInsets = NSEdgeInsets() { didSet { relayout(animated: true) } }

    private let imageLayer = CALayer()
    private var pixelSize: CGSize = .zero
    private var turns = 0
    private(set) var zoom: CGFloat = 1
    private(set) var isFit = true
    private var pan: CGPoint = .zero
    /// The next photo to arrive grows in (the viewer is opening).
    private var opening = false
    /// How small the photo is when it starts growing and when it finishes shrinking.
    private static let collapsedScale: CGFloat = 0.03

    private var didDrag = false
    private var swipeAccum: CGFloat = 0
    private var swipeFired = false

    var hasContents: Bool { imageLayer.contents != nil }
    var rotation: Int { ((turns % 4) + 4) % 4 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    // MARK: Content

    func setImage(_ image: CGImage?, pixelSize size: CGSize, rotation: Int) {
        pixelSize = size.width > 0 ? size : CGSize(width: image?.width ?? 0, height: image?.height ?? 0)
        turns = rotation
        isFit = true
        pan = .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
        relayout(animated: false)
        if image != nil { growIn() }
    }

    func replaceContents(_ image: CGImage) {
        if pixelSize.width == 0 {
            pixelSize = CGSize(width: image.width, height: image.height)
            relayout(animated: false)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
        growIn()
    }

    // MARK: Open and close

    /// The first photo to arrive grows out of the middle of its fitted place.
    func playOpen() {
        opening = true
        if hasContents { growIn() }
    }

    private func growIn() {
        guard opening, pixelSize.width > 0 else { return }
        opening = false
        // With only fromValue set the animation runs to the model value, so a relayout while
        // it plays still lands in the right place. Position stays put: it grows from the middle.
        let grow = CABasicAnimation(keyPath: "bounds")
        grow.fromValue = NSValue(rect: collapsedBounds)
        grow.duration = Self.openDuration
        grow.timingFunction = Self.openEasing
        imageLayer.add(grow, forKey: "open")
    }

    /// Shrinks the photo back into the middle of its place.
    func playClose() {
        opening = false
        imageLayer.removeAnimation(forKey: "open")
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.closeDuration)
        CATransaction.setAnimationTimingFunction(Self.closeEasing)
        imageLayer.bounds = collapsedBounds
        CATransaction.commit()
    }

    private var collapsedBounds: CGRect {
        let b = imageLayer.bounds
        return CGRect(x: 0, y: 0, width: b.width * Self.collapsedScale, height: b.height * Self.collapsedScale)
    }

    func rotate(by quarterTurns: Int) {
        turns += quarterTurns
        relayout(animated: true)
    }

    // MARK: Zoom

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private var availRect: NSRect {
        let i = reservedInsets
        return NSRect(x: bounds.minX + i.left, y: bounds.minY + i.bottom,
                      width: max(bounds.width - i.left - i.right, 1),
                      height: max(bounds.height - i.top - i.bottom, 1))
    }

    /// Where the fitted photo goes, in device pixels.
    var fitBox: CGSize {
        let a = availRect
        return CGSize(width: a.width * backingScale, height: a.height * backingScale)
    }

    private var rotatedPixelSize: CGSize {
        rotation % 2 == 0 ? pixelSize : CGSize(width: pixelSize.height, height: pixelSize.width)
    }

    /// Largest zoom that fits the image on screen, never enlarging past actual size.
    var fitZoom: CGFloat {
        let s = rotatedPixelSize
        guard s.width > 0, s.height > 0 else { return 1 }
        let a = availRect
        return min(a.width * backingScale / s.width, a.height * backingScale / s.height, 1)
    }

    private var displaySize: CGSize {
        let s = rotatedPixelSize
        return CGSize(width: s.width * zoom / backingScale, height: s.height * zoom / backingScale)
    }

    var canPan: Bool {
        let d = displaySize, a = availRect
        return d.width > a.width + 0.5 || d.height > a.height + 0.5
    }

    func setZoom(_ z: CGFloat, around point: CGPoint? = nil, animated: Bool = false) {
        guard pixelSize.width > 0 else { return }
        let newZoom = min(max(z, fitZoom), 32)
        let a = availRect
        let anchor = point ?? CGPoint(x: a.midX, y: a.midY)
        let center = CGPoint(x: a.midX + pan.x, y: a.midY + pan.y)
        let f = newZoom / zoom
        let newCenter = CGPoint(x: anchor.x - (anchor.x - center.x) * f, y: anchor.y - (anchor.y - center.y) * f)
        zoom = newZoom
        pan = CGPoint(x: newCenter.x - a.midX, y: newCenter.y - a.midY)
        isFit = newZoom <= fitZoom + 0.0001
        relayout(animated: animated)
    }

    func zoomIn() { setZoom(zoom * 1.25, animated: true) }
    func zoomOut() { setZoom(zoom / 1.25, animated: true) }
    func zoomToActualSize(around point: CGPoint? = nil) { setZoom(1, around: point, animated: true) }

    func zoomToFit() {
        isFit = true
        relayout(animated: true)
    }

    func toggleFitAndActual(at point: CGPoint?) {
        if isFit && fitZoom < 1 { zoomToActualSize(around: point) } else { zoomToFit() }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        relayout(animated: false)
    }

    private func clampPan() {
        let d = displaySize, a = availRect
        let maxX = max(0, (d.width - a.width) / 2)
        let maxY = max(0, (d.height - a.height) / 2)
        pan.x = min(max(pan.x, -maxX), maxX)
        pan.y = min(max(pan.y, -maxY), maxY)
    }

    private func relayout(animated: Bool) {
        if isFit {
            zoom = fitZoom
            pan = .zero
        }
        clampPan()
        let ppp = zoom / backingScale
        let a = availRect
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(Self.easing)
        } else {
            CATransaction.setDisableActions(true)
        }
        imageLayer.bounds = CGRect(x: 0, y: 0, width: pixelSize.width * ppp, height: pixelSize.height * ppp)
        imageLayer.position = CGPoint(x: a.midX + pan.x, y: a.midY + pan.y)
        imageLayer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
        imageLayer.magnificationFilter = zoom >= 3 ? .nearest : .linear
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
        onViewChange?()
    }

    override func resetCursorRects() {
        if canPan { addCursorRect(imageLayer.frame.intersection(bounds), cursor: .openHand) }
    }

    // MARK: Events

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard canPan else { return }
        if !didDrag { NSCursor.closedHand.set() }
        didDrag = true
        pan.x += event.deltaX
        pan.y -= event.deltaY
        relayout(animated: false)
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            window?.invalidateCursorRects(for: self)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            toggleFitAndActual(at: p)
        } else if event.clickCount == 1 {
            onClick?(imageLayer.frame.contains(p))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Trackpads and the Magic Mouse send gesture phases. A precise event without any is
        // a wheel notch from a remote-desktop client such as Jump Desktop (60 points each).
        let isWheel = !event.hasPreciseScrollingDeltas || (event.phase.isEmpty && event.momentumPhase.isEmpty)
        if isWheel {
            // Mouse wheel zooms around the pointer, one fixed step per notch, like Picasa.
            let dy = event.scrollingDeltaY
            if dy != 0 { setZoom(zoom * (dy > 0 ? 1.2 : 1 / 1.2), around: p) }
            return
        }
        if event.modifierFlags.contains(.command) {
            setZoom(zoom * exp(event.scrollingDeltaY * 0.01), around: p)
        } else if canPan {
            pan.x += event.scrollingDeltaX
            pan.y -= event.scrollingDeltaY
            relayout(animated: false)
        } else if event.momentumPhase.isEmpty {
            // Two-finger horizontal swipe flips through photos when nothing is zoomed.
            if event.phase == .began { swipeAccum = 0; swipeFired = false }
            swipeAccum += event.scrollingDeltaX
            if !swipeFired && abs(swipeAccum) > 60 {
                swipeFired = true
                onSwipe?(swipeAccum < 0 ? 1 : -1)
            }
        }
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), around: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        toggleFitAndActual(at: convert(event.locationInWindow, from: nil))
    }
}
