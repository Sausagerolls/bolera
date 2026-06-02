import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import CoreGraphics
import CoreText

// MARK: - Model

public struct DailyPlaylist: Codable, Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let theme: String
    public let date: String  // yyyy-MM-dd
    public let tracks: [BaseItem]

    public init(id: UUID = UUID(), name: String, theme: String, date: String, tracks: [BaseItem]) {
        self.id = id
        self.name = name
        self.theme = theme
        self.date = date
        self.tracks = tracks
    }
}

// MARK: - Store

/// Generates a small set of themed playlists per day (deterministic by date),
/// caches them + their composite artwork to disk, and exposes both for the
/// Home screens to display.
@MainActor
public final class DailyPlaylistStore: ObservableObject {

    public static let shared = DailyPlaylistStore()

    @Published public private(set) var playlists: [DailyPlaylist] = []
    @Published public private(set) var artworkByPlaylist: [UUID: PlatformImage] = [:]
    @Published public private(set) var lastError: String?
    @Published public private(set) var isGenerating: Bool = false

    // v10: mixes are now single-artist-anchored (cohesive) — invalidate the
    // old multi-seed "mashup" caches so they regenerate with the new logic.
    private static let cacheKey = "bolera.dailyPlaylists.cache.v10"
    private let artworkDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("DailyArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private var generating: Bool {
        get { isGenerating }
        set { isGenerating = newValue }
    }

    private init() {
        loadCachedPlaylists()
        loadCachedArtwork()
        NotificationCenter.default.addObserver(
            forName: Notification.Name("boleraDidLogout"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.clear() }
    }

    /// Wipes cached playlists + artwork. Called when the user signs out
    /// or switches Jellyfin servers — leftover mixes from the previous
    /// server would otherwise still appear on Home.
    public func clear() {
        playlists = []
        artworkByPlaylist = [:]
        lastError = nil
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        try? FileManager.default.removeItem(at: artworkDir)
        try? FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
    }

    /// Generates today's playlists if cache is empty or from an older date.
    /// Safe to call repeatedly — no-ops when up-to-date.
    /// `lastFm` is optional: when configured, similar-artist lookups via
    /// Last.fm tighten each mix's tonal consistency.
    public func refreshIfNeeded(client: JellyfinClient,
                                auth: AuthManager,
                                lastFm: LastFmService? = nil) async {
        let today = Self.dateString(Date())
        if !playlists.isEmpty, playlists.first?.date == today {
            return
        }
        guard !generating else { return }
        generating = true
        defer { generating = false }
        await generate(client: client, auth: auth, lastFm: lastFm, today: today)
    }

    /// Force-regeneration (debug / manual refresh).
    /// Detaches from the caller's task so SwiftUI's refreshable scope
    /// cancellation doesn't kill mid-generation network calls.
    public func regenerate(client: JellyfinClient,
                           auth: AuthManager,
                           lastFm: LastFmService? = nil) async {
        guard !generating else { return }
        playlists = []
        artworkByPlaylist = [:]
        generating = true
        defer { generating = false }
        let today = Self.dateString(Date())
        let detached = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.generate(client: client, auth: auth, lastFm: lastFm, today: today)
        }
        await detached.value
    }

    public func tracks(forPlaylist id: UUID) -> [BaseItem]? {
        playlists.first(where: { $0.id == id })?.tracks
    }

    // MARK: - Generation

    private func generate(client: JellyfinClient,
                          auth: AuthManager,
                          lastFm: LastFmService?,
                          today: String) async {
        let themes = Self.pickThemes(forDate: today)
        let useLastFm = lastFm?.hasAppCredentials ?? false

        // Seed pool = the user's most-played artists recently.
        let recent = (try? await client.recentlyPlayed(limit: 200)) ?? []
        let recentAudio = await expandToAudio(recent, client: client)
        let topArtists = topArtistIds(from: recentAudio, count: 15)
        let topArtistTracks = recentAudio.filter { topArtists.contains(artistKey(for: $0)) }
        var seedPool: [BaseItem] = topArtistTracks.isEmpty ? recentAudio : topArtistTracks
        if seedPool.isEmpty {
            let favs = (try? await client.favorites(type: "Audio", limit: 100)) ?? []
            seedPool = await expandToAudio(favs, client: client)
        }

        // ONE distinct anchor artist per mix. Each mix is then that anchor plus
        // its Last.fm-similar artists — tonally cohesive — instead of mashing
        // several unrelated seeds together (which put Alestorm and Admiral
        // Fallow in the same mix). Mixes build in parallel; main-actor network
        // awaits overlap, so wall time ≈ a single mix's.
        let seeds = pickDiverseSeeds(seedPool, count: themes.count)
        guard !seeds.isEmpty else { return }
        // Refresh the live-album set so the live filter (applied per mix below)
        // reflects the user's current tag.
        await LiveFilterStore.shared.refresh(client: client)
        let snapshotIgnore = IgnoredTracksStore.shared
        var built = await withTaskGroup(of: (Int, DailyPlaylist?).self) { group -> [DailyPlaylist] in
            for (idx, seed) in seeds.enumerated() {
                let themeId = themes[idx].id
                group.addTask { @MainActor in
                    let pl = await self.buildPlaylist(
                        seed: seed,
                        themeId: themeId,
                        useLastFm: useLastFm,
                        lastFm: lastFm,
                        client: client,
                        ignore: snapshotIgnore,
                        today: today
                    )
                    return (idx, pl)
                }
            }
            var slots: [(Int, DailyPlaylist)] = []
            for await (idx, pl) in group {
                if let pl { slots.append((idx, pl)) }
            }
            slots.sort { $0.0 < $1.0 }   // preserve seed order
            return slots.map { $0.1 }
        }

        // Only overwrite when we actually produced something. If generation
        // was cancelled mid-flight (e.g. pull-to-refresh fired again),
        // preserve the existing playlists instead of clearing the section.
        guard !built.isEmpty else { return }

        // Name each mix after the artist it actually leans on ("Snow Patrol
        // Mix", "Slipknot Mix") instead of a generic time-of-day theme.
        built = nameMixesByArtist(built)
        playlists = built
        persistPlaylists()

        // Generate artwork (async, doesn't block UI).
        Task { await renderAllArtwork(auth: auth, client: client) }
    }

    /// Build ONE cohesive mix anchored on a single seed artist: the artist's
    /// own tracks plus its Last.fm-similar artists, weighted toward the anchor
    /// so the mix stays tonally consistent (no genre whiplash) and is clearly
    /// named after it. Pure async — safe to run concurrently with other mixes.
    private func buildPlaylist(seed: BaseItem,
                               themeId: String,
                               useLastFm: Bool,
                               lastFm: LastFmService?,
                               client: JellyfinClient,
                               ignore: IgnoredTracksStore,
                               today: String) async -> DailyPlaylist? {
        var pool: [BaseItem] = []
        if useLastFm, let lf = lastFm {
            pool = await buildLastFmInformedPool(seed: seed, client: client, lastFm: lf)
        }
        if pool.count < 12 {
            // Last.fm unavailable / thin — Jellyfin's instant mix is genre &
            // audio-feature based, so it stays in the seed's lane too.
            let mixRaw = (try? await client.instantMix(itemId: seed.Id, limit: 40)) ?? []
            pool += await expandToAudio(mixRaw, client: client)
        }

        let seedKey = artistKey(for: seed)
        var combined: [BaseItem] = []
        var seenIds: Set<String> = []
        var perArtist: [String: Int] = [:]
        func tryAdd(_ t: BaseItem) {
            guard t.type == "Audio", seenIds.insert(t.Id).inserted else { return }
            let key = artistKey(for: t)
            // Anchor-heavy: more from the seed artist so it leads (and names) the
            // mix; a few each from its similar artists for variety.
            let cap = (key == seedKey) ? 5 : 3
            let c = perArtist[key] ?? 0
            if c < cap { perArtist[key] = c + 1; combined.append(t) }
        }
        tryAdd(seed)
        for t in pool { tryAdd(t) }

        let allowed = LiveFilterStore.shared.filter(ignore.filter(combined))
        let trimmed = Array(allowed.filter { $0.type == "Audio" }.shuffled().prefix(25))
        guard trimmed.count >= 4 else { return nil }
        return DailyPlaylist(
            name: "\(seed.primaryArtistName) Mix",
            theme: themeId,
            date: today,
            tracks: trimmed
        )
    }

    // MARK: - Endless extension

    /// A `AudioPlayer.playMix` extender that keeps `mix` going: each time the
    /// queue nears its end it fetches more tracks cohesive with the mix's anchor
    /// artist, excluding whatever's already been queued. Builds its own client /
    /// Last.fm from the shared session so call sites don't have to thread them.
    public func extender(for mix: DailyPlaylist) -> (Set<String>) async -> [BaseItem] {
        return { [weak self] existing in
            guard let self, let url = AuthManager.shared.serverURL else { return [] }
            let client = JellyfinClient(baseURL: url, auth: AuthManager.shared)
            return await self.moreTracks(forMix: mix, excluding: existing,
                                         client: client, lastFm: LastFmService.shared)
        }
    }

    /// More tracks for an in-progress mix — anchored on its dominant artist,
    /// not already in `existing`. Draws from Last.fm-similar artists plus
    /// Jellyfin's instant-mix radio (a renewable pool, so repeated top-ups keep
    /// finding new tracks in the same lane), throttled per artist for cohesion.
    func moreTracks(forMix mix: DailyPlaylist, excluding existing: Set<String>,
                    client: JellyfinClient, lastFm: LastFmService?) async -> [BaseItem] {
        let dominant = rankedArtistNames(in: mix.tracks).first
        let seed = mix.tracks.first(where: { $0.primaryArtistName == dominant }) ?? mix.tracks.first
        guard let seed else { return [] }

        var pool: [BaseItem] = []
        if lastFm?.hasAppCredentials == true, let lf = lastFm {
            pool = await buildLastFmInformedPool(seed: seed, client: client, lastFm: lf)
        }
        let radio = (try? await client.instantMix(itemId: seed.Id, limit: 60)) ?? []
        pool += await expandToAudio(radio, client: client)

        let ignore = IgnoredTracksStore.shared
        let seedKey = artistKey(for: seed)
        var seen = existing
        var perArtist: [String: Int] = [:]
        var out: [BaseItem] = []
        for t in LiveFilterStore.shared.filter(ignore.filter(pool)).shuffled() where t.type == "Audio" {
            guard seen.insert(t.Id).inserted else { continue }
            let k = artistKey(for: t)
            let cap = (k == seedKey) ? 4 : 3
            let c = perArtist[k] ?? 0
            if c < cap { perArtist[k] = c + 1; out.append(t) }
            if out.count >= 20 { break }
        }
        return out
    }

    /// Tallies appearance frequency of each primary artist in `tracks` and
    /// returns the top `count` artist keys.
    private func topArtistIds(from tracks: [BaseItem], count: Int) -> Set<String> {
        var tally: [String: Int] = [:]
        for t in tracks {
            let key = artistKey(for: t)
            guard key != "_" else { continue }
            tally[key, default: 0] += 1
        }
        let sorted = tally.sorted { $0.value > $1.value }
        return Set(sorted.prefix(count).map { $0.key })
    }

    /// Primary-artist names in a mix, ranked by how many tracks each
    /// contributes (ties broken alphabetically for stable, repeatable names).
    private func rankedArtistNames(in tracks: [BaseItem]) -> [String] {
        var tally: [String: Int] = [:]
        for t in tracks {
            let n = t.primaryArtistName
            guard !n.isEmpty else { continue }
            tally[n, default: 0] += 1
        }
        return tally.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.map { $0.key }
    }

    /// Renames each mix after the artist it's built around — "<Artist> Mix" —
    /// using the most-represented artist whose name isn't already taken by
    /// another mix today (falls through to the next artist, then a numeric
    /// suffix; keeps the original theme name only if a mix has no artist info).
    private func nameMixesByArtist(_ playlists: [DailyPlaylist]) -> [DailyPlaylist] {
        var used = Set<String>()
        return playlists.map { pl in
            let ranked = rankedArtistNames(in: pl.tracks)
            var name = pl.name
            if let fresh = ranked.first(where: { !used.contains("\($0) Mix") }) {
                name = "\(fresh) Mix"
            } else if let top = ranked.first {
                var candidate = "\(top) Mix"; var i = 2
                while used.contains(candidate) { candidate = "\(top) Mix \(i)"; i += 1 }
                name = candidate
            }
            used.insert(name)
            return DailyPlaylist(id: pl.id, name: name, theme: pl.theme, date: pl.date, tracks: pl.tracks)
        }
    }

    /// Stable key per primary artist, for diversity throttling.
    private func artistKey(for track: BaseItem) -> String {
        track.AlbumArtists?.first?.Id
            ?? track.ArtistItems?.first?.Id
            ?? track.AlbumArtist
            ?? "_"
    }

    /// Pick up to `count` seed tracks from the pool, prioritizing distinct artists.
    private func pickDiverseSeeds(_ pool: [BaseItem], count: Int) -> [BaseItem] {
        let shuffled = pool.shuffled()
        var seeds: [BaseItem] = []
        var artistsSeen: Set<String> = []
        for t in shuffled where t.type == "Audio" {
            let key = artistKey(for: t)
            if artistsSeen.insert(key).inserted {
                seeds.append(t)
                if seeds.count >= count { break }
            }
        }
        // If pool was tiny / single-artist, fall back to whatever exists.
        if seeds.isEmpty {
            seeds = Array(shuffled.filter { $0.type == "Audio" }.prefix(count))
        }
        return seeds
    }

    /// Build a tonally-consistent track pool for a seed using Last.fm.
    /// Pulls Last.fm's similar artists for the seed's primary artist, resolves
    /// each against the user's Jellyfin library, then collects the top
    /// tracks for the seed artist + each matched similar artist.
    private func buildLastFmInformedPool(seed: BaseItem,
                                         client: JellyfinClient,
                                         lastFm: LastFmService) async -> [BaseItem] {
        let seedArtistName = seed.primaryArtistName
        let seedArtistId   = seed.AlbumArtists?.first?.Id ?? seed.ArtistItems?.first?.Id
        guard !seedArtistName.isEmpty else { return [] }

        var artistsToHarvest: [(id: String, name: String)] = []
        var seenArtistIds = Set<String>()
        if let seedArtistId, !seedArtistId.isEmpty {
            artistsToHarvest.append((seedArtistId, seedArtistName))
            seenArtistIds.insert(seedArtistId)
        }

        // Resolve Last.fm's similar artists against the user's library. The
        // per-candidate Jellyfin searches run CONCURRENTLY — their network I/O
        // overlaps on the main actor instead of running one-at-a-time, which is
        // what made mix generation take minutes over a slow/remote link.
        let similar = (try? await lastFm.similarArtists(forName: seedArtistName, limit: 12)) ?? []
        let candidates = Array(similar.prefix(10))
        let matches: [(id: String, name: String)] = await withTaskGroup(of: (Int, (id: String, name: String)?).self) { group in
            for (i, cand) in candidates.enumerated() {
                group.addTask { @MainActor in
                    let needle = cand.name.folding(options: .diacriticInsensitive, locale: .current)
                    let hits = (try? await client.artists(search: cand.name)) ?? []
                    if let match = hits.first(where: {
                        $0.type == "MusicArtist" &&
                        $0.Name.folding(options: .diacriticInsensitive, locale: .current)
                            .compare(needle, options: .caseInsensitive) == .orderedSame
                    }) {
                        return (i, (match.Id, match.Name))
                    }
                    return (i, nil)
                }
            }
            var found: [(Int, (id: String, name: String))] = []
            for await (i, m) in group { if let m { found.append((i, m)) } }
            return found.sorted { $0.0 < $1.0 }.map { $0.1 }   // preserve Last.fm rank
        }
        for m in matches {
            if artistsToHarvest.count >= 7 { break }
            if seenArtistIds.insert(m.id).inserted { artistsToHarvest.append(m) }
        }

        // Fetch each artist's top tracks concurrently too.
        let pools: [[BaseItem]] = await withTaskGroup(of: [BaseItem].self) { group in
            for (id, name) in artistsToHarvest {
                group.addTask { @MainActor in
                    let tracks = (try? await client.topTracksForArtist(id, name: name, limit: 8)) ?? []
                    return tracks.filter { $0.type == "Audio" }
                }
            }
            var all: [[BaseItem]] = []
            for await p in group { all.append(p) }
            return all
        }
        return pools.flatMap { $0 }
    }

    /// Expand a mixed pool of items (which may contain albums + tracks) into
    /// a flat list of Audio tracks. Albums are expanded via songs(parentId:).
    private func expandToAudio(_ items: [BaseItem], client: JellyfinClient) async -> [BaseItem] {
        var out: [BaseItem] = []
        for item in items {
            if item.type == "Audio" {
                out.append(item)
            } else if item.type == "MusicAlbum" {
                if let songs = try? await client.songs(parentId: item.Id) {
                    out.append(contentsOf: songs.filter { $0.type == "Audio" })
                }
            }
            // Cap expansion early to avoid huge fan-out on big libraries.
            if out.count >= 300 { break }
        }
        return out
    }

    // MARK: - Artwork

    private func renderAllArtwork(auth: AuthManager, client: JellyfinClient) async {
        for playlist in playlists {
            if let existing = loadArtworkFromDisk(id: playlist.id) {
                artworkByPlaylist[playlist.id] = existing
                continue
            }
            let img = await DailyArtworkRenderer.render(
                playlist: playlist,
                auth: auth,
                client: client
            )
            if let img {
                artworkByPlaylist[playlist.id] = img
                saveArtworkToDisk(img, id: playlist.id)
            }
        }
    }

    private func artworkPath(id: UUID) -> URL {
        artworkDir.appendingPathComponent("\(id.uuidString).png")
    }

    private func saveArtworkToDisk(_ image: PlatformImage, id: UUID) {
        let url = artworkPath(id: id)
        #if canImport(UIKit)
        if let data = image.pngData() {
            try? data.write(to: url, options: .atomic)
        }
        #elseif canImport(AppKit)
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url, options: .atomic)
        }
        #endif
    }

    private func loadArtworkFromDisk(id: UUID) -> PlatformImage? {
        let url = artworkPath(id: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return PlatformImage(data: data)
    }

    private func loadCachedArtwork() {
        // Lazy — actual loading happens per-playlist as Home reads them.
    }

    // MARK: - Persistence

    private func persistPlaylists() {
        if let data = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    private func loadCachedPlaylists() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let decoded = try? JSONDecoder().decode([DailyPlaylist].self, from: data) else {
            return
        }
        // Rename on load too, so mixes already cached under an older build
        // (generic time-of-day names) pick up the new artist names right away
        // — no waiting for the next day's regeneration. Ids are preserved, so
        // artwork still hydrates below.
        playlists = nameMixesByArtist(decoded)
        // Hydrate artwork cache from disk lazily.
        for p in decoded {
            if let img = loadArtworkFromDisk(id: p.id) {
                artworkByPlaylist[p.id] = img
            }
        }
    }

    // MARK: - Theme bank

    private struct Theme: Sendable {
        let id: String
        let name: String
        let fetcher: @Sendable (JellyfinClient) async throws -> [BaseItem]
    }

    /// Pick 4 themes for the given date. Time-of-day + day-of-week tinted, with
    /// stable selection within the day (date-seeded).
    private static func pickThemes(forDate date: String) -> [Theme] {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let weekday = cal.component(.weekday, from: now)  // 1=Sun, 7=Sat
        let hour = cal.component(.hour, from: now)

        // Time-of-day primary.
        let timeTheme: Theme = {
            switch hour {
            case 5..<11:  return Theme(id: "morning", name: "Bright Morning",
                                       fetcher: { try await $0.recentlyPlayed(limit: 60) })
            case 11..<14: return Theme(id: "midday", name: "Midday Lift",
                                       fetcher: { try await $0.favorites(type: "Audio", limit: 60) })
            case 14..<18: return Theme(id: "afternoon", name: "Afternoon Sessions",
                                       fetcher: { try await $0.frequentlyPlayed(limit: 60) })
            case 18..<22: return Theme(id: "evening", name: "Evening Wind-Down",
                                       fetcher: { try await $0.favorites(type: "Audio", limit: 60) })
            default:      return Theme(id: "latenight", name: "Late Night Vibes",
                                       fetcher: { try await $0.recentlyPlayed(limit: 60) })
            }
        }()

        // Day-of-week tinted theme.
        let dayTheme: Theme = {
            switch weekday {
            case 1: return Theme(id: "sun", name: "Lazy Sunday",
                                 fetcher: { try await $0.favorites(type: "Audio", limit: 60) })
            case 2: return Theme(id: "mon", name: "Monday Motivation",
                                 fetcher: { try await $0.frequentlyPlayed(limit: 60) })
            case 3: return Theme(id: "tue", name: "Tuesday Sessions",
                                 fetcher: { try await $0.recentlyPlayed(limit: 60) })
            case 4: return Theme(id: "wed", name: "Hump Day Energy",
                                 fetcher: { try await $0.frequentlyPlayed(limit: 60) })
            case 5: return Theme(id: "thu", name: "Throwback Thursday",
                                 fetcher: { try await $0.frequentlyPlayed(limit: 80) })
            case 6: return Theme(id: "fri", name: "Happy Friday",
                                 fetcher: { try await $0.favorites(type: "Audio", limit: 60) })
            case 7: return Theme(id: "sat", name: "Saturday Spin",
                                 fetcher: { try await $0.recentlyPlayed(limit: 60) })
            default: return Theme(id: "any", name: "Daily Mix",
                                  fetcher: { try await $0.recentlyPlayed(limit: 60) })
            }
        }()

        let stableExtras: [Theme] = [
            Theme(id: "discover", name: "Fresh Discoveries",
                  fetcher: { try await $0.recentlyAdded(limit: 60) }),
            Theme(id: "deepcuts", name: "Deep Cuts",
                  fetcher: { try await $0.favorites(type: "Audio", limit: 80) }),
            Theme(id: "toplays", name: "Most Loved",
                  fetcher: { try await $0.frequentlyPlayed(limit: 60) }),
            Theme(id: "discover2", name: "Recently Found",
                  fetcher: { try await $0.recentlyAdded(limit: 60) })
        ]

        // Deterministic shuffle per date for the extras pick.
        var seed = UInt64(abs(date.hashValue))
        var extras = stableExtras
        for i in stride(from: extras.count - 1, to: 0, by: -1) {
            seed = seed &* 2862933555777941757 &+ 3037000493
            let j = Int(seed % UInt64(i + 1))
            extras.swapAt(i, j)
        }

        var picks: [Theme] = [timeTheme, dayTheme]
        // Avoid duplicating ids
        for e in extras {
            if !picks.contains(where: { $0.id == e.id }) {
                picks.append(e)
            }
            if picks.count >= 4 { break }
        }
        return picks
    }

    private static func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: d)
    }
}
