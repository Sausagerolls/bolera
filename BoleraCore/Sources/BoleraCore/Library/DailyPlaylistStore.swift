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

    private static let cacheKey = "bolera.dailyPlaylists.cache.v8"
    private let artworkDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("DailyArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private var generating = false

    private init() {
        loadCachedPlaylists()
        loadCachedArtwork()
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

        // Compute a shared seed pool from the user's most-listened-to artists
        // over the past few days. Each theme draws seeds from this pool so
        // mixes reflect the user's recent taste.
        let recent = (try? await client.recentlyPlayed(limit: 200)) ?? []
        let recentAudio = await expandToAudio(recent, client: client)
        let topArtists = topArtistIds(from: recentAudio, count: 15)
        let topArtistTracks = recentAudio.filter { topArtists.contains(artistKey(for: $0)) }
        // Fallback: if user has no recent plays, fall back to per-theme fetcher.
        let sharedSeedPool: [BaseItem] = topArtistTracks.isEmpty ? recentAudio : topArtistTracks

        var built: [DailyPlaylist] = []
        for theme in themes {
            do {
                // Seed pool: shared recent-top-artists if available, else theme-specific.
                let poolForTheme: [BaseItem]
                if !sharedSeedPool.isEmpty {
                    poolForTheme = sharedSeedPool
                } else {
                    let pool = try await theme.fetcher(client)
                    poolForTheme = await expandToAudio(pool, client: client)
                }
                // Fewer seeds when Last.fm is driving — each seed contributes
                // a whole cluster of similar artists, so 3 seeds already
                // populate a 25-track playlist. Without Last.fm we still use
                // 6 seeds because instantMix per seed yields fewer hits.
                let seedCount = useLastFm ? 3 : 6
                let seeds = pickDiverseSeeds(poolForTheme, count: seedCount)
                guard !seeds.isEmpty else { continue }

                var combined: [BaseItem] = []
                var seenIds: Set<String> = []
                var perArtist: [String: Int] = [:]
                let maxPerArtist = useLastFm ? 3 : 2

                for seed in seeds {
                    var pool: [BaseItem] = []
                    if useLastFm, let lf = lastFm {
                        // Tonally-consistent pool: seed's own top tracks +
                        // top tracks from each Last.fm similar artist found
                        // in the user's library.
                        pool = await buildLastFmInformedPool(seed: seed,
                                                             client: client,
                                                             lastFm: lf)
                    }
                    // Augment with instantMix when Last.fm coverage is sparse
                    // (e.g. user's library has no overlap with the seed's
                    // similar-artist list). Keeps the playlist populated
                    // without breaking tonal direction.
                    if pool.count < 8 {
                        let mixRaw = (try? await client.instantMix(itemId: seed.Id, limit: 30)) ?? []
                        let mixAudio = await expandToAudio(mixRaw, client: client)
                        pool.append(contentsOf: mixAudio)
                    }

                    // Include seed itself first.
                    if seed.type == "Audio", seenIds.insert(seed.Id).inserted {
                        let key = artistKey(for: seed)
                        let c = perArtist[key] ?? 0
                        if c < maxPerArtist {
                            perArtist[key] = c + 1
                            combined.append(seed)
                        }
                    }
                    for t in pool where t.type == "Audio" && seenIds.insert(t.Id).inserted {
                        let key = artistKey(for: t)
                        let c = perArtist[key] ?? 0
                        if c < maxPerArtist {
                            perArtist[key] = c + 1
                            combined.append(t)
                        }
                    }
                }

                let trimmed = Array(combined.filter { $0.type == "Audio" }.shuffled().prefix(25))
                guard trimmed.count >= 4 else { continue }
                let playlist = DailyPlaylist(
                    name: theme.name,
                    theme: theme.id,
                    date: today,
                    tracks: trimmed
                )
                built.append(playlist)
            } catch is CancellationError {
                continue
            } catch let err as URLError where err.code == .cancelled {
                continue
            } catch {
                lastError = error.localizedDescription
            }
        }

        // Only overwrite when we actually produced something. If generation
        // was cancelled mid-flight (e.g. pull-to-refresh fired again),
        // preserve the existing playlists instead of clearing the section.
        guard !built.isEmpty else { return }

        playlists = built
        persistPlaylists()

        // Generate artwork (async, doesn't block UI).
        Task { await renderAllArtwork(auth: auth, client: client) }
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
        if let seedArtistId, !seedArtistId.isEmpty {
            artistsToHarvest.append((seedArtistId, seedArtistName))
        }

        if let similar = try? await lastFm.similarArtists(forName: seedArtistName, limit: 20) {
            for cand in similar {
                if artistsToHarvest.count >= 7 { break }
                let needle = cand.name.folding(options: .diacriticInsensitive, locale: .current)
                let hits = (try? await client.artists(search: cand.name)) ?? []
                if let match = hits.first(where: {
                    $0.type == "MusicArtist" &&
                    $0.Name.folding(options: .diacriticInsensitive, locale: .current)
                        .compare(needle, options: .caseInsensitive) == .orderedSame
                }) {
                    artistsToHarvest.append((match.Id, match.Name))
                }
            }
        }

        var pool: [BaseItem] = []
        for (id, name) in artistsToHarvest {
            if let tracks = try? await client.topTracksForArtist(id, name: name, limit: 8) {
                pool.append(contentsOf: tracks.filter { $0.type == "Audio" })
            }
        }
        return pool
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
        playlists = decoded
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
