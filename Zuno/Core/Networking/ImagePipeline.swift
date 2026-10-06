import Foundation
import ImageIO
import UIKit

/// Resolves image bytes for a reference. Live: public Storage URLs for event media and
/// authenticated downloads for avatars. Development: bundled assets.
protocol ImageDataSource: Sendable {
    func data(for reference: ImageReference) async throws -> Data
}

/// Fetches, downsamples and caches artwork. Requests are de-duplicated and cancellable
/// (SwiftUI cancels `.task` when a view disappears); decoded images live in a cost-limited
/// `NSCache` that the system trims under memory pressure.
actor ImagePipeline {
    static let shared = ImagePipeline()

    private nonisolated let memoryCache = ImageMemoryCache()
    private var inflight: [String: Task<UIImage, Error>] = [:]
    private var source: ImageDataSource = URLImageDataSource()

    enum PipelineError: Error { case decodingFailed, missingAsset }

    func configure(source: ImageDataSource) {
        self.source = source
        memoryCache.removeAllObjects()
    }

    nonisolated func cachedImage(for reference: ImageReference, maxPixelSize: CGFloat) -> UIImage? {
        memoryCache.object(forKey: Self.key(reference, maxPixelSize) as NSString)
    }

    func image(for reference: ImageReference, maxPixelSize: CGFloat) async throws -> UIImage {
        let key = Self.key(reference, maxPixelSize)
        if let cached = memoryCache.object(forKey: key as NSString) { return cached }
        if let running = inflight[key] { return try await running.value }

        if case .bundled(let name) = reference {
            guard let image = UIImage(named: name) else { throw PipelineError.missingAsset }
            let prepared = await image.byPreparingForDisplay() ?? image
            store(prepared, key: key)
            return prepared
        }

        let source = self.source
        let task = Task<UIImage, Error> {
            let data = try await source.data(for: reference)
            try Task.checkCancellation()
            guard let image = Self.downsample(data, maxPixelSize: maxPixelSize) else { throw PipelineError.decodingFailed }
            return image
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        let image = try await task.value
        store(image, key: key)
        return image
    }

    /// Warms the cache for artwork that is about to scroll into view.
    func prefetch(_ references: [ImageReference], maxPixelSize: CGFloat) {
        for reference in references where cachedImage(for: reference, maxPixelSize: maxPixelSize) == nil {
            Task(priority: .utility) { _ = try? await self.image(for: reference, maxPixelSize: maxPixelSize) }
        }
    }

    func purge() { memoryCache.removeAllObjects() }

    private func store(_ image: UIImage, key: String) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
    }

    private static func key(_ reference: ImageReference, _ size: CGFloat) -> String {
        let bucket = Int((size / 100).rounded(.up)) * 100 // share entries across similar sizes
        switch reference {
        case .storage(let bucketName, let path): return "s:\(bucketName)/\(path)@\(bucket)"
        case .remote(let url): return "r:\(url.absoluteString)@\(bucket)"
        case .bundled(let name): return "b:\(name)"
        }
    }

    /// ImageIO thumbnailing decodes straight to the target size (no full-size bitmap).
    static func downsample(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 64),
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// `NSCache` is documented as thread-safe; this wrapper states that to the compiler.
final class ImageMemoryCache: @unchecked Sendable {
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    func object(forKey key: NSString) -> UIImage? { cache.object(forKey: key) }
    func setObject(_ image: UIImage, forKey key: NSString, cost: Int) { cache.setObject(image, forKey: key, cost: cost) }
    func removeAllObjects() { cache.removeAllObjects() }
}

/// Plain URL fetching for `.remote` references (and public storage URLs built by callers).
struct URLImageDataSource: ImageDataSource {
    let session: URLSession
    let storageBaseURL: URL?

    init(storageBaseURL: URL? = nil) {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        self.storageBaseURL = storageBaseURL
    }

    func data(for reference: ImageReference) async throws -> Data {
        let url: URL
        switch reference {
        case .remote(let remote): url = remote
        case .storage(let bucket, let path):
            guard let base = storageBaseURL else { throw ImagePipeline.PipelineError.missingAsset }
            url = base.appending(path: "storage/v1/object/public/\(bucket)/\(path)")
        case .bundled: throw ImagePipeline.PipelineError.missingAsset
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
