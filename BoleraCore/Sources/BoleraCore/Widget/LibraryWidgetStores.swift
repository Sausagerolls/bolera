import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - Recently Played

/// Recent tracks shared with the widget. Stores the full `BaseItem`s (Codable)
/// so the play intent can start a real queue without any network round-trip,
/// plus a small artwork JPEG per track keyed by id.
public enum RecentTracksSharedStore {
    public static let maxItems = 12
    private static let file = "recent-tracks.json"

    public static func write(_ tracks: [BaseItem]) {
        let items = Array(tracks.prefix(maxItems))
        guard let data = try? JSONEncoder().encode(items) else { return }
        WidgetSharedContainer.writeFile(data, name: file)
    }

    public static func read() -> [BaseItem] {
        guard let data = WidgetSharedContainer.readFile(name: file),
              let items = try? JSONDecoder().decode([BaseItem].self, from: data) else { return [] }
        return items
    }

    public static func writeArtwork(id: String, image: PlatformImage) {
        guard let data = WidgetSharedContainer.jpegThumbnail(image, maxDimension: 200) else { return }
        WidgetSharedContainer.writeFile(data, name: artworkName(id))
    }

    public static func artworkData(id: String) -> Data? {
        WidgetSharedContainer.readFile(name: artworkName(id))
    }

    private static func artworkName(_ id: String) -> String { "recent-\(id).jpg" }
}

// MARK: - Mixes

public struct WidgetMix: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let theme: String

    public init(id: UUID, name: String, theme: String) {
        self.id = id
        self.name = name
        self.theme = theme
    }
}

/// Daily Mixes shared with the widget. Display metadata is stored here; the
/// play intent resolves the live mix (tracks + endless extender) from
/// `DailyPlaylistStore.shared` by id.
public enum MixesSharedStore {
    private static let file = "mixes.json"

    public static func write(_ mixes: [WidgetMix]) {
        guard let data = try? JSONEncoder().encode(mixes) else { return }
        WidgetSharedContainer.writeFile(data, name: file)
    }

    public static func read() -> [WidgetMix] {
        guard let data = WidgetSharedContainer.readFile(name: file),
              let mixes = try? JSONDecoder().decode([WidgetMix].self, from: data) else { return [] }
        return mixes
    }

    public static func writeArtwork(id: UUID, image: PlatformImage) {
        guard let data = WidgetSharedContainer.jpegThumbnail(image, maxDimension: 240) else { return }
        WidgetSharedContainer.writeFile(data, name: artworkName(id))
    }

    public static func artworkData(id: UUID) -> Data? {
        WidgetSharedContainer.readFile(name: artworkName(id))
    }

    private static func artworkName(_ id: UUID) -> String { "mix-\(id.uuidString).jpg" }
}

// MARK: - App-side export

/// Writes recents into the App Group and refreshes the Recently Played widget.
/// Call whenever `LibraryStore.recentlyPlayed` changes. Text lands immediately;
/// artwork (cached or freshly fetched) follows on a background task.
public enum RecentTracksWidgetExport {
    @MainActor
    public static func export(_ tracks: [BaseItem], client: JellyfinClient?) {
        RecentTracksSharedStore.write(tracks)
        reload()
        guard let client else { return }
        let header = client.auth.authHeader()
        let items = Array(tracks.prefix(RecentTracksSharedStore.maxItems))
        Task.detached {
            for item in items {
                if let img = await ImageCache.shared.loadArtwork(
                    itemId: item.artworkItemId, tag: item.artworkTag,
                    client: client, maxWidth: 200,
                    headers: ["Authorization": header]) {
                    RecentTracksSharedStore.writeArtwork(id: item.Id, image: img)
                }
            }
            await MainActor.run { reload() }
        }
    }

    static func reload() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.recentlyPlayed)
        #endif
    }
}

/// Writes mixes into the App Group and refreshes the Mixes widget. Call when
/// `DailyPlaylistStore.playlists` or its artwork changes.
public enum MixesWidgetExport {
    @MainActor
    public static func export(_ playlists: [DailyPlaylist], artwork: [UUID: PlatformImage]) {
        MixesSharedStore.write(playlists.map { WidgetMix(id: $0.id, name: $0.name, theme: $0.theme) })
        for playlist in playlists {
            if let img = artwork[playlist.id] {
                MixesSharedStore.writeArtwork(id: playlist.id, image: img)
            }
        }
        reload()
    }

    static func reload() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.mixes)
        #endif
    }
}
