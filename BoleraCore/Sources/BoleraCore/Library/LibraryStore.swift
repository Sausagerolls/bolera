import Foundation
import Combine
import Network

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

/// Tracks whether the Jellyfin server is reachable. Driven by NWPathMonitor
/// (interface up/down) plus request outcomes — a satisfied Wi-Fi path doesn't
/// guarantee the (often LAN-only) server is reachable, so successful/failed
/// requests are the authority. Views show downloaded-only content + a banner
/// when offline and repopulate on the `didReconnect` signal.
@MainActor
public final class ConnectivityStore: ObservableObject {
    public static let shared = ConnectivityStore()

    @Published public private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.bolera.connectivity")
    private let reconnect = PassthroughSubject<Void, Never>()

    /// Fires once each time we transition offline -> online.
    public var didReconnect: AnyPublisher<Void, Never> { reconnect.eraseToAnyPublisher() }

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if satisfied, !self.isOnline {
                    self.isOnline = true
                    self.reconnect.send()
                } else if !satisfied {
                    self.isOnline = false
                }
            }
        }
        monitor.start(queue: queue)
    }

    /// Call from any successful network request — the server is reachable.
    public func noteSuccess() {
        if !isOnline {
            isOnline = true
            reconnect.send()
        }
    }

    /// Call from a failed request. Only connectivity-class URLErrors flip us
    /// offline; HTTP 4xx/5xx and decode errors mean the server IS reachable.
    public func noteFailure(_ error: Error) {
        guard let u = error as? URLError else { return }
        switch u.code {
        case .notConnectedToInternet, .timedOut, .cannotConnectToHost,
             .networkConnectionLost, .cannotFindHost, .dataNotAllowed:
            isOnline = false
        default:
            break
        }
    }
}

/// Pre-fetches the whole library (artists, albums, playlists, track names) into
/// LibraryCache and warms ImageCache with every artist + album cover, so the
/// library/home screens render instantly afterwards. Publishes progress for the
/// onboarding step and the Settings "Update Offline Cache" action.
@MainActor
public final class LibraryPrefetcher: ObservableObject {
    public static let shared = LibraryPrefetcher()

    @Published public private(set) var isRunning = false
    @Published public private(set) var progress: Double = 0   // 0...1
    @Published public private(set) var phase: String = ""

    private static let lastCompletedKey = "bolera.prefetch.lastCompleted"
    public var lastCompleted: Date? {
        let t = UserDefaults.standard.double(forKey: Self.lastCompletedKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    public func run(client: JellyfinClient, auth: AuthManager) async {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        phase = "Fetching library…"
        defer { isRunning = false }

        // 1. Lists → LibraryCache (the keys the Library/Home views read).
        let artists = (try? await client.artists(limit: 5000)) ?? []
        LibraryCache.shared.write("artists", value: artists)
        let albums = (try? await client.albums(limit: 5000)) ?? []
        LibraryCache.shared.write("albums", value: albums)
        let playlists = (try? await client.playlists()) ?? []
        LibraryCache.shared.write("playlists", value: playlists)

        // 2. Track names (capped flat fetch).
        phase = "Fetching tracks…"
        let tracks = (try? await client.allTracks(limit: 10000)) ?? []
        LibraryCache.shared.write("allTracks", value: tracks)
        progress = 0.1

        // 3. Warm ImageCache with artist + album artwork (the slow part).
        phase = "Caching artwork…"
        let header = ["Authorization": auth.authHeader()]
        var urls: [URL] = []
        for a in artists {
            if let u = client.imageURL(for: a.Id, tag: a.ImageTags?["Primary"], maxWidth: 180) { urls.append(u) }
        }
        for al in albums {
            if let u = client.imageURL(for: al.Id, tag: al.ImageTags?["Primary"], maxWidth: 400) { urls.append(u) }
        }
        let total = max(1, urls.count)
        var done = 0
        await withTaskGroup(of: Void.self) { group in
            var idx = 0
            func enqueue() {
                while idx < urls.count {
                    let url = urls[idx]; idx += 1
                    group.addTask { _ = await ImageCache.shared.load(url: url, headers: header) }
                    return
                }
            }
            for _ in 0..<8 { enqueue() }            // bound to 8 concurrent fetches
            for await _ in group {
                done += 1
                progress = 0.1 + 0.9 * (Double(done) / Double(total))
                enqueue()
            }
        }
        progress = 1.0
        phase = "Done"
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCompletedKey)
    }
}
