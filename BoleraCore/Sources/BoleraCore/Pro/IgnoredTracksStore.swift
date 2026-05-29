import Foundation
import Combine

/// Per-user "Do not auto-play" lists. Originally tracks-only; now also
/// covers full artists and full albums. Anything in any of the three
/// sets is silently skipped by the daily-mix and AI-playlist generators.
/// Persists to UserDefaults + iCloud-KVS.
@MainActor
public final class IgnoredTracksStore: ObservableObject {

    public static let shared = IgnoredTracksStore()

    @Published public private(set) var ignored: Set<String>          // track IDs
    @Published public private(set) var ignoredArtists: Set<String>   // MusicArtist IDs
    @Published public private(set) var ignoredAlbums: Set<String>    // MusicAlbum IDs
    /// User-friendly display map: id → label populated by the app so the
    /// settings UI renders rows even when the user is offline. Shared
    /// across all three kinds.
    @Published public private(set) var labels: [String: String]

    private static let idsKey         = "bolera.pro.ignoredTracks"
    private static let artistsKey     = "bolera.pro.ignoredArtists"
    private static let albumsKey      = "bolera.pro.ignoredAlbums"
    private static let labelsKey      = "bolera.pro.ignoredTrackLabels"

    private init() {
        let localT = UserDefaults.standard.stringArray(forKey: Self.idsKey) ?? []
        let cloudT = CloudKVS.stringArray(forKey: Self.idsKey) ?? []
        let localA = UserDefaults.standard.stringArray(forKey: Self.artistsKey) ?? []
        let cloudA = CloudKVS.stringArray(forKey: Self.artistsKey) ?? []
        let localB = UserDefaults.standard.stringArray(forKey: Self.albumsKey) ?? []
        let cloudB = CloudKVS.stringArray(forKey: Self.albumsKey) ?? []
        self.ignored = Set(localT).union(cloudT)
        self.ignoredArtists = Set(localA).union(cloudA)
        self.ignoredAlbums = Set(localB).union(cloudB)
        let localLabels = UserDefaults.standard.dictionary(forKey: Self.labelsKey) as? [String: String] ?? [:]
        let cloudLabels = CloudKVS.dictionary(forKey: Self.labelsKey) ?? [:]
        self.labels = localLabels.merging(cloudLabels) { $1 }
        persistLocal()
        CloudKVS.synchronize()
        CloudKVS.addObserver(self, selector: #selector(cloudChanged))
    }

    @objc private nonisolated func cloudChanged(_ note: Notification) {
        Task { @MainActor in
            let t = CloudKVS.stringArray(forKey: Self.idsKey) ?? []
            let a = CloudKVS.stringArray(forKey: Self.artistsKey) ?? []
            let b = CloudKVS.stringArray(forKey: Self.albumsKey) ?? []
            let lbl = CloudKVS.dictionary(forKey: Self.labelsKey) ?? [:]
            self.ignored.formUnion(t)
            self.ignoredArtists.formUnion(a)
            self.ignoredAlbums.formUnion(b)
            self.labels.merge(lbl) { $1 }
            self.persistLocal()
        }
    }

    // MARK: - Tracks

    public func isIgnored(_ id: String) -> Bool { ignored.contains(id) }

    public func ignore(_ item: BaseItem) {
        ignored.insert(item.Id)
        labels[item.Id] = "\(item.Name) — \(item.primaryArtistName)"
        persistLocal(); sync()
    }

    public func unignore(_ id: String) {
        ignored.remove(id)
        labels.removeValue(forKey: id)
        persistLocal(); sync()
    }

    // MARK: - Artists

    public func isArtistIgnored(_ id: String) -> Bool { ignoredArtists.contains(id) }

    public func ignoreArtist(_ item: BaseItem) {
        ignoredArtists.insert(item.Id)
        labels[item.Id] = item.Name
        persistLocal(); sync()
    }

    public func unignoreArtist(_ id: String) {
        ignoredArtists.remove(id)
        labels.removeValue(forKey: id)
        persistLocal(); sync()
    }

    // MARK: - Albums

    public func isAlbumIgnored(_ id: String) -> Bool { ignoredAlbums.contains(id) }

    public func ignoreAlbum(_ item: BaseItem) {
        ignoredAlbums.insert(item.Id)
        labels[item.Id] = "\(item.Name) — \(item.primaryArtistName)"
        persistLocal(); sync()
    }

    public func unignoreAlbum(_ id: String) {
        ignoredAlbums.remove(id)
        labels.removeValue(forKey: id)
        persistLocal(); sync()
    }

    // MARK: - Filtering

    /// Drops items hit by any of the three ignore lists. For a track, hits
    /// when: the track itself is ignored, its album is ignored, or any of
    /// its credited artists are ignored. Cheap O(n).
    public func filter(_ items: [BaseItem]) -> [BaseItem] {
        if ignored.isEmpty && ignoredArtists.isEmpty && ignoredAlbums.isEmpty {
            return items
        }
        return items.filter { item in
            if ignored.contains(item.Id) { return false }
            if let albumId = item.AlbumId, ignoredAlbums.contains(albumId) { return false }
            // For an album item itself
            if item.type == "MusicAlbum" && ignoredAlbums.contains(item.Id) { return false }
            // For an artist item itself
            if item.type == "MusicArtist" && ignoredArtists.contains(item.Id) { return false }
            // Artist credits on tracks
            let albumArtistIds = (item.AlbumArtists ?? []).map(\.Id)
            let artistItemIds = (item.ArtistItems ?? []).map(\.Id)
            for aid in albumArtistIds where ignoredArtists.contains(aid) { return false }
            for aid in artistItemIds where ignoredArtists.contains(aid) { return false }
            return true
        }
    }

    private func persistLocal() {
        UserDefaults.standard.set(Array(ignored), forKey: Self.idsKey)
        UserDefaults.standard.set(Array(ignoredArtists), forKey: Self.artistsKey)
        UserDefaults.standard.set(Array(ignoredAlbums), forKey: Self.albumsKey)
        UserDefaults.standard.set(labels, forKey: Self.labelsKey)
    }

    private func sync() {
        CloudKVS.set(Array(ignored), forKey: Self.idsKey)
        CloudKVS.set(Array(ignoredArtists), forKey: Self.artistsKey)
        CloudKVS.set(Array(ignoredAlbums), forKey: Self.albumsKey)
        CloudKVS.set(labels, forKey: Self.labelsKey)
        CloudKVS.synchronize()
    }
}
