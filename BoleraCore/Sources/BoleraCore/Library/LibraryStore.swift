import Foundation
import Combine

/// Disk cache for library lists (artists, albums, playlists, home sections).
/// Used to show data instantly on view appear, then refresh in background.
/// Lives here (not its own file) because Xcode flat-pbxproj sometimes drops
/// freshly-added files from the compile batch on first build.
public final class LibraryCache: @unchecked Sendable {
    public static let shared = LibraryCache()

    private let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("LibraryCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    public init() {
        NotificationCenter.default.addObserver(forName: Notification.Name("boleraDidLogout"), object: nil, queue: nil) { [weak self] _ in
            self?.clear()
        }
    }

    public func read<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        let p = dir.appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: p) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func write<T: Encodable>(_ key: String, value: T) {
        let p = dir.appendingPathComponent(key + ".json")
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: p, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// View-model for home screen + simple library caches.
/// Reads cached lists from disk on init so the home screen has data instantly,
/// then refresh() fetches fresh data and overwrites the cache.
@MainActor
public final class LibraryStore: ObservableObject {
    @Published public var recentlyAdded: [BaseItem] = []
    @Published public var recentlyPlayed: [BaseItem] = []
    @Published public var frequentAlbums: [BaseItem] = []
    @Published public var favoriteAlbums: [BaseItem] = []
    @Published public var lastError: String?

    public init() {
        loadCached()
    }

    private func loadCached() {
        recentlyAdded = LibraryCache.shared.read("home.recentlyAdded", as: [BaseItem].self) ?? []
        recentlyPlayed = LibraryCache.shared.read("home.recentlyPlayed", as: [BaseItem].self) ?? []
        frequentAlbums = LibraryCache.shared.read("home.frequentAlbums", as: [BaseItem].self) ?? []
        favoriteAlbums = LibraryCache.shared.read("home.favoriteAlbums", as: [BaseItem].self) ?? []
    }

    public func refresh(client: JellyfinClient) async {
        async let added = client.recentlyAdded()
        async let played = client.recentlyPlayed()
        async let freq = client.frequentlyPlayed()
        async let favs = client.favorites(type: "MusicAlbum")
        do {
            let (a, p, f, fav) = try await (added, played, freq, favs)
            let visibility = LibraryVisibilityStore.shared
            let ignored = IgnoredTracksStore.shared
            let aF = ignored.filter(visibility.filter(a))
            let pF = ignored.filter(visibility.filter(p))
            let fF = visibility.filter(f)
            let favF = visibility.filter(fav)
            recentlyAdded = aF
            recentlyPlayed = pF
            frequentAlbums = fF
            favoriteAlbums = favF
            lastError = nil
            // Cache the unfiltered server response so toggling visibility/ignore
            // shows the right state next launch.
            LibraryCache.shared.write("home.recentlyAdded", value: a)
            LibraryCache.shared.write("home.recentlyPlayed", value: p)
            LibraryCache.shared.write("home.frequentAlbums", value: f)
            LibraryCache.shared.write("home.favoriteAlbums", value: fav)
        } catch is CancellationError {
            // Refresh superseded — keep prior state.
        } catch let err as URLError where err.code == .cancelled {
            // Same — silent on cancellation.
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Re-applies the visibility + ignore filters to the cached lists without
    /// hitting the server. Call after the user toggles a library or ignores
    /// a track so the UI reflects the change immediately.
    public func reapplyFilters() {
        let visibility = LibraryVisibilityStore.shared
        let ignored = IgnoredTracksStore.shared
        let cachedAdded = LibraryCache.shared.read("home.recentlyAdded", as: [BaseItem].self) ?? []
        let cachedPlayed = LibraryCache.shared.read("home.recentlyPlayed", as: [BaseItem].self) ?? []
        let cachedFreq = LibraryCache.shared.read("home.frequentAlbums", as: [BaseItem].self) ?? []
        let cachedFavs = LibraryCache.shared.read("home.favoriteAlbums", as: [BaseItem].self) ?? []
        recentlyAdded = ignored.filter(visibility.filter(cachedAdded))
        recentlyPlayed = ignored.filter(visibility.filter(cachedPlayed))
        frequentAlbums = visibility.filter(cachedFreq)
        favoriteAlbums = visibility.filter(cachedFavs)
    }
}
