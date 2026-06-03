import Foundation
import Combine

/// Per-user set of Jellyfin library IDs that the user has chosen to hide.
/// Persists to UserDefaults + iCloud-KVS so toggles roam across devices.
///
/// A hidden library has to be honoured in *generated* content (daily mixes,
/// radio, home rows), not just the library browser. The catch: a track's
/// `ParentId` is its album, and an album's `ParentId` is its artist — neither
/// is the library/CollectionFolder id. So matching `ParentId` against the
/// hidden set alone misses almost everything. We additionally resolve each
/// hidden library's album + artist IDs from the server (cached) and filter
/// membership against those, the same way `LiveFilterStore` caches live-album
/// IDs.
@MainActor
public final class LibraryVisibilityStore: ObservableObject {

    public static let shared = LibraryVisibilityStore()

    @Published public private(set) var hidden: Set<String>
    /// Album IDs belonging to hidden libraries (resolved from the server).
    @Published public private(set) var hiddenAlbumIds: Set<String>
    /// Artist IDs belonging to hidden libraries (resolved from the server).
    @Published public private(set) var hiddenArtistIds: Set<String>

    private static let key        = "bolera.pro.hiddenLibraries"
    private static let albumsKey  = "bolera.pro.hiddenLibraryAlbums"
    private static let artistsKey = "bolera.pro.hiddenLibraryArtists"

    private init() {
        let defaults = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        let cloud = CloudKVS.stringArray(forKey: Self.key) ?? []
        self.hidden = Set(defaults).union(cloud)
        self.hiddenAlbumIds = Set(UserDefaults.standard.stringArray(forKey: Self.albumsKey) ?? [])
        self.hiddenArtistIds = Set(UserDefaults.standard.stringArray(forKey: Self.artistsKey) ?? [])
        persistLocal()
        CloudKVS.synchronize()
        CloudKVS.addObserver(self, selector: #selector(cloudChanged))
    }

    @objc private nonisolated func cloudChanged(_ note: Notification) {
        Task { @MainActor in
            let updated = CloudKVS.stringArray(forKey: Self.key) ?? []
            self.hidden.formUnion(updated)
            self.persistLocal()
        }
    }

    public func isHidden(_ libraryId: String) -> Bool { hidden.contains(libraryId) }

    public func setHidden(_ libraryId: String, _ on: Bool) {
        if on { hidden.insert(libraryId) } else { hidden.remove(libraryId) }
        persistLocal()
        CloudKVS.set(Array(hidden), forKey: Self.key)
        CloudKVS.synchronize()
    }

    /// Resolve the album + artist IDs inside every hidden library so `filter`
    /// can drop their tracks/albums/artists from generated content. No-op-ish
    /// when nothing is hidden (clears the caches). Call after a toggle changes
    /// and on library refresh / before mix generation.
    public func refresh(client: JellyfinClient) async {
        guard !hidden.isEmpty else {
            if !hiddenAlbumIds.isEmpty || !hiddenArtistIds.isEmpty {
                hiddenAlbumIds = []; hiddenArtistIds = []
                persistLocal()
            }
            return
        }
        // Resolve every hidden library concurrently so N libraries cost ~1
        // round-trip, not N (this runs on home load + mix generation).
        let libs = Array(hidden)
        let resolved = await withTaskGroup(of: (albums: Set<String>, artists: Set<String>).self) { group in
            for lib in libs { group.addTask { await client.contentIds(inLibrary: lib) } }
            var albums: Set<String> = []
            var artists: Set<String> = []
            for await ids in group {
                albums.formUnion(ids.albums)
                artists.formUnion(ids.artists)
            }
            return (albums: albums, artists: artists)
        }
        hiddenAlbumIds = resolved.albums
        hiddenArtistIds = resolved.artists
        persistLocal()
    }

    /// Drops items belonging to a hidden library: matched by the library id
    /// itself (top-level folders), the item's album id, the album/artist item
    /// id, or any credited artist.
    public func filter(_ items: [BaseItem]) -> [BaseItem] {
        guard !hidden.isEmpty || !hiddenAlbumIds.isEmpty || !hiddenArtistIds.isEmpty else {
            return items
        }
        return items.filter { item in
            if let pid = item.ParentId, hidden.contains(pid) { return false }
            if let aid = item.AlbumId, hiddenAlbumIds.contains(aid) { return false }
            if item.type == "MusicAlbum", hiddenAlbumIds.contains(item.Id) { return false }
            if item.type == "MusicArtist", hiddenArtistIds.contains(item.Id) { return false }
            for aid in (item.AlbumArtists ?? []).map(\.Id) where hiddenArtistIds.contains(aid) { return false }
            for aid in (item.ArtistItems ?? []).map(\.Id) where hiddenArtistIds.contains(aid) { return false }
            return true
        }
    }

    private func persistLocal() {
        UserDefaults.standard.set(Array(hidden), forKey: Self.key)
        UserDefaults.standard.set(Array(hiddenAlbumIds), forKey: Self.albumsKey)
        UserDefaults.standard.set(Array(hiddenArtistIds), forKey: Self.artistsKey)
    }
}
