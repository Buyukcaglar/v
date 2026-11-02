import Foundation
import CoreGraphics

/// Decodes photos off the main thread, a couple at a time, and holds only the ones the
/// viewer can show next: a screen-sized image of the current photo and its neighbours, and
/// a full-resolution one of the current photo while it is zoomed in. Call it from the main
/// thread only.
final class ImagePipeline {
    enum Tier { case screen, full }

    /// Called on the main thread when a wanted image has been decoded, or failed (nil).
    var onDecoded: ((URL, Tier, CGImage?) -> Void)?

    private(set) var images: [URL: CGImage] = [:]
    private(set) var full: (url: URL, image: CGImage)?
    private var pending: [Request: Operation] = [:]
    private var wanted: [URL] = []
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    private struct Request: Hashable {
        let url: URL
        let tier: Tier
    }

    /// The photos worth holding, the current one first. Everything else is dropped, and its
    /// decode is cancelled unless it has already started.
    func keep(_ urls: [URL]) {
        wanted = urls
        images = images.filter { urls.contains($0.key) }
        if full?.url != urls.first { full = nil }
        cancel { !urls.contains($0.url) || ($0.tier == .full && $0.url != urls.first) }
    }

    func dropFull() {
        full = nil
        cancel { $0.tier == .full }
    }

    /// Decodes the screen tier of `url` to fill `box` (device pixels) unless an image with a
    /// long side of at least `minLongSide` is cached or on its way. `first` puts it ahead of the rest.
    func loadScreen(_ url: URL, box: CGSize, minLongSide: Int = 0, first: Bool) {
        if let image = images[url], max(image.width, image.height) >= minLongSide { return }
        load(Request(url: url, tier: .screen), first: first) { ImageLoader.screenImage(url, fitting: box) }
    }

    func loadFull(_ url: URL) {
        guard full?.url != url else { return }
        load(Request(url: url, tier: .full), first: true) { ImageLoader.fullImage(url) }
    }

    private func load(_ request: Request, first: Bool, decode: @escaping () -> CGImage?) {
        if let op = pending[request] {
            if first { op.queuePriority = .veryHigh }
            return
        }
        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let op, !op.isCancelled else { return }
            let image = decode()
            DispatchQueue.main.async { self?.finished(request, image, op) }
        }
        op.queuePriority = first ? .veryHigh : .normal
        op.qualityOfService = first ? .userInitiated : .utility
        pending[request] = op
        queue.addOperation(op)
    }

    private func cancel(where stale: (Request) -> Bool) {
        for (request, op) in pending where stale(request) && !op.isExecuting {
            op.cancel()
            pending[request] = nil
        }
    }

    private func finished(_ request: Request, _ image: CGImage?, _ op: Operation) {
        if pending[request] === op { pending[request] = nil }
        let url = request.url
        switch request.tier {
        case .screen:
            guard wanted.contains(url) else { return }
            if let image { images[url] = image }
        case .full:
            guard url == wanted.first else { return }
            full = image.map { (url, $0) }
        }
        onDecoded?(url, request.tier, image)
    }
}
