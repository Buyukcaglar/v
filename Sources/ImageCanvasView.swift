import AppKit
import QuartzCore

/// Shows one image with zoom, pan and quarter-turn rotation, and ellipses drawn on it.
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
    /// An ellipse has been drawn.
    var onMark: ((Mark) -> Void)?

    /// Space kept free for the surrounding chrome when fitting the image.
    var reservedInsets = NSEdgeInsets() { didSet { relayout(animated: true) } }

    /// The ellipses on the photo.
    var marks: [Mark] = [] { didSet { updateMarkLayers() } }
    /// Dragging draws an ellipse instead of panning, unless Space is held.
    var isMarking = false {
        didSet {
            cancelMark()
            window?.invalidateCursorRects(for: self)
        }
    }
    var markColor = MarkColor.palette[0]
    /// In screen pixels.
    var markWidth: CGFloat = 3

    private let imageLayer = CALayer()
    /// Holds the marks over the photo, in its upright pixels scaled to the screen, and clips them to it.
    private let marksLayer = CALayer()
    private var markLayers: [CAShapeLayer] = []
    private let draftLayer = CAShapeLayer()
    /// The ellipse being drawn: the drag started at `dragStart` on the photo and is at
    /// `dragPoint` in the view.
    private var draft: Mark?
    private var dragStart: CGPoint?
    private var dragPoint: CGPoint?
    /// Upright size of the full photo, in pixels.
    private(set) var pixelSize: CGSize = .zero
    /// EXIF orientation of the pixels on the layer; the layer transform turns them upright.
    private var contentsOrientation = 1
    private var turns = 0
    private(set) var zoom: CGFloat = 1
    private(set) var isFit = true
    private var pan: CGPoint = .zero
    /// The next photo to arrive grows in (the viewer is opening).
    private var opening = false
    /// How small the photo is when it starts growing and when it finishes shrinking.
    private static let collapsedScale: CGFloat = 0.03

    private var didDrag = false
    /// Space is held: with the pen on, dragging pans the photo as it does without the pen.
    private var spaceHeld = false {
        didSet {
            // A drag under way keeps its cursor until it ends.
            if spaceHeld != oldValue, dragStart == nil, !grabbing { window?.invalidateCursorRects(for: self) }
        }
    }
    /// The drag under way pans the photo though the pen is on.
    private var grabbing = false
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
        marksLayer.masksToBounds = true
        draftLayer.fillColor = nil
        marksLayer.addSublayer(draftLayer)
        layer?.addSublayer(marksLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    // MARK: Content

    func setImage(_ image: DecodedImage?, pixelSize size: CGSize, rotation: Int) {
        cancelMark()
        pixelSize = size.width > 0 ? size : image?.uprightSize ?? .zero
        contentsOrientation = image?.orientation ?? 1
        turns = rotation
        isFit = true
        pan = .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image?.contents
        CATransaction.commit()
        relayout(animated: false)
        if image != nil { growIn() }
    }

    func replaceContents(_ image: DecodedImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if pixelSize.width == 0 || image.orientation != contentsOrientation {
            if pixelSize.width == 0 { pixelSize = image.uprightSize }
            contentsOrientation = image.orientation
            relayout(animated: false)
        }
        imageLayer.contents = image.contents
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
        marksLayer.setAffineTransform(marksLayer.affineTransform().scaledBy(x: Self.collapsedScale, y: Self.collapsedScale))
        CATransaction.commit()
    }

    private var collapsedBounds: CGRect {
        let b = imageLayer.bounds
        return CGRect(x: 0, y: 0, width: b.width * Self.collapsedScale, height: b.height * Self.collapsedScale)
    }

    /// Turns or mirrors pixels stored in EXIF orientation `orientation` upright, in the layer's
    /// y-up coordinates.
    nonisolated static func transform(forOrientation orientation: Int) -> CGAffineTransform {
        switch orientation {
        case 2: return CGAffineTransform(scaleX: -1, y: 1)
        case 3: return CGAffineTransform(rotationAngle: .pi)
        case 4: return CGAffineTransform(scaleX: 1, y: -1)
        case 5: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 0, ty: 0)  // transpose
        case 6: return CGAffineTransform(rotationAngle: -.pi / 2)
        case 7: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)  // transverse
        case 8: return CGAffineTransform(rotationAngle: .pi / 2)
        default: return .identity
        }
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

    /// Panning moves the photo under a cursor rect that stays put, so it leaves the cursor
    /// rects alone until it ends.
    private func relayout(animated: Bool, panning: Bool = false) {
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
        // The layer holds the pixels as stored; the transform turns them upright, then by the user's turns.
        let stored = contentsOrientation >= 5 ? CGSize(width: pixelSize.height, height: pixelSize.width) : pixelSize
        imageLayer.bounds = CGRect(x: 0, y: 0, width: stored.width * ppp, height: stored.height * ppp)
        imageLayer.position = CGPoint(x: a.midX + pan.x, y: a.midY + pan.y)
        imageLayer.setAffineTransform(Self.transform(forOrientation: contentsOrientation)
            .concatenating(CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2)))
        imageLayer.magnificationFilter = zoom >= 3 ? .nearest : .linear
        // The marks are in upright pixels whatever way the pixels on the layer are stored, so
        // they only take the user's turns.
        marksLayer.bounds = CGRect(x: 0, y: 0, width: pixelSize.width * ppp, height: pixelSize.height * ppp)
        marksLayer.position = imageLayer.position
        marksLayer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
        layoutMarks()
        CATransaction.commit()
        if !panning { window?.invalidateCursorRects(for: self) }
        onViewChange?()
    }

    /// The bars and their buttons lie over the canvas, in the space kept free for them, so the
    /// crosshair and the hand stay out of it and the arrow shows over the buttons.
    override func resetCursorRects() {
        let photo = imageLayer.frame.intersection(availRect)
        if isMarking && !spaceHeld {
            if hasContents { addCursorRect(photo, cursor: .crosshair) }
        } else if canPan {
            addCursorRect(photo, cursor: .openHand)
        }
    }

    // MARK: Marks

    private func updateMarkLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        markLayers.forEach { $0.removeFromSuperlayer() }
        markLayers = marks.map { _ in
            let shape = CAShapeLayer()
            shape.fillColor = nil
            marksLayer.insertSublayer(shape, below: draftLayer)
            return shape
        }
        layoutMarks()
        CATransaction.commit()
    }

    /// Sizes the marks for the zoom, in the transaction of the photo's layout so they move with it.
    private func layoutMarks() {
        let ppp = zoom / backingScale
        for (shape, mark) in zip(markLayers, marks) { place(mark, in: shape, ppp) }
        if let draft { place(draft, in: draftLayer, ppp) }
        draftLayer.isHidden = draft == nil
    }

    private func place(_ mark: Mark, in shape: CAShapeLayer, _ ppp: CGFloat) {
        shape.frame = marksLayer.bounds
        shape.path = CGPath(ellipseIn: mark.rect.applying(CGAffineTransform(scaleX: ppp, y: ppp)), transform: nil)
        shape.lineWidth = mark.lineWidth * ppp
        shape.strokeColor = mark.color.cgColor
    }

    /// Where `point` in the view falls on the photo, in its upright pixels.
    private func photoPoint(_ point: CGPoint) -> CGPoint {
        let p = marksLayer.convert(point, from: layer)
        let ppp = zoom / backingScale
        return CGPoint(x: p.x / ppp, y: p.y / ppp)
    }

    private func beginMark(at point: CGPoint) {
        guard hasContents, pixelSize.width > 0 else { return }
        dragStart = photoPoint(point)
    }

    /// The drag spans the ellipse's bounds; Shift makes it a circle and Option centres it on
    /// where the drag started.
    private func dragMark(to point: CGPoint, _ modifiers: NSEvent.ModifierFlags) {
        guard let start = dragStart else { return }
        dragPoint = point
        let end = photoPoint(point)
        var dx = end.x - start.x, dy = end.y - start.y
        if modifiers.contains(.shift) {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        let rect = modifiers.contains(.option)
            ? CGRect(x: start.x - abs(dx), y: start.y - abs(dy), width: 2 * abs(dx), height: 2 * abs(dy))
            : CGRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy), width: abs(dx), height: abs(dy))
        draft = Mark(rect: rect, color: markColor, lineWidth: markWidth / zoom)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutMarks()
        CATransaction.commit()
    }

    /// Keeps an ellipse that is big enough to be meant and touches the photo.
    private func endMark() {
        defer { cancelMark() }
        guard let mark = draft, max(mark.rect.width, mark.rect.height) * zoom >= 4,
              mark.rect.intersects(CGRect(origin: .zero, size: pixelSize)) else { return }
        onMark?(mark)
    }

    /// Drops the ellipse being drawn. Returns whether one was.
    @discardableResult
    func cancelMark() -> Bool {
        let wasDrawing = dragStart != nil
        dragStart = nil
        dragPoint = nil
        draft = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draftLayer.isHidden = true
        CATransaction.commit()
        return wasDrawing
    }

    // MARK: Events

    override func keyDown(with event: NSEvent) {
        // With the pen on, Space is held to pan instead of turning to the next photo.
        if isMarking, event.keyCode == 49 {
            spaceHeld = true
            return
        }
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false }
        super.keyUp(with: event)
    }

    /// Counts Space as let go of, for when its release goes to another window.
    func letGoOfSpace() { spaceHeld = false }

    override func flagsChanged(with event: NSEvent) {
        if let dragPoint { dragMark(to: dragPoint, event.modifierFlags) }
        super.flagsChanged(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        didDrag = false
        grabbing = isMarking && spaceHeld
        if isMarking && !grabbing { beginMark(at: convert(event.locationInWindow, from: nil)) }
    }

    override func mouseDragged(with event: NSEvent) {
        if isMarking && !grabbing {
            dragMark(to: convert(event.locationInWindow, from: nil), event.modifierFlags)
            return
        }
        guard canPan else { return }
        if !didDrag { NSCursor.closedHand.set() }
        didDrag = true
        pan.x += event.deltaX
        pan.y -= event.deltaY
        relayout(animated: false, panning: true)
    }

    override func mouseUp(with event: NSEvent) {
        if isMarking {
            // While drawing, clicks neither zoom nor close the viewer.
            if grabbing { grabbing = false } else { endMark() }
            // Space may have been pressed or let go of during the drag.
            window?.invalidateCursorRects(for: self)
            return
        }
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

    /// The view's menu opens only over the photo itself.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard hasContents, imageLayer.frame.contains(convert(event.locationInWindow, from: nil)) else { return nil }
        return super.menu(for: event)
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
            relayout(animated: false, panning: event.phase != .ended && event.momentumPhase != .ended)
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
