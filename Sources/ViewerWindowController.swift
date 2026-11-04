import AppKit
import UniformTypeIdentifiers

final class ViewerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A borderless button laid out by its frame. Symbols would otherwise stretch the frame by
/// their own outlines, so that neighbours overlap and steal each other's clicks.
private final class ToolButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}

/// Keeps clicks between the bar's buttons and thumbnails. Passed on, they would reach the
/// photo behind it, which closes the viewer on a click outside the photo.
private final class BarBackground: NSView {
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

/// A Picasa Photo Viewer style overlay: the desktop is dimmed, the photo floats in the
/// middle, and a filmstrip with the tools sits at the bottom.
final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    var onClose: (() -> Void)?

    private let backdrop = NSView()
    private let canvas = ImageCanvasView()
    private let filmstrip = FilmstripView()
    private let chrome = NSView()
    /// A dark band behind the filmstrip and the buttons, so that they stand out over a zoomed-in photo.
    private let chromeBackground = BarBackground()
    /// The band's top: over the filmstrip, or over the buttons alone while the filmstrip is hidden.
    private var backgroundTops: (strip: NSLayoutConstraint, tools: NSLayoutConstraint)!
    private let infoLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let toast = NSView()
    private let toastLabel = NSTextField(labelWithString: "")
    private var toastFade: DispatchWorkItem?
    private var closeButton: NSButton!
    private var penButton: NSButton!
    private var undoButton: NSButton!
    private var saveButton: NSButton!
    private var markupBar: MarkupBar!
    private var safeConstraints: [NSLayoutConstraint] = []  // top, bottom, leading, trailing
    private var isClosing = false
    private var closeCount = 0

    private var files: [URL] = []
    private var index = 0
    private var rotations: [URL: Int] = [:]
    /// Each photo's zoom and pan, kept until V quits. A fitted photo has none.
    private static var views: [URL: ImageCanvasView.ViewState] = [:]
    private var generation = 0
    private let pipeline: ImagePipeline
    private var infos: [URL: ImageInfo] = [:]
    private let infoQueue = DispatchQueue(label: "viewer.info", qos: .userInitiated)
    private let listQueue = DispatchQueue(label: "viewer.list", qos: .userInitiated)
    private var listing = 0
    /// The photo whose pixels (thumbnail or decoded) the canvas shows.
    private var canvasURL: URL?
    private var canvasShowsFull = false
    /// The current photo plays as an animation, so decoded stills stay off the canvas.
    private var isAnimating = false
    /// While a key is held, photos are decoded only where the user stops.
    private var lastNavigation: CFTimeInterval = 0
    private var pendingDecode: DispatchWorkItem?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private let thumbCache = NSCache<NSURL, CGImage>()
    private var thumbLoads: [URL: Operation] = [:]
    private let thumbQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .utility
        return q
    }()

    private var slideshowTimer: Timer?
    private var slideshowActivity: NSObjectProtocol?
    private var isSlideshow: Bool { slideshowTimer != nil }

    /// The ellipses drawn on one photo.
    private struct Markup {
        /// The photo's upright size in pixels, which the marks are drawn on.
        var size: CGSize
        var marks: [Mark] = []
        /// Marks taken back with Undo, the most recent last, for Redo.
        var undone: [Mark] = []
        /// The marks as they were last saved.
        var saved: [Mark] = []
        var isUnsaved: Bool { !marks.isEmpty && marks != saved }
    }

    /// The pen is on: dragging on the photo draws, and the colours replace the filmstrip.
    private var isMarking = false
    /// The filmstrip is hidden with ⌘F. It stays hidden, also the next time, until shown again.
    private var isFilmstripHidden = UserDefaults.standard.bool(forKey: ViewerWindowController.hideFilmstripKey)
    private static let hideFilmstripKey = "HideFilmstrip"
    /// Marks drawn on each photo while the viewer is open.
    private var markups: [URL: Markup] = [:]

    private static let chromeHeight: CGFloat = 118
    private static let topBarHeight: CGFloat = 44

    /// Starts decoding a single opened photo before building the window, so the two overlap.
    convenience init(opening urls: [URL]) {
        let pipeline = ImagePipeline()
        if urls.count == 1, let url = urls.first, !ImageLoader.isDirectory(url) {
            pipeline.keep([url])
            pipeline.loadScreen(url, box: Self.screenForNewWindow.map(Self.fitBox) ?? CGSize(width: 2560, height: 1600), first: true)
        }
        self.init(pipeline: pipeline)
    }

    init(pipeline: ImagePipeline? = nil) {
        self.pipeline = pipeline ?? ImagePipeline()
        // During a display change there can briefly be no screen; updateForScreen() catches up.
        let frame = Self.screenForNewWindow?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = ViewerWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        buildUI()
        updateForScreen()
        thumbCache.totalCostLimit = 8 << 20
        self.pipeline.onDecoded = { [weak self] in self?.decoded($0, $1, $2) }
        watchMemoryPressure()
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func buildUI() {
        let content = NSView()
        content.wantsLayer = true
        window!.contentView = content

        let safe = NSLayoutGuide()
        content.addLayoutGuide(safe)
        safeConstraints = [
            safe.topAnchor.constraint(equalTo: content.topAnchor),
            safe.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            safe.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            safe.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ]
        NSLayoutConstraint.activate(safeConstraints)

        // The dimming lives in its own view so it can fade on its own while the photo grows.
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(white: 0.03, alpha: 0.9).cgColor
        backdrop.frame = content.bounds
        backdrop.autoresizingMask = [.width, .height]
        content.addSubview(backdrop)

        canvas.frame = content.bounds
        canvas.autoresizingMask = [.width, .height]
        content.addSubview(canvas)
        canvas.onKeyDown = { [weak self] in self?.handleKey($0) ?? false }
        canvas.onClick = { [weak self] inside in self?.canvasClicked(insideImage: inside) }
        canvas.onSwipe = { [weak self] dir in self?.step(dir) }
        canvas.onViewChange = { [weak self] in
            guard let self else { return }
            if let url = self.canvasURL { Self.views[url] = self.canvas.viewState }
            self.updateZoomLabel()
            self.updateTiers()
        }
        canvas.onMark = { [weak self] in self?.addMark($0) }
        let imageMenu = NSMenu()
        imageMenu.addItem(withTitle: "Copy Image", action: #selector(copy(_:)), keyEquivalent: "").target = self
        imageMenu.addItem(withTitle: "Show in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "").target = self
        canvas.menu = imageMenu

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 3

        infoLabel.font = .systemFont(ofSize: 13, weight: .medium)
        infoLabel.textColor = NSColor(white: 1, alpha: 0.85)
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.shadow = shadow
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(infoLabel)

        closeButton = toolButton("xmark.circle.fill", "Close (Esc)", #selector(closeViewer(_:)), size: 22)
        closeButton.contentTintColor = NSColor(white: 1, alpha: 0.75)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(closeButton)

        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.textColor = NSColor(white: 1, alpha: 0.7)
        messageLabel.alignment = .center
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(messageLabel)

        toast.wantsLayer = true
        toast.layer?.backgroundColor = NSColor(white: 0.16, alpha: 0.92).cgColor
        toast.layer?.cornerRadius = 8
        toast.alphaValue = 0
        toast.translatesAutoresizingMaskIntoConstraints = false
        toastLabel.font = .systemFont(ofSize: 13, weight: .medium)
        toastLabel.textColor = .white
        toastLabel.lineBreakMode = .byTruncatingMiddle
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toast.addSubview(toastLabel)
        content.addSubview(toast)

        chrome.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(chrome)

        chromeBackground.wantsLayer = true
        chromeBackground.layer?.backgroundColor = NSColor(white: 0, alpha: 0.7).cgColor
        chromeBackground.layer?.cornerRadius = 10
        chromeBackground.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(chromeBackground)

        filmstrip.translatesAutoresizingMaskIntoConstraints = false
        filmstrip.thumbnail = { [weak self] in self?.thumbnail(at: $0) }
        filmstrip.onVisibleRange = { [weak self] in self?.loadThumbnails($0) }
        filmstrip.onSelect = { [weak self] in self?.go(to: $0) }
        chrome.addSubview(filmstrip)

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        zoomLabel.textColor = NSColor(white: 1, alpha: 0.7)
        zoomLabel.alignment = .right
        zoomLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        penButton = toolButton("pencil.tip.crop.circle", "Draw Circles (P)", #selector(toggleMarking(_:)))
        penButton.wantsLayer = true
        penButton.layer?.cornerRadius = 6
        undoButton = toolButton("arrow.uturn.backward", "Undo (⌘Z)", #selector(undoMark(_:)))
        saveButton = toolButton("square.and.arrow.down", "Save Marked Copy (⌘S)", #selector(saveMarkup(_:)))
        markupBar = MarkupBar(tools: [undoButton, saveButton])
        markupBar.onChange = { [weak self] in self?.penChanged() }
        markupBar.isHidden = true
        markupBar.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(markupBar)
        penChanged()
        showMarks()

        let tools = NSStackView(views: [
            toolButton("chevron.left", "Previous (←)", #selector(previousImage(_:))),
            toolButton("chevron.right", "Next (→)", #selector(nextImage(_:))),
            spacer(),
            toolButton("rotate.left", "Rotate Left (⌘L)", #selector(rotateLeft(_:))),
            toolButton("rotate.right", "Rotate Right (⌘R)", #selector(rotateRight(_:))),
            spacer(),
            toolButton("minus.magnifyingglass", "Zoom Out (−)", #selector(zoomOut(_:))),
            toolButton("arrow.down.right.and.arrow.up.left", "Zoom to Fit (⌘9)", #selector(zoomToFit(_:))),
            toolButton(Self.actualSizeImage, "Actual Size (⌘0)", #selector(actualSize(_:))),
            toolButton("plus.magnifyingglass", "Zoom In (+)", #selector(zoomIn(_:))),
            zoomLabel,
            spacer(),
            penButton,
            spacer(),
            toolButton("play.fill", "Slideshow (⇧⌘F)", #selector(toggleSlideshow(_:))),
            toolButton("doc.on.doc", "Copy Image (⌘C)", #selector(copy(_:))),
            toolButton("folder", "Show in Finder (⇧⌘R)", #selector(revealInFinder(_:))),
            toolButton("trash", "Move to Trash (⌘⌫)", #selector(moveToTrash(_:))),
        ])
        // The buttons' rectangles almost touch, so a click near an icon hits it.
        tools.spacing = 2
        tools.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(tools)

        NSLayoutConstraint.activate([
            infoLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 14),
            infoLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -20),
            closeButton.centerYAnchor.constraint(equalTo: infoLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),

            messageLabel.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: safe.centerYAnchor),

            toast.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            toast.centerYAnchor.constraint(equalTo: infoLabel.centerYAnchor),
            toastLabel.topAnchor.constraint(equalTo: toast.topAnchor, constant: 6),
            toastLabel.bottomAnchor.constraint(equalTo: toast.bottomAnchor, constant: -6),
            toastLabel.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 14),
            toastLabel.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -14),
            toastLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 560),

            chrome.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -16),
            chrome.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
            chrome.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -20),
            chrome.heightAnchor.constraint(equalToConstant: Self.chromeHeight),

            filmstrip.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 8),
            filmstrip.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            filmstrip.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            filmstrip.heightAnchor.constraint(equalToConstant: 64),

            markupBar.centerXAnchor.constraint(equalTo: chrome.centerXAnchor),
            markupBar.centerYAnchor.constraint(equalTo: filmstrip.centerYAnchor),

            tools.topAnchor.constraint(equalTo: filmstrip.bottomAnchor, constant: 4),
            tools.centerXAnchor.constraint(equalTo: chrome.centerXAnchor),
            tools.heightAnchor.constraint(equalToConstant: 34),

            chromeBackground.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            chromeBackground.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            chromeBackground.bottomAnchor.constraint(equalTo: chrome.bottomAnchor),
        ])
        backgroundTops = (chromeBackground.topAnchor.constraint(equalTo: chrome.topAnchor),
                          chromeBackground.topAnchor.constraint(equalTo: tools.topAnchor, constant: -8))
        updateStrip()
    }

    private func toolButton(_ symbol: String, _ tip: String, _ action: Selector, size: CGFloat = 16) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        return toolButton(image, tip, action)
    }

    /// A button that takes clicks anywhere in a rectangle around its icon, not just on the icon.
    private func toolButton(_ image: NSImage?, _ tip: String, _ action: Selector) -> NSButton {
        let button = image.map { ToolButton(image: $0, target: self, action: action) } ?? ToolButton(title: tip, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .white
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    /// "1:1" as a template image, for Actual Size.
    private static let actualSizeImage: NSImage = {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "1:1", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]))
        let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).integral
        let image = NSImage(size: glyphs.size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.textPosition = CGPoint(x: -glyphs.minX, y: -glyphs.minY)
            CTLineDraw(line, ctx)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Actual Size"
        return image
    }()

    private func spacer() -> NSView {
        let v = NSView()
        v.widthAnchor.constraint(equalToConstant: 14).isActive = true
        return v
    }

    /// The screen with the pointer, where the viewer opens.
    private static var screenForNewWindow: NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }

    private var screenInsets: NSEdgeInsets {
        guard let screen = window?.screen ?? NSScreen.main else { return NSEdgeInsets() }
        return Self.insets(of: screen)
    }

    private static func insets(of screen: NSScreen) -> NSEdgeInsets {
        let f = screen.frame, v = screen.visibleFrame
        return NSEdgeInsets(top: f.maxY - v.maxY, left: v.minX - f.minX, bottom: v.minY - f.minY, right: f.maxX - v.maxX)
    }

    /// Space the photo leaves free for the chrome, the menu bar and the Dock.
    private static func canvasInsets(_ i: NSEdgeInsets, slideshow: Bool) -> NSEdgeInsets {
        let chromeSpace: CGFloat = slideshow ? 0 : chromeHeight + 24
        let topSpace: CGFloat = slideshow ? 0 : topBarHeight
        return NSEdgeInsets(top: i.top + topSpace, left: i.left + 10, bottom: i.bottom + chromeSpace, right: i.right + 10)
    }

    /// The canvas's `fitBox` on `screen`, before there is a canvas.
    private static func fitBox(on screen: NSScreen) -> CGSize {
        let i = canvasInsets(insets(of: screen), slideshow: false), scale = screen.backingScaleFactor
        return CGSize(width: max(screen.frame.width - i.left - i.right, 1) * scale,
                      height: max(screen.frame.height - i.top - i.bottom, 1) * scale)
    }

    private func updateForScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(screen.frame, display: true)
        let i = screenInsets
        safeConstraints[0].constant = i.top
        safeConstraints[1].constant = -i.bottom
        safeConstraints[2].constant = i.left
        safeConstraints[3].constant = -i.right
        updateCanvasInsets()
    }

    private func updateCanvasInsets() {
        canvas.reservedInsets = Self.canvasInsets(screenInsets, slideshow: isSlideshow)
    }

    @objc private func screenParametersChanged(_ note: Notification) { updateForScreen() }

    // MARK: Showing files

    /// Shows a single photo at once and lists its folder in the background; folders and
    /// several items appear once they are listed.
    func show(urls: [URL]) {
        if isClosing { cancelClose() }
        listing += 1
        let token = listing
        if urls.count == 1, let file = urls.first, !ImageLoader.isDirectory(file) {
            open([file], at: 0)
            listQueue.async { [weak self] in
                let (list, start) = ImageLoader.siblings(of: file)
                DispatchQueue.main.async {
                    guard let self, self.listing == token, self.files == [file], list.count > 1 else { return }
                    self.folderListed(list, at: start)
                }
            }
        } else {
            listQueue.async { [weak self] in
                let (list, start) = ImageLoader.browseList(for: urls)
                DispatchQueue.main.async {
                    guard let self, self.listing == token else { return }
                    self.open(list, at: start)
                }
            }
        }
    }

    /// Puts the photo already on screen in its place among its folder's photos.
    private func folderListed(_ list: [URL], at start: Int) {
        files = list
        index = start
        filmstrip.urls = list
        filmstrip.current = start
        updateInfoLabel(currentInfo)
        pipeline.keep([list[start]] + neighborURLs)
        if pipeline.images[list[start]] != nil || isAnimating { preloadNeighbors() }
    }

    private func open(_ list: [URL], at start: Int) {
        guard !list.isEmpty else {
            NSSound.beep()
            if !(window?.isVisible ?? false) { closeViewer(nil) }
            return
        }
        files = list
        thumbQueue.cancelAllOperations()
        thumbLoads.removeAll()
        filmstrip.urls = files
        filmstrip.resetPopIn()
        index = start

        if let window, !window.isVisible {
            // The desktop dims at once and the photo grows out of the middle of the screen as
            // soon as its first pixels (thumbnail or full image) are ready.
            isClosing = false
            for v in fadingViews { v.alphaValue = 0 }
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup {
                $0.duration = 0.25
                $0.timingFunction = ImageCanvasView.openEasing
                for v in fadingViews { v.animator().alphaValue = 1 }
            }
            canvas.playOpen()
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
        window?.makeFirstResponder(canvas)
        display()
    }

    private var fadingViews: [NSView] { [backdrop, chrome, infoLabel, closeButton] }

    private var currentURL: URL? { files.indices.contains(index) ? files[index] : nil }
    private var currentInfo: ImageInfo? { currentURL.flatMap { infos[$0] } }

    private func display() {
        guard let url = currentURL else { return }
        generation += 1
        isAnimating = false
        let gen = generation

        window?.title = url.lastPathComponent
        filmstrip.current = index
        messageLabel.isHidden = true
        pipeline.keep([url] + neighborURLs)
        infos = infos.filter { $0.key == url || neighborURLs.contains($0.key) }
        pendingDecode?.cancel()
        let now = CACurrentMediaTime()
        let isKeyRepeat = now - lastNavigation < 0.12
        lastNavigation = now
        // The decode needs only the space on screen, so it need not wait for the info.
        if !isKeyRepeat { pipeline.loadScreen(url, box: fitBox(for: url), first: true) }

        if let info = infos[url] {
            display(url, info, isKeyRepeat: isKeyRepeat)
            return
        }
        updateInfoLabel(nil)
        infoQueue.async { [weak self] in
            let info = ImageLoader.info(url)
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                if let info { self.infos[url] = info }
                self.display(url, info, isKeyRepeat: isKeyRepeat)
            }
        }
    }

    private func display(_ url: URL, _ info: ImageInfo?, isKeyRepeat: Bool) {
        let gen = generation
        updateInfoLabel(info)
        guard let info else {
            showFailure(url)
            loadAround(url, decode: false, after: isKeyRepeat)
            return
        }

        if info.isAnimatable {
            setCanvas(thumbCache.object(forKey: url as NSURL).map { DecodedImage($0) }, of: url)
            let status = CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak self] _, frame, stop in
                guard let self, self.generation == gen, self.window?.isVisible == true else {
                    stop.pointee = true
                    return
                }
                self.canvas.replaceContents(DecodedImage(frame))
            }
            if status == noErr {
                isAnimating = true
                loadAround(url, decode: false, after: isKeyRepeat)
                return
            }
        }

        if let image = pipeline.images[url] {
            show(image, of: url)
        } else if let thumb = thumbCache.object(forKey: url as NSURL) {
            // Show the thumbnail while decoding; without one, keep the previous photo up until
            // the full image is ready.
            setCanvas(DecodedImage(thumb), of: url)
        }
        loadAround(url, decode: true, after: isKeyRepeat)
    }

    /// Decodes the current photo, or once it is ready its neighbours. While a key is held this
    /// waits until the user stops.
    private func loadAround(_ url: URL, decode: Bool, after isKeyRepeat: Bool) {
        let load = { [weak self] in
            guard let self else { return }
            if decode && self.pipeline.images[url] == nil {
                self.pipeline.loadScreen(url, box: self.fitBox(for: url), first: true)
            } else {
                self.preloadNeighbors()
            }
        }
        if isKeyRepeat {
            let work = DispatchWorkItem(block: load)
            pendingDecode = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            load()
        }
    }

    private func decoded(_ url: URL, _ tier: ImagePipeline.Tier, _ image: DecodedImage?) {
        // Until the info arrives the canvas can't size the photo; display() shows it then.
        guard url == currentURL, currentInfo != nil, !isAnimating else { return }
        switch tier {
        case .screen:
            if let image {
                show(image, of: url)
                updateTiers()
            } else if canvasURL != url || !canvas.hasContents {
                showFailure(url)
            }
            preloadNeighbors()
        case .full:
            updateTiers()
        }
    }

    /// Shows the decoded photo, in place of its thumbnail if that is up.
    private func show(_ image: DecodedImage, of url: URL) {
        if canvasURL == url {
            canvas.replaceContents(image)
            canvasShowsFull = false
        } else {
            setCanvas(image, of: url)
        }
    }

    private func setCanvas(_ image: DecodedImage?, of url: URL?) {
        let info = url == currentURL ? currentInfo : nil
        // Set first: laying the photo out reports its view, which is kept under `canvasURL` and,
        // when the photo comes back zoomed in, loads the sharper image it needs.
        canvasURL = url
        canvasShowsFull = false
        canvas.setImage(image, pixelSize: info?.pixelSize ?? .zero, rotation: url.flatMap { rotations[$0] } ?? 0,
                        view: url.flatMap { Self.views[$0] })
        showMarks()
    }

    private func showFailure(_ url: URL) {
        setCanvas(nil, of: nil)
        showMessage("Can’t open “\(url.lastPathComponent)”.")
    }

    /// Where `url` goes on screen, in device pixels, with its rotation taken into account.
    private func fitBox(for url: URL) -> CGSize {
        let box = canvas.fitBox
        return (rotations[url] ?? 0) % 2 == 0 ? box : CGSize(width: box.height, height: box.width)
    }

    /// Keeps the current photo sharp: a bigger screen image when the space for it grows, and the
    /// full-resolution one only while zoomed in past the screen image.
    private func updateTiers() {
        guard let url = currentURL, canvasURL == url, let info = currentInfo, !isAnimating,
              let screen = pipeline.images[url] else { return }
        let fullLong = min(max(info.pixelSize.width, info.pixelSize.height), CGFloat(ImageLoader.maxDecodedSide))
        let screenLong = CGFloat(max(screen.width, screen.height))
        let needed = ImageLoader.neededLongSide(info.pixelSize, box: fitBox(for: url))
        if Int(screenLong) < needed - 1 {
            pipeline.loadScreen(url, box: fitBox(for: url), minLongSide: needed - 1, first: true)
        }
        if screenLong < fullLong, canvas.zoom > screenLong / fullLong + 0.001 {
            if let full = pipeline.full, full.url == url {
                if !canvasShowsFull {
                    canvas.replaceContents(full.image)
                    canvasShowsFull = true
                }
            } else {
                pipeline.loadFull(url)
            }
        } else if pipeline.full != nil || canvasShowsFull {
            if canvasShowsFull { canvas.replaceContents(screen) }
            canvasShowsFull = false
            pipeline.dropFull()
        }
    }

    private var neighborURLs: [URL] {
        guard files.count > 1 else { return [] }
        return [1, -1].map { files[(index + $0 + files.count) % files.count] }
    }

    private func preloadNeighbors() {
        for url in neighborURLs { pipeline.loadScreen(url, box: fitBox(for: url), first: false) }
    }

    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if self.canvasShowsFull, let url = self.currentURL, let screen = self.pipeline.images[url] {
                self.canvas.replaceContents(screen)
                self.canvasShowsFull = false
            }
            self.pipeline.dropFull()
            self.pipeline.keep([self.currentURL].compactMap { $0 })
            if source.data.contains(.critical) {
                self.thumbCache.removeAllObjects()
                self.thumbQueue.cancelAllOperations()
                self.thumbLoads.removeAll()
            }
        }
        source.resume()
        memoryPressure = source
    }

    private func thumbnail(at i: Int) -> CGImage? {
        files.indices.contains(i) ? thumbCache.object(forKey: files[i] as NSURL) : nil
    }

    /// Loads the thumbnails for the filmstrip's slots, nearest the current photo first, and
    /// drops queued ones that scrolled out of view.
    private func loadThumbnails(_ range: Range<Int>) {
        guard range.lowerBound >= 0, range.upperBound <= files.count else { return }
        let visible = Set(files[range])
        for (url, op) in thumbLoads where !visible.contains(url) {
            op.cancel()
            thumbLoads[url] = nil
        }
        let side = Int(FilmstripView.thumbnailSide * (window?.backingScaleFactor ?? 2))
        for i in range where thumbCache.object(forKey: files[i] as NSURL) == nil {
            let url = files[i]
            let distance = abs(i - index)
            let priority: Operation.QueuePriority = distance == 0 ? .veryHigh : distance <= 3 ? .high : .normal
            if let op = thumbLoads[url] {
                op.queuePriority = priority
                continue
            }
            let op = BlockOperation()
            op.addExecutionBlock { [weak self, weak op] in
                guard let op, !op.isCancelled else { return }
                let thumb = ImageLoader.thumbnail(url, maxPixel: side)
                DispatchQueue.main.async { self?.thumbnailLoaded(url, thumb, op) }
            }
            op.queuePriority = priority
            thumbLoads[url] = op
            thumbQueue.addOperation(op)
        }
    }

    private func thumbnailLoaded(_ url: URL, _ thumb: CGImage?, _ op: Operation) {
        if thumbLoads[url] === op { thumbLoads[url] = nil }
        guard let thumb else { return }
        thumbCache.setObject(thumb, forKey: url as NSURL, cost: thumb.bytesPerRow * thumb.height)
        filmstrip.thumbnailsChanged()
        if url == currentURL, canvasURL != url, currentInfo != nil { setCanvas(DecodedImage(thumb), of: url) }
    }

    private func showMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = false
    }

    private func updateInfoLabel(_ info: ImageInfo?) {
        guard let url = currentURL else { return }
        var parts = [url.lastPathComponent, "\(index + 1) of \(files.count)"]
        if let info, info.pixelSize.width > 0 {
            var size = info.pixelSize
            if (rotations[url] ?? 0) % 2 == 1 { size = CGSize(width: size.height, height: size.width) }
            parts.append("\(Int(size.width)) × \(Int(size.height))")
        }
        if let bytes = info?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        infoLabel.stringValue = parts.joined(separator: "     ")
    }

    private func updateZoomLabel() {
        let text = "\(Int((canvas.zoom * 100).rounded()))%"
        if zoomLabel.stringValue != text { zoomLabel.stringValue = text }
    }

    // MARK: Navigation

    func go(to i: Int) {
        guard !files.isEmpty else { return }
        index = (i % files.count + files.count) % files.count
        display()
    }

    private func step(_ delta: Int) {
        go(to: index + delta)
        if isSlideshow { restartSlideshowTimer() }
    }

    @objc func nextImage(_ sender: Any?) { step(1) }
    @objc func previousImage(_ sender: Any?) { step(-1) }
    @objc func firstImage(_ sender: Any?) { go(to: 0) }
    @objc func lastImage(_ sender: Any?) { go(to: files.count - 1) }

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        // Ctrl-S and Ctrl-F work as ⌘S and ⌘F do, for keyboards and remote-desktop clients that
        // send Ctrl as it is.
        if mods == .control {
            switch event.charactersIgnoringModifiers {
            case "s": saveMarkup(nil)
            case "f": toggleFilmstrip(nil)
            default: return false
            }
            return true
        }
        guard mods.isEmpty else { return false }
        if let key = event.specialKey {
            switch key {
            case .rightArrow, .downArrow, .pageDown: step(1)
            case .leftArrow, .upArrow, .pageUp: step(-1)
            case .home: go(to: 0)
            case .end: go(to: files.count - 1)
            case .carriageReturn, .enter: canvas.zoomToFit()  // Return or Enter: as the photo first opens
            default: return false
            }
            return true
        }
        switch event.keyCode {
        case 53:  // Esc: drops the ellipse being drawn, then puts the pen away, then closes
            if canvas.cancelMark() {
            } else if isMarking {
                setMarking(false)
            } else if isSlideshow {
                stopSlideshow()
            } else {
                closeViewer(nil)
            }
            return true
        case 49:  // Space; with the pen on, the canvas keeps it for panning
            step(event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        default:
            break
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=": canvas.zoomIn()
        case "-", "_": canvas.zoomOut()
        case "0", "1": canvas.zoomToActualSize()  // as ⌘0
        case "9": canvas.zoomToFit()  // as ⌘9
        case "p", "P": toggleMarking(nil)
        default: return false
        }
        return true
    }

    private func canvasClicked(insideImage: Bool) {
        if isSlideshow {
            stopSlideshow()
        } else if !insideImage {
            // Clicking the dimmed background closes the viewer, as in Picasa.
            closeViewer(nil)
        }
    }

    // MARK: Actions

    @objc func rotateLeft(_ sender: Any?) { rotate(-1) }
    @objc func rotateRight(_ sender: Any?) { rotate(1) }

    private func rotate(_ delta: Int) {
        guard let url = currentURL else { return }
        rotations[url] = (((rotations[url] ?? 0) + delta) % 4 + 4) % 4
        canvas.rotate(by: delta)
        updateInfoLabel(currentInfo)
    }

    @objc func zoomIn(_ sender: Any?) { canvas.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { canvas.zoomOut() }
    @objc func zoomToFit(_ sender: Any?) { canvas.zoomToFit() }
    @objc func actualSize(_ sender: Any?) { canvas.zoomToActualSize() }

    /// Hides or shows the filmstrip. The photo keeps its place either way.
    @objc func toggleFilmstrip(_ sender: Any?) {
        isFilmstripHidden.toggle()
        UserDefaults.standard.set(isFilmstripHidden, forKey: Self.hideFilmstripKey)
        updateStrip()
    }

    /// The filmstrip shows unless it is hidden or the pen's colours have its place. The band
    /// behind the bar shrinks to the buttons while neither shows.
    private func updateStrip() {
        filmstrip.isHidden = isMarking || isFilmstripHidden
        markupBar.isHidden = !isMarking
        let (on, off) = isMarking || !isFilmstripHidden
            ? (backgroundTops.strip, backgroundTops.tools) : (backgroundTops.tools, backgroundTops.strip)
        off.isActive = false
        on.isActive = true
    }

    // MARK: Drawing

    @objc func toggleMarking(_ sender: Any?) { setMarking(!isMarking) }

    private func setMarking(_ on: Bool) {
        guard on != isMarking, currentURL != nil || !on else { return }
        if on, isSlideshow { stopSlideshow() }
        isMarking = on
        canvas.isMarking = on
        updateStrip()
        penButton.layer?.backgroundColor = on ? NSColor(white: 1, alpha: 0.22).cgColor : nil
    }

    private func penChanged() {
        canvas.markColor = markupBar.color
        canvas.markWidth = CGFloat(markupBar.width.rawValue)
    }

    /// The ellipse goes on the photo it was drawn on.
    private func addMark(_ mark: Mark) {
        guard let url = canvasURL else { return }
        markups[url, default: Markup(size: canvas.pixelSize)].marks.append(mark)
        markups[url]?.undone.removeAll()
        showMarks()
    }

    /// Shows the marks of the photo on the canvas.
    private func showMarks() {
        let marks = canvasURL.flatMap { markups[$0]?.marks } ?? []
        canvas.marks = marks
        undoButton.isEnabled = !marks.isEmpty
        saveButton.isEnabled = !marks.isEmpty
    }

    @objc func undoMark(_ sender: Any?) {
        guard let url = currentURL, let mark = markups[url]?.marks.popLast() else { return }
        markups[url]?.undone.append(mark)
        showMarks()
    }

    @objc func redoMark(_ sender: Any?) {
        guard let url = currentURL, let mark = markups[url]?.undone.popLast() else { return }
        markups[url]?.marks.append(mark)
        showMarks()
    }

    /// Saves a copy of the photo with its marks drawn in next to it, as "Name_marked.ext".
    @objc func saveMarkup(_ sender: Any?) {
        guard let url = currentURL, let markup = markups[url], !markup.marks.isEmpty else {
            NSSound.beep()
            return
        }
        save(markup, of: url)
    }

    private func save(_ markup: Markup, of url: URL) {
        showToast("Saving…")
        let marks = markup.marks
        MarkupWriter.save(marks, on: url, markedSize: markup.size, turns: rotations[url] ?? 0) { [weak self] result in
            switch result {
            case .success(let copy):
                self?.saved(marks, of: url, to: copy)
            case .failure(let error):
                self?.toast.alphaValue = 0
                NSAlert(error: error).runModal()
            }
        }
    }

    /// The copy shows up in the filmstrip next to its photo, where Finder sorts it.
    private func saved(_ marks: [Mark], of url: URL, to copy: URL) {
        markups[url]?.saved = marks
        showToast("Saved “\(copy.lastPathComponent)”")
        if files.contains(copy) {
            // It replaced an earlier copy: let go of what is cached of that one.
            thumbCache.removeObject(forKey: copy as NSURL)
            thumbLoads.removeValue(forKey: copy)?.cancel()
            infos[copy] = nil
            pipeline.forget(copy)
            filmstrip.thumbnailsChanged()
            if copy == currentURL { display() } else if neighborURLs.contains(copy) { preloadNeighbors() }
        } else if let i = files.firstIndex(of: url) {
            // "IMG_1234_marked.JPG" sorts just before "IMG_1234.JPG".
            let at = copy.lastPathComponent.localizedStandardCompare(url.lastPathComponent) == .orderedAscending ? i : i + 1
            files.insert(copy, at: at)
            if index >= at { index += 1 }
            filmstrip.urls = files
            filmstrip.current = index
            updateInfoLabel(currentInfo)
            pipeline.keep([files[index]] + neighborURLs)
            preloadNeighbors()
        }
    }

    /// Offers to save the marks that aren't saved yet. Returns false if the user cancels.
    func confirmUnsavedMarks() -> Bool {
        let unsaved = markups.filter { $0.value.isUnsaved }
        guard let first = unsaved.first else { return true }
        let alert = NSAlert()
        alert.messageText = unsaved.count == 1
            ? "Do you want to save the marks on “\(first.key.lastPathComponent)”?"
            : "Do you want to save the marks on \(unsaved.count) photos?"
        alert.informativeText = "A copy with the marks is saved next to each photo, with “_marked” added to its name. If you don’t save, your marks will be lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for (url, markup) in unsaved { save(markup, of: url) }
            return true
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    /// Shows `text` at the top of the screen for a moment.
    private func showToast(_ text: String) {
        toastLabel.stringValue = text
        toastFade?.cancel()
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.15
            toast.animator().alphaValue = 1
        }
        let fade = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup {
                $0.duration = 0.5
                self?.toast.animator().alphaValue = 0
            }
        }
        toastFade = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: fade)
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Puts the file on the pasteboard at once; its bytes, in their own format, are read only
    /// when an app pastes them.
    @objc func copy(_ sender: Any?) {
        guard let url = currentURL else { return }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
            let provider = FileDataProvider(url: url)
            item.setDataProvider(provider, forTypes: [NSPasteboard.PasteboardType(type.identifier)])
            FileDataProvider.current = provider
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard let url = currentURL else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        files.remove(at: index)
        thumbCache.removeObject(forKey: url as NSURL)
        rotations[url] = nil
        Self.views[url] = nil
        markups[url] = nil
        if files.isEmpty {
            closeViewer(nil)
            return
        }
        filmstrip.urls = files
        go(to: min(index, files.count - 1))
    }

    @objc func toggleSlideshow(_ sender: Any?) {
        if isSlideshow { stopSlideshow() } else { startSlideshow() }
    }

    private func startSlideshow() {
        guard files.count > 1 else { return }
        setMarking(false)
        restartSlideshowTimer()
        slideshowActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Slideshow")
        setChromeHidden(true)
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func restartSlideshowTimer() {
        slideshowTimer?.invalidate()
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.go(to: self.index + 1)
            }
        }
        slideshowTimer?.tolerance = 0.1
    }

    private func stopSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        endSlideshowActivity()
        setChromeHidden(false)
    }

    private func endSlideshowActivity() {
        if let slideshowActivity { ProcessInfo.processInfo.endActivity(slideshowActivity) }
        slideshowActivity = nil
    }

    private func setChromeHidden(_ hidden: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = ImageCanvasView.easing
            for v in [chrome, infoLabel, closeButton!] as [NSView] { v.animator().alphaValue = hidden ? 0 : 1 }
        }
        updateCanvasInsets()
    }

    @objc func closeViewer(_ sender: Any?) {
        guard !isClosing, confirmUnsavedMarks() else { return }
        isClosing = true
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        endSlideshowActivity()
        generation += 1
        guard let window, window.isVisible else {
            self.window?.close()
            return
        }
        // The photo shrinks back into the middle while the dimming lifts.
        closeCount += 1
        let close = closeCount
        canvas.playClose()
        NSAnimationContext.runAnimationGroup({
            $0.duration = ImageCanvasView.closeDuration
            $0.timingFunction = ImageCanvasView.closeEasing
            for v in fadingViews { v.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.closeCount == close, self?.isClosing == true { window.close() }
            }
        })
    }

    /// A photo opened while the viewer is closing keeps it open; it grows in like on opening.
    private func cancelClose() {
        isClosing = false
        closeCount += 1
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.25
            $0.timingFunction = ImageCanvasView.openEasing
            for v in fadingViews { v.animator().alphaValue = 1 }
        }
        canvas.playOpen()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Space let go of in another window never reaches the canvas.
        canvas.letGoOfSpace()
    }

    func windowWillClose(_ notification: Notification) {
        thumbQueue.cancelAllOperations()
        memoryPressure?.cancel()
        NotificationCenter.default.removeObserver(self)
        onClose?()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSlideshow(_:)):
            item.title = isSlideshow ? "Stop Slideshow" : "Start Slideshow"
            return files.count > 1
        case #selector(nextImage(_:)), #selector(previousImage(_:)), #selector(firstImage(_:)), #selector(lastImage(_:)):
            return files.count > 1
        case #selector(toggleFilmstrip(_:)):
            item.title = isFilmstripHidden ? "Show Filmstrip" : "Hide Filmstrip"
            return true
        case #selector(toggleMarking(_:)):
            item.state = isMarking ? .on : .off
            return currentURL != nil
        case #selector(saveMarkup(_:)), #selector(undoMark(_:)):
            return currentURL.flatMap { markups[$0] }?.marks.isEmpty == false
        case #selector(redoMark(_:)):
            return currentURL.flatMap { markups[$0] }?.undone.isEmpty == false
        default:
            return currentURL != nil || item.action == #selector(closeViewer(_:))
        }
    }
}

/// Supplies a copied file's bytes when they are pasted.
private final class FileDataProvider: NSObject, NSPasteboardItemDataProvider {
    /// Held until the pasteboard is done with it, which can be after the viewer has closed.
    nonisolated(unsafe) static var current: FileDataProvider?
    let url: URL

    init(url: URL) { self.url = url }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) { item.setData(data, forType: type) }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        if Self.current === self { Self.current = nil }
    }
}
