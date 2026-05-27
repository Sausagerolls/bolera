import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// In-memory + on-disk image cache. Required because Jellyfin image URLs need
/// the Authorization header, so `AsyncImage` alone can't handle them.
/// Class (not actor) so concurrent loads run in parallel — NSCache + filesystem are thread-safe.
public final class ImageCache: @unchecked Sendable {
    public static let shared = ImageCache()

    private let memory = NSCache<NSURL, PlatformImage>()
    private let diskURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public func load(url: URL, headers: [String: String] = [:]) async -> PlatformImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        let diskPath = diskURL.appendingPathComponent(url.absoluteString.sha)
        if let image = await Task.detached(priority: .utility, operation: { () -> PlatformImage? in
            guard let data = try? Data(contentsOf: diskPath) else { return nil }
            return PlatformImage(data: data)
        }).value {
            memory.setObject(image, forKey: url as NSURL)
            return image
        }
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let image = PlatformImage(data: data) else { return nil }
            memory.setObject(image, forKey: url as NSURL)
            Task.detached(priority: .utility) { try? data.write(to: diskPath) }
            return image
        } catch {
            return nil
        }
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
