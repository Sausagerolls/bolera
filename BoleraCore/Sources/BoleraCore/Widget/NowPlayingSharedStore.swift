import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Read/write bridge for the Now Playing widget. The small JSON snapshot
/// lives in the App Group `UserDefaults`; the artwork (too big for defaults)
/// is a downsized JPEG in the App Group container directory. Both the app
/// (writer) and the widget extension (reader) reach the same bytes via the
/// shared `group.com.giantmushroom.bolera` container.
public enum NowPlayingSharedStore {
    /// Must stay byte-identical to the `com.apple.security.application-groups`
    /// entry in every target's entitlements file.
    public static let appGroupId = "group.com.giantmushroom.bolera"

    private static let snapshotFileName = "nowplaying-snapshot.json"
    private static let artworkFileName = "nowplaying-artwork.jpg"
    private static let artworkMaxDimension: CGFloat = 240

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    private static var snapshotURL: URL? { containerURL?.appendingPathComponent(snapshotFileName) }

    // MARK: - Write (app side)

    public static func write(_ snapshot: NowPlayingSnapshot) {
        // A FILE in the App Group container — NOT App Group `UserDefaults`. On
        // macOS the widget extension is kept warm by chronod and its cfprefsd
        // serves a STALE cached copy of a shared UserDefaults suite, so the
        // widget never saw new writes (the artwork — already a file — was the
        // only thing that updated). File reads always hit disk fresh.
        guard let url = snapshotURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Downsize + JPEG-encode `image` and write it atomically into the App
    /// Group container. Returns the relative file name to store in the
    /// snapshot, or nil if there's nothing to write.
    @discardableResult
    public static func writeArtwork(_ image: PlatformImage?) -> String? {
        guard let image, let dir = containerURL else { return nil }
        let url = dir.appendingPathComponent(artworkFileName)
        guard let data = jpegData(from: downsized(image, maxDimension: artworkMaxDimension)) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? data.write(to: url, options: .atomic)
        return artworkFileName
    }

    public static func clearArtwork() {
        guard let dir = containerURL else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(artworkFileName))
    }

    // MARK: - Read (widget side)

    public static func read() -> NowPlayingSnapshot {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    public static func artworkData(relativePath: String?) -> Data? {
        guard let name = relativePath, let dir = containerURL else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    // MARK: - Cross-platform image helpers (mirror DailyPlaylistStore's pattern)

    private static func jpegData(from image: PlatformImage) -> Data? {
        #if canImport(UIKit)
        return image.jpegData(compressionQuality: 0.8)
        #elseif canImport(AppKit)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        #else
        return nil
        #endif
    }

    /// Aspect-fit resize so the longest edge is at most `maxDimension`. Returns
    /// the original if it's already smaller.
    private static func downsized(_ image: PlatformImage, maxDimension: CGFloat) -> PlatformImage {
        #if canImport(UIKit)
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        #elseif canImport(AppKit)
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let result = NSImage(size: target)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy, fraction: 1.0)
        result.unlockFocus()
        return result
        #else
        return image
        #endif
    }
}
