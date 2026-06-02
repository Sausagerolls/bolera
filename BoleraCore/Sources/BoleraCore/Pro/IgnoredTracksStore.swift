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

/// Optionally excludes LIVE recordings from generated content (daily mixes,
/// Make-a-Mix, artist/track radio). A track is treated as live when its title
/// or album name looks live (heuristic) OR its album carries the user's chosen
/// "live" tag/genre on the server. The tag is user-configurable so it matches
/// however they label live albums in their own library. Filtering is purely
/// subtractive — it never affects normal browsing or direct playback.
@MainActor
public final class LiveFilterStore: ObservableObject {
    public static let shared = LiveFilterStore()

    /// Master switch. Off by default.
    @Published public var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    /// Tag/genre the user applies to live albums on their server (default "Live").
    @Published public var tag: String {
        didSet { UserDefaults.standard.set(tag, forKey: Self.tagKey) }
    }
    /// Album IDs carrying `tag`, fetched from the server. Cached to disk.
    @Published public private(set) var liveAlbumIds: Set<String>

    private static let enabledKey = "bolera.live.exclude"
    private static let tagKey     = "bolera.live.tag"
    private static let albumsKey  = "bolera.live.albumIds"

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        tag = UserDefaults.standard.string(forKey: Self.tagKey) ?? "Live"
        liveAlbumIds = Set(UserDefaults.standard.stringArray(forKey: Self.albumsKey) ?? [])
    }

    /// Re-fetch the set of live-tagged album IDs from the server. Call when
    /// online (and after the tag/toggle changes). No-op when disabled.
    public func refresh(client: JellyfinClient) async {
        guard enabled else { return }
        let ids = await client.albumIds(taggedOrGenred: tag)
        guard !ids.isEmpty || liveAlbumIds.isEmpty == false else { return }
        liveAlbumIds = ids
        UserDefaults.standard.set(Array(ids), forKey: Self.albumsKey)
    }

    /// Remove live tracks from `items` when enabled; pass-through otherwise.
    public func filter(_ items: [BaseItem]) -> [BaseItem] {
        guard enabled else { return items }
        return items.filter { !isLive($0) }
    }

    public func isLive(_ item: BaseItem) -> Bool {
        guard enabled else { return false }
        if Self.nameLooksLive(item.Name) { return true }
        if let al = item.Album, Self.nameLooksLive(al) { return true }
        if let aid = item.AlbumId, liveAlbumIds.contains(aid) { return true }
        if liveAlbumIds.contains(item.Id) { return true }   // the item is itself the tagged album
        return false
    }

    /// Heuristic: does a track/album title read as a live recording? Tuned to
    /// avoid common false positives ("Alive", "Living…", the band Live, "Live
    /// and Let Die" — none contain these delimited markers).
    static func nameLooksLive(_ s: String) -> Bool {
        let l = s.lowercased()
        if l.contains("(live") || l.contains("[live") { return true }
        if l.contains(" - live") || l.contains(" – live") || l.contains(": live") { return true }
        for kw in ["unplugged", "in concert", "live at ", "live from ", "live in ",
                   "live on ", "live session", "live version", "live recording",
                   "live bootleg", "live concert", "mtv unplugged"] {
            if l.contains(kw) { return true }
        }
        return false
    }
}
