import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Low-level access to the shared App Group container used by every Bolera
/// widget: the suite `UserDefaults`, raw file read/write in the container
/// directory, and a cross-platform JPEG thumbnail encoder. Internal — the
/// per-widget stores (`NowPlayingSharedStore`, `RecentTracksSharedStore`,
/// `MixesSharedStore`) wrap it with typed APIs.
enum WidgetSharedContainer {
    static let appGroupId = "group.com.giantmushroom.bolera"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupId) }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    static func writeFile(_ data: Data, name: String) {
        guard let dir = containerURL else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    static func readFile(name: String) -> Data? {
        guard let dir = containerURL else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    static func removeFile(name: String) {
        guard let dir = containerURL else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }

    /// Downsize to `maxDimension` (longest edge) and JPEG-encode. nil if there's
    /// nothing encodable.
    static func jpegThumbnail(_ image: PlatformImage,
                              maxDimension: CGFloat = 240,
                              quality: CGFloat = 0.8) -> Data? {
        let resized = downsized(image, maxDimension: maxDimension)
        #if canImport(UIKit)
        return resized.jpegData(compressionQuality: quality)
        #elseif canImport(AppKit)
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #else
        return nil
        #endif
    }

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

/// Widget `kind` identifiers, shared so the app's `reloadTimelines(ofKind:)`
/// calls and the widget definitions can't drift apart.
public enum WidgetKinds {
    public static let nowPlaying = "BoleraNowPlaying"
    public static let recentlyPlayed = "BoleraRecentlyPlayed"
    public static let mixes = "BoleraMixes"
}
