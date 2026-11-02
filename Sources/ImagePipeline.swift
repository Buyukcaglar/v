import Foundation
import CoreGraphics

/// Decodes photos off the main thread, a couple at a time, and holds only the ones the
/// viewer can show next. Call it from the main thread only.
final class ImagePipeline {
    /// Called on the main thread when a wanted photo has been decoded, or failed (nil).
    var onDecoded: ((URL, CGImage?) -> Void)?

    private(set) var images: [URL: CGImage] = [:]
    private var pending: [URL: Operation] = [:]
    private var wanted: [URL] = []
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    /// The photos worth holding, the current one first. Everything else is dropped, and its
    /// decode is cancelled unless it has already started.
    func keep(_ urls: [URL]) {
        wanted = urls
        images = images.filter { urls.contains($0.key) }
        for (url, op) in pending where !urls.contains(url) && !op.isExecuting {
            op.cancel()
            pending[url] = nil
        }
    }

    /// Decodes `url` unless it is cached or already on its way; `first` puts it ahead of the rest.
    func load(_ url: URL, first: Bool) {
        guard images[url] == nil else { return }
        if let op = pending[url] {
            if first { op.queuePriority = .veryHigh }
            return
        }
        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let op, !op.isCancelled else { return }
            let image = ImageLoader.fullImage(url)
            DispatchQueue.main.async { self?.finished(url, image, op) }
        }
        op.queuePriority = first ? .veryHigh : .normal
        op.qualityOfService = first ? .userInitiated : .utility
        pending[url] = op
        queue.addOperation(op)
    }

    private func finished(_ url: URL, _ image: CGImage?, _ op: Operation) {
        if pending[url] === op { pending[url] = nil }
        guard wanted.contains(url) else { return }
        images[url] = image
        onDecoded?(url, image)
    }
}
