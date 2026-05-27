import Foundation
import Combine

public struct PinnedItem: Codable, Identifiable, Hashable {
    public let itemId: String
    public let name: String
    public let type: String   // "MusicArtist" or "MusicAlbum"
    public let imageTag: String?

    public var id: String { "\(type):\(itemId)" }

    public init(itemId: String, name: String, type: String, imageTag: String?) {
        self.itemId = itemId
        self.name = name
        self.type = type
        self.imageTag = imageTag
    }
}

/// Persists user-pinned artists/albums for the Mac sidebar Pinned section.
@MainActor
public final class PinnedItemsStore: ObservableObject {

    public static let shared = PinnedItemsStore()

    @Published public private(set) var pins: [PinnedItem]

    private static let key = "bolera.sidebarPins.v2"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([PinnedItem].self, from: data) {
            self.pins = saved
        } else {
            self.pins = []
        }
    }

    public func isPinned(itemId: String) -> Bool {
        pins.contains(where: { $0.itemId == itemId })
    }

    public func pin(_ item: BaseItem) {
        // Resolve to the underlying album or artist record. Audio tracks
        // pin to their parent album so the saved pin opens a real album page.
        let resolvedId: String
        let resolvedType: String
        let resolvedName: String
        let resolvedTag: String?

        if item.type == "MusicAlbum" || item.type == "MusicArtist" {
            resolvedId = item.Id
            resolvedType = item.type!
            resolvedName = item.Name
            resolvedTag = item.ImageTags?["Primary"]
        } else if item.type == "Audio", let aid = item.AlbumId {
            resolvedId = aid
            resolvedType = "MusicAlbum"
            resolvedName = item.Album ?? item.Name
            resolvedTag = item.AlbumPrimaryImageTag
        } else {
            return
        }

        guard !isPinned(itemId: resolvedId) else { return }
        pins.append(PinnedItem(itemId: resolvedId, name: resolvedName, type: resolvedType, imageTag: resolvedTag))
        persist()
    }

    public func togglePin(_ item: BaseItem) {
        let resolvedId: String
        if item.type == "MusicAlbum" || item.type == "MusicArtist" {
            resolvedId = item.Id
        } else if item.type == "Audio", let aid = item.AlbumId {
            resolvedId = aid
        } else {
            return
        }
        if isPinned(itemId: resolvedId) {
            unpin(itemId: resolvedId)
        } else {
            pin(item)
        }
    }

    public func unpin(itemId: String) {
        pins.removeAll { $0.itemId == itemId }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(pins) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
