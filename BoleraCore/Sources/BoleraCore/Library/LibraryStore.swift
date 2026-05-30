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
        // Application Support (not Caches): the prefetched artist/album/track
        // lists are small JSON and should survive iOS purging the Caches
        // directory under memory pressure — otherwise the library reloads slowly
        // from the server after every low-memory event.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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
    @Published public var recentlyAdded: [BaseItem] = []          // albums
    @Published public var recentlyPlayed: [BaseItem] = []         // tracks ("Recent Tracks")
    @Published public var recentlyPlayedAlbums: [BaseItem] = []   // albums ("Recent Albums")
    @Published public var topPlayedTracks: [BaseItem] = []        // tracks ("Top Played Tracks")
    @Published public var favoriteAlbums: [BaseItem] = []
    @Published public var lastError: String?

    public init() {
        loadCached()
    }

    private func loadCached() {
        recentlyAdded = LibraryCache.shared.read("home.recentlyAdded", as: [BaseItem].self) ?? []
        recentlyPlayed = LibraryCache.shared.read("home.recentlyPlayed", as: [BaseItem].self) ?? []
        recentlyPlayedAlbums = LibraryCache.shared.read("home.recentlyPlayedAlbums", as: [BaseItem].self) ?? []
        topPlayedTracks = LibraryCache.shared.read("home.topPlayedTracks", as: [BaseItem].self) ?? []
        favoriteAlbums = LibraryCache.shared.read("home.favoriteAlbums", as: [BaseItem].self) ?? []
    }

    public func refresh(client: JellyfinClient) async {
        async let added = client.recentlyAdded()
        async let playedTracks = client.recentlyPlayed(limit: 60)
        async let topTracks = client.topPlayedTracks()
        async let favs = client.favorites(type: "MusicAlbum")
        do {
            let (a, pt, tt, fav) = try await (added, playedTracks, topTracks, favs)
            let visibility = LibraryVisibilityStore.shared
            let ignored = IgnoredTracksStore.shared
            // "Recent Albums" = the distinct albums of recently-played tracks.
            // Jellyfin doesn't reliably flag the albums themselves as played, so
            // a MusicAlbum+IsPlayed query comes back empty — derive instead.
            let recentAlbums = Self.distinctAlbums(from: pt)
            // Albums get the visibility filter; track lists also get the ignore filter.
            recentlyAdded = visibility.filter(a)
            recentlyPlayed = Array(ignored.filter(visibility.filter(pt)).prefix(24))
            recentlyPlayedAlbums = recentAlbums
            topPlayedTracks = ignored.filter(visibility.filter(tt))
            favoriteAlbums = visibility.filter(fav)
            lastError = nil
            // Cache the unfiltered server response so toggling visibility/ignore
            // shows the right state next launch.
            LibraryCache.shared.write("home.recentlyAdded", value: a)
            LibraryCache.shared.write("home.recentlyPlayed", value: pt)
            LibraryCache.shared.write("home.recentlyPlayedAlbums", value: recentAlbums)
            LibraryCache.shared.write("home.topPlayedTracks", value: tt)
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
        func cached(_ key: String) -> [BaseItem] { LibraryCache.shared.read(key, as: [BaseItem].self) ?? [] }
        recentlyAdded = visibility.filter(cached("home.recentlyAdded"))
        recentlyPlayed = Array(ignored.filter(visibility.filter(cached("home.recentlyPlayed"))).prefix(24))
        recentlyPlayedAlbums = cached("home.recentlyPlayedAlbums")   // derived stubs; already scoped
        topPlayedTracks = ignored.filter(visibility.filter(cached("home.topPlayedTracks")))
        favoriteAlbums = visibility.filter(cached("home.favoriteAlbums"))
    }

    /// Distinct album items derived from a list of tracks, most-recent first.
    /// Used for "Recent Albums" (the albums of recently-played tracks). The
    /// stubs carry the album id as their own id, so artwork (`Items/{id}/Images`)
    /// and navigation to the album detail both resolve.
    static func distinctAlbums(from tracks: [BaseItem], limit: Int = 24) -> [BaseItem] {
        var seen = Set<String>()
        var out: [BaseItem] = []
        for t in tracks {
            guard let aid = t.AlbumId, !aid.isEmpty, seen.insert(aid).inserted else { continue }
            out.append(BaseItem.stub(id: aid, name: t.Album ?? t.Name, type: "MusicAlbum"))
            if out.count >= limit { break }
        }
        return out
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

    /// Re-probes the server while we believe we're offline, so we reconnect
    /// automatically the moment it answers — without depending on the network
    /// path flipping (it doesn't, when signal stays good). nil when online.
    private var probeTask: Task<Void, Never>?
    /// In-flight "is this failure real?" verification, so a burst of failing
    /// requests triggers only one probe.
    private var verifyTask: Task<Void, Never>?

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if !satisfied {
                    // No usable interface at all — definitely offline.
                    self.goOffline()
                } else if !self.isOnline {
                    // Interface came back; verify the server is actually
                    // reachable rather than optimistically claiming online.
                    self.startProbe(immediate: true)
                }
            }
        }
        monitor.start(queue: queue)
        NotificationCenter.default.addObserver(forName: Notification.Name("boleraDidLogout"),
                                               object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.stopProbing() }
        }
    }

    /// Call from any successful network request — the server is reachable.
    public func noteSuccess() {
        stopProbing()
        if !isOnline {
            isOnline = true
            reconnect.send()
        }
    }

    /// Call from a failed request. Only connectivity-class URLErrors are
    /// candidates (HTTP 4xx/5xx and decode errors mean the server IS reachable).
    /// A single failure does NOT drop us offline — a transient cellular blip or
    /// one slow response shouldn't blank the app — instead we confirm with a
    /// quick probe and only go offline if the server is genuinely unreachable.
    public func noteFailure(_ error: Error) {
        guard Self.isConnectivityError(error), isOnline,
              verifyTask == nil, probeTask == nil else { return }
        let base = AuthManager.shared.serverURL
        verifyTask = Task { [weak self] in
            let reachable = await Self.serverReachable(base: base)
            guard let self else { return }
            self.verifyTask = nil
            if !reachable { self.goOffline() }
        }
    }

    /// Flip offline and start re-probing the server until it answers.
    private func goOffline() {
        if isOnline { isOnline = false }
        startProbe(immediate: false)
    }

    /// Background loop that pings the server with backoff (3s → 30s) and flips
    /// back online the instant it responds. Runs only while offline.
    private func startProbe(immediate: Bool) {
        guard probeTask == nil else { return }
        verifyTask?.cancel(); verifyTask = nil
        probeTask = Task { [weak self] in
            var delayNs: UInt64 = immediate ? 0 : 3_000_000_000
            while !Task.isCancelled {
                if delayNs > 0 { try? await Task.sleep(nanoseconds: delayNs) }
                if Task.isCancelled { return }
                let base = self?.serverBase ?? nil
                if await Self.serverReachable(base: base) {
                    self?.recoverOnline()
                    return
                }
                delayNs = min(delayNs == 0 ? 3_000_000_000 : delayNs * 2, 30_000_000_000)
            }
        }
    }

    private var serverBase: URL? { AuthManager.shared.serverURL }

    private func recoverOnline() {
        probeTask = nil
        if !isOnline {
            isOnline = true
            reconnect.send()
        }
    }

    private func stopProbing() {
        probeTask?.cancel(); probeTask = nil
        verifyTask?.cancel(); verifyTask = nil
    }

    private static func isConnectivityError(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        switch u.code {
        case .notConnectedToInternet, .timedOut, .cannotConnectToHost,
             .networkConnectionLost, .cannotFindHost, .dnsLookupFailed,
             .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    /// Lightweight, unauthenticated reachability check against Jellyfin's public
    /// info endpoint. ANY HTTP response (even 401/404) means the server answered,
    /// so it's reachable; only a transport error (timeout, cannot-connect) counts
    /// as unreachable. NOTE: a LAN-only server (private 192.168.x.x address) is
    /// genuinely unreachable over cellular — this correctly stays offline there.
    static func serverReachable(base: URL?) async -> Bool {
        guard let base else { return false }
        var req = URLRequest(url: base.appendingPathComponent("System/Info/Public"))
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return resp is HTTPURLResponse
        } catch {
            return false
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
        // Cache at the EXACT maxWidth this platform's grid/list tiles request.
        // The image URL embeds the size, so a mismatch is a different cache key —
        // the prefetched image never gets reused and tiles re-download on scroll
        // (the "art popping in" seen on macOS, whose tiles ask for 320).
        #if os(macOS)
        let artistW = 320, albumW = 320
        #else
        let artistW = 180, albumW = 400
        #endif
        var urls: [URL] = []
        for a in artists {
            if let u = client.imageURL(for: a.Id, tag: a.ImageTags?["Primary"], maxWidth: artistW) { urls.append(u) }
        }
        for al in albums {
            if let u = client.imageURL(for: al.Id, tag: al.ImageTags?["Primary"], maxWidth: albumW) { urls.append(u) }
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
