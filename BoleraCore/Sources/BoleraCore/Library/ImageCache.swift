import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Posted when NSCache evicts an entry under memory pressure. Views
/// that hold a "currently visible" URL (mini player artwork, Now Playing
/// art) can subscribe and re-trigger their async load instead of going
/// blank — `.task(id:)` alone won't re-fire because the item id hasn't
/// changed, only the cache contents.
public extension Notification.Name {
    static let imageCacheDidEvict = Notification.Name("BoleraImageCacheDidEvict")
}

/// In-memory + on-disk image cache. Required because Jellyfin image URLs need
/// the Authorization header, so `AsyncImage` alone can't handle them.
/// Class (not actor) so concurrent loads run in parallel — NSCache + filesystem are thread-safe.
public final class ImageCache: NSObject, NSCacheDelegate, @unchecked Sendable {
    public static let shared = ImageCache()

    private let memory: NSCache<NSURL, PlatformImage> = {
        let cache = NSCache<NSURL, PlatformImage>()
        // Cap the in-memory image cache so it doesn't grow without bound
        // as the user browses the library. Without this, every artist /
        // album avatar that scrolls past stays resident — UIImage backing
        // decompresses to ~width*height*4 bytes — and iOS eventually
        // throws memory warnings that stall scrolling while it evicts
        // and re-decodes. ~200MB caps several hundred avatars + a few
        // dozen full album covers, which is plenty for browsing.
        cache.totalCostLimit = 200 * 1024 * 1024
        cache.countLimit = 600
        return cache
    }()

    private override init() {
        super.init()
        memory.delegate = self
    }

    public func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        // NSCache eviction posts on a background thread; bounce to the
        // main queue so SwiftUI observers can update state directly.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .imageCacheDidEvict, object: nil)
        }
    }
    private let diskURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Synchronous, side-effect-free peek of the in-memory cache. Lets
    /// SwiftUI views render the correct artwork *immediately* on a cell
    /// recycle rather than first flashing the previous item's image (or
    /// a shimmer placeholder) while the async `load` round-trip
    /// completes. Returns nil on a memory-tier miss — the caller should
    /// still drive an async `load` to populate it.
    public func peekMemory(url: URL) -> PlatformImage? {
        memory.object(forKey: url as NSURL)
    }

    public func load(url: URL, headers: [String: String] = [:]) async -> PlatformImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        let diskPath = diskURL.appendingPathComponent(url.absoluteString.sha)
        if let image = await Task.detached(priority: .utility, operation: { () -> PlatformImage? in
            guard let data = try? Data(contentsOf: diskPath) else { return nil }
            return Self.decoded(from: data)
        }).value {
            store(image, for: url)
            return image
        }
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let image = await Task.detached(priority: .utility, operation: {
                Self.decoded(from: data)
            }).value else { return nil }
            store(image, for: url)
            Task.detached(priority: .utility) { try? data.write(to: diskPath) }
            return image
        } catch {
            return nil
        }
    }

    /// Decode the image data eagerly off the main thread. `UIImage(data:)`
    /// returns a *lazily*-decoded image — the first time SwiftUI draws it,
    /// CoreGraphics decompresses on the main thread, causing a scroll hitch
    /// as each new cell appears. The old approach (drawing into a 1x1
    /// UIGraphics context) was both ineffective — a 1pt draw doesn't force a
    /// full-size decode — and unsafe off the main thread. Instead use ImageIO
    /// to create a fully-decoded thumbnail right here on the background task:
    /// `kCGImageSourceShouldCacheImmediately` forces the decompress now, and
    /// the max-pixel cap (== the largest size any JellyfinImage requests)
    /// bounds the decompressed backing store. Falls back to a plain decode so
    /// valid data never renders blank.
    private static let maxDecodePixels = 600
    private static func decoded(from data: Data) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return PlatformImage(data: data)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDecodePixels
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            return PlatformImage(data: data)
        }
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: .zero)
        #endif
    }

    private func store(_ image: PlatformImage, for url: URL) {
        memory.setObject(image, forKey: url as NSURL, cost: Self.estimateCost(of: image))
    }

    /// Conservative byte estimate for an image's decompressed backing.
    /// Avoids the platform's `cgImage.bytesPerRow * height` because
    /// UIImage/NSImage may not have decoded a cgImage yet at this point.
    private static func estimateCost(of image: PlatformImage) -> Int {
        #if canImport(UIKit)
        let scale = image.scale
        let w = Int(image.size.width * scale)
        let h = Int(image.size.height * scale)
        #else
        let w = Int(image.size.width)
        let h = Int(image.size.height)
        #endif
        // Assume 4 bytes/pixel (BGRA8). Even when the source is JPEG with
        // 3 channels, UIKit allocates a 4-byte-per-pixel backing buffer.
        return max(1, w * h * 4)
    }
}

private extension String {
    /// Cheap fixed-length hash for use as a cache filename.
    var sha: String {
        let h = self.unicodeScalars.reduce(into: UInt64(5381)) { acc, c in
            acc = (acc &* 33) &+ UInt64(c.value)
        }
        return String(h, radix: 16)
    }
}
