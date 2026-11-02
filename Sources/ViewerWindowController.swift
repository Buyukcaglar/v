import AppKit
import UniformTypeIdentifiers

final class ViewerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A Picasa Photo Viewer style overlay: the desktop is dimmed, the photo floats in the
/// middle, and a filmstrip with the tools sits at the bottom.
final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    var onClose: (() -> Void)?

    private let backdrop = NSView()
    private let canvas = ImageCanvasView()
    private let filmstrip = FilmstripView()
    private let chrome = NSView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private var closeButton: NSButton!
    private var safeConstraints: [NSLayoutConstraint] = []  // top, bottom, leading, trailing
    private var isClosing = false

    private var files: [URL] = []
    private var index = 0
    private var rotations: [URL: Int] = [:]
    private var generation = 0
    private var fullCache: [URL: CGImage] = [:]
    private let thumbCache = NSCache<NSURL, CGImage>()
    private var thumbsLoading = Set<URL>()
    private let loadQueue = DispatchQueue(label: "viewer.load", qos: .userInitiated, attributes: .concurrent)
    private let thumbQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .utility
        return q
    }()

    private var slideshowTimer: Timer?
    private var isSlideshow: Bool { slideshowTimer != nil }

    private static let chromeHeight: CGFloat = 118
    private static let topBarHeight: CGFloat = 44

    init() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let window = ViewerWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
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
        thumbCache.countLimit = 600
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
        canvas.onViewChange = { [weak self] in self?.updateZoomLabel() }

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

        chrome.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(chrome)

        filmstrip.translatesAutoresizingMaskIntoConstraints = false
        filmstrip.thumbnail = { [weak self] in self?.thumbnail(at: $0) }
        filmstrip.onSelect = { [weak self] in self?.go(to: $0) }
        chrome.addSubview(filmstrip)

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        zoomLabel.textColor = NSColor(white: 1, alpha: 0.7)
        zoomLabel.alignment = .right
        zoomLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let tools = NSStackView(views: [
            toolButton("chevron.left", "Previous (←)", #selector(previousImage(_:))),
            toolButton("chevron.right", "Next (→)", #selector(nextImage(_:))),
            spacer(),
            toolButton("rotate.left", "Rotate Left (⌘L)", #selector(rotateLeft(_:))),
            toolButton("rotate.right", "Rotate Right (⌘R)", #selector(rotateRight(_:))),
            spacer(),
            toolButton("minus.magnifyingglass", "Zoom Out (−)", #selector(zoomOut(_:))),
            toolButton("arrow.down.right.and.arrow.up.left", "Zoom to Fit (⌘9)", #selector(zoomToFit(_:))),
            toolButton("1.magnifyingglass", "Actual Size (⌘0)", #selector(actualSize(_:))),
            toolButton("plus.magnifyingglass", "Zoom In (+)", #selector(zoomIn(_:))),
            zoomLabel,
            spacer(),
            toolButton("play.fill", "Slideshow (⇧⌘F)", #selector(toggleSlideshow(_:))),
            toolButton("folder", "Show in Finder (⇧⌘R)", #selector(revealInFinder(_:))),
            toolButton("trash", "Move to Trash (⌘⌫)", #selector(moveToTrash(_:))),
        ])
        tools.spacing = 4
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

            chrome.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -16),
            chrome.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
            chrome.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -20),
            chrome.heightAnchor.constraint(equalToConstant: Self.chromeHeight),

            filmstrip.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 8),
            filmstrip.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            filmstrip.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            filmstrip.heightAnchor.constraint(equalToConstant: 64),

            tools.topAnchor.constraint(equalTo: filmstrip.bottomAnchor, constant: 4),
            tools.centerXAnchor.constraint(equalTo: chrome.centerXAnchor),
            tools.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    private func toolButton(_ symbol: String, _ tip: String, _ action: Selector, size: CGFloat = 16) -> NSButton {
        let button: NSButton
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular)) {
            button = NSButton(image: image, target: self, action: action)
        } else {
            button = NSButton(title: tip, target: self, action: action)
        }
        button.isBordered = false
        button.contentTintColor = .white
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: size + 18).isActive = true
        return button
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.widthAnchor.constraint(equalToConstant: 14).isActive = true
        return v
    }

    private var screenInsets: NSEdgeInsets {
        guard let screen = window?.screen ?? NSScreen.main else { return NSEdgeInsets() }
        let f = screen.frame, v = screen.visibleFrame
        return NSEdgeInsets(top: f.maxY - v.maxY, left: v.minX - f.minX, bottom: v.minY - f.minY, right: f.maxX - v.maxX)
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
        let i = screenInsets
        let chromeSpace: CGFloat = isSlideshow ? 0 : Self.chromeHeight + 24
        let topSpace: CGFloat = isSlideshow ? 0 : Self.topBarHeight
        canvas.reservedInsets = NSEdgeInsets(top: i.top + topSpace, left: i.left + 10,
                                             bottom: i.bottom + chromeSpace, right: i.right + 10)
    }

    @objc private func screenParametersChanged(_ note: Notification) { updateForScreen() }

    // MARK: Showing files

    func show(urls: [URL]) {
        let (list, start) = ImageLoader.browseList(for: urls)
        guard !list.isEmpty else {
            NSSound.beep()
            if !(window?.isVisible ?? false) { closeViewer(nil) }
            return
        }
        files = list
        fullCache.removeAll()
        thumbQueue.cancelAllOperations()
        thumbsLoading.removeAll()
        filmstrip.count = files.count
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

    private func display() {
        guard let url = currentURL else { return }
        generation += 1
        let gen = generation
        thumbQueue.cancelAllOperations()
        thumbsLoading.removeAll()

        let info = ImageLoader.info(url)
        window?.title = url.lastPathComponent
        filmstrip.current = index
        messageLabel.isHidden = true
        updateInfoLabel(info)

        guard let info else {
            canvas.setImage(nil, pixelSize: .zero, rotation: 0)
            showMessage("Can’t open “\(url.lastPathComponent)”.")
            return
        }

        let rotation = rotations[url] ?? 0
        if info.isAnimatable {
            canvas.setImage(thumbCache.object(forKey: url as NSURL), pixelSize: info.pixelSize, rotation: rotation)
            let status = CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak self] _, frame, stop in
                guard let self, self.generation == gen, self.window?.isVisible == true else {
                    stop.pointee = true
                    return
                }
                self.canvas.replaceContents(frame)
            }
            if status == noErr { return }
        }

        if let full = fullCache[url] {
            canvas.setImage(full, pixelSize: info.pixelSize, rotation: rotation)
            preloadNeighbors()
            return
        }
        // Show the thumbnail while decoding; without one, keep the previous photo up until
        // the full image is ready.
        let thumb = thumbCache.object(forKey: url as NSURL)
        if let thumb { canvas.setImage(thumb, pixelSize: info.pixelSize, rotation: rotation) }
        loadQueue.async { [weak self] in
            let image = ImageLoader.fullImage(url)
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                if let image {
                    self.fullCache[url] = image
                    self.trimCache()
                    if thumb != nil {
                        self.canvas.replaceContents(image)
                    } else {
                        self.canvas.setImage(image, pixelSize: info.pixelSize, rotation: rotation)
                    }
                    self.preloadNeighbors()
                } else {
                    self.canvas.setImage(nil, pixelSize: .zero, rotation: 0)
                    self.showMessage("Can’t open “\(url.lastPathComponent)”.")
                }
            }
        }
    }

    private var neighborURLs: [URL] {
        guard files.count > 1 else { return [] }
        return [1, -1].map { files[(index + $0 + files.count) % files.count] }
    }

    private func trimCache() {
        let keep = Set([currentURL].compactMap { $0 } + neighborURLs)
        fullCache = fullCache.filter { keep.contains($0.key) }
    }

    private func preloadNeighbors() {
        for url in neighborURLs where fullCache[url] == nil {
            loadQueue.async { [weak self] in
                guard let image = ImageLoader.fullImage(url) else { return }
                DispatchQueue.main.async {
                    guard let self, self.neighborURLs.contains(url) else { return }
                    self.fullCache[url] = image
                }
            }
        }
    }

    private func thumbnail(at i: Int) -> CGImage? {
        guard files.indices.contains(i) else { return nil }
        let url = files[i]
        if let thumb = thumbCache.object(forKey: url as NSURL) { return thumb }
        if !thumbsLoading.contains(url) {
            thumbsLoading.insert(url)
            thumbQueue.addOperation { [weak self] in
                let thumb = ImageLoader.thumbnail(url, maxPixel: 160)
                OperationQueue.main.addOperation {
                    guard let self else { return }
                    self.thumbsLoading.remove(url)
                    guard let thumb else { return }
                    self.thumbCache.setObject(thumb, forKey: url as NSURL)
                    self.filmstrip.needsDisplay = true
                    if url == self.currentURL, !self.canvas.hasContents { self.canvas.replaceContents(thumb) }
                }
            }
        }
        return nil
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
        zoomLabel.stringValue = "\(Int((canvas.zoom * 100).rounded()))%"
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
        guard mods.isEmpty else { return false }
        if let key = event.specialKey {
            switch key {
            case .rightArrow, .downArrow, .pageDown: step(1)
            case .leftArrow, .upArrow, .pageUp: step(-1)
            case .home: go(to: 0)
            case .end: go(to: files.count - 1)
            default: return false
            }
            return true
        }
        switch event.keyCode {
        case 53:  // Esc
            if isSlideshow { stopSlideshow() } else { closeViewer(nil) }
            return true
        case 49:  // Space
            step(event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        default:
            break
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=": canvas.zoomIn()
        case "-", "_": canvas.zoomOut()
        case "0": canvas.zoomToFit()
        case "1": canvas.zoomToActualSize()
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
        updateInfoLabel(ImageLoader.info(url))
    }

    @objc func zoomIn(_ sender: Any?) { canvas.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { canvas.zoomOut() }
    @objc func zoomToFit(_ sender: Any?) { canvas.zoomToFit() }
    @objc func actualSize(_ sender: Any?) { canvas.zoomToActualSize() }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func copy(_ sender: Any?) {
        guard let url = currentURL else { return }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType,
           type.conforms(to: .png) || type.conforms(to: .jpeg) || type.conforms(to: .tiff),
           let data = try? Data(contentsOf: url) {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        } else if let tiff = NSImage(contentsOf: url)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
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
        fullCache[url] = nil
        thumbCache.removeObject(forKey: url as NSURL)
        rotations[url] = nil
        if files.isEmpty {
            closeViewer(nil)
            return
        }
        filmstrip.count = files.count
        go(to: min(index, files.count - 1))
    }

    @objc func toggleSlideshow(_ sender: Any?) {
        if isSlideshow { stopSlideshow() } else { startSlideshow() }
    }

    private func startSlideshow() {
        guard files.count > 1 else { return }
        restartSlideshowTimer()
        setChromeHidden(true)
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func restartSlideshowTimer() {
        slideshowTimer?.invalidate()
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.go(to: self.index + 1)
        }
    }

    private func stopSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        setChromeHidden(false)
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
        guard !isClosing else { return }
        isClosing = true
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        generation += 1
        guard let window, window.isVisible else {
            self.window?.close()
            return
        }
        // The photo shrinks back into the middle while the dimming lifts.
        canvas.playClose()
        NSAnimationContext.runAnimationGroup({
            $0.duration = ImageCanvasView.closeDuration
            $0.timingFunction = ImageCanvasView.closeEasing
            for v in fadingViews { v.animator().alphaValue = 0 }
        }, completionHandler: { window.close() })
    }

    func windowWillClose(_ notification: Notification) {
        thumbQueue.cancelAllOperations()
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
        default:
            return currentURL != nil || item.action == #selector(closeViewer(_:))
        }
    }
}
