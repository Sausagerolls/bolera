import SwiftUI
import BoleraCore
#if canImport(FoundationModels)
import FoundationModels
#endif

struct HomeView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var daily: DailyPlaylistStore
    @EnvironmentObject var lastFm: LastFmService
    @EnvironmentObject var nowPlaying: PlayerNowPlayingState
    @EnvironmentObject var connectivity: ConnectivityStore
    @ObservedObject private var downloads = DownloadManager.shared
    @AppStorage("bolera.ai.moodMixEnabled") private var moodMixEnabled: Bool = true
    @State private var showMoodMix = false
    @State private var recentsRefresh: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if connectivity.isOnline {
                    if let err = library.lastError {
                        Text("API error: \(err)")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(Color.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal)
                    }

                    if moodMixEnabled {
                        moodMixCard
                    }

                    if !daily.playlists.isEmpty || daily.isGenerating {
                        dailySection
                    }

                    if !library.recentlyPlayed.isEmpty {
                        section(title: "Recent Tracks", items: library.recentlyPlayed)
                    }
                    if !library.recentlyPlayedAlbums.isEmpty {
                        section(title: "Recent Albums", items: library.recentlyPlayedAlbums)
                    }
                    if !library.topPlayedTracks.isEmpty {
                        section(title: "Top Played Tracks", items: library.topPlayedTracks)
                    }
                    if !library.recentlyAdded.isEmpty {
                        section(title: "Recently Added", items: library.recentlyAdded)
                    }
                    if !library.favoriteAlbums.isEmpty {
                        section(title: "Favorites", items: library.favoriteAlbums)
                    }
                } else {
                    offlineContent
                }
                Color.clear.frame(height: 100)
            }
            .padding(.vertical)
        }
        .navigationTitle("Home")
        .navigationDestination(for: BaseItem.self) { item in
            if item.type == "MusicArtist" {
                ArtistDetailView(artist: item)
            } else {
                AlbumDetailView(album: item)
            }
        }
        .refreshable { await reload(force: true) }
        .task { await reload(force: false) }
        .onReceive(connectivity.didReconnect) { _ in
            Task { await reload(force: false) }
        }
        .onChange(of: nowPlaying.current?.Id) { _, _ in
            // Recently Played / On Repeat are server-derived. HomeView's
            // `.task` runs once and the Home tab stays alive in the TabView,
            // so returning to it after playing wouldn't re-fetch — recents
            // stayed stale until app relaunch. Re-fetch shortly after each
            // track change (debounced) so they reflect what was just played.
            recentsRefresh?.cancel()
            recentsRefresh = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let url = auth.serverURL else { return }
                await library.refresh(client: JellyfinClient(baseURL: url, auth: auth))
            }
        }
        .sheet(isPresented: $showMoodMix) {
            MoodMixSheet().environmentObject(auth)
        }
    }

    /// Entry point for the Apple Intelligence-driven mood mix. Renders as a
    /// gradient banner above Daily Mixes; tap → opens the prompt sheet.
    private var moodMixCard: some View {
        Button {
            showMoodMix = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.18), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Make a Mix").font(.headline).foregroundStyle(.white)
                    Text("Describe a mood, get a playlist")
                        .font(.caption).foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(16)
            .background(
                LinearGradient(colors: [Color.accentColor, Color.purple, Color.indigo],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }

    private func reload(force: Bool) async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        await library.refresh(client: client)
        if force {
            await daily.regenerate(client: client, auth: auth, lastFm: lastFm)
        } else {
            await daily.refreshIfNeeded(client: client, auth: auth, lastFm: lastFm)
        }
    }

    /// Downloaded-only content shown when the server is unreachable. Reuses the
    /// existing `section`/`homeTile` helpers (album/artist tiles navigate;
    /// Audio tiles play offline).
    @ViewBuilder
    private var offlineContent: some View {
        let artists = downloads.downloadedArtistReps()
        let albums  = downloads.downloadedAlbumReps()
        let tracks  = downloads.individuallyDownloadedTracks()
        if artists.isEmpty && albums.isEmpty && tracks.isEmpty {
            ContentUnavailableView(
                "You're Offline",
                systemImage: "wifi.slash",
                description: Text("Download music while connected to listen offline."))
                .frame(minHeight: 300)
        } else {
            if !albums.isEmpty  { section(title: "Downloaded Albums",  items: albums) }
            if !artists.isEmpty { section(title: "Downloaded Artists", items: artists) }
            if !tracks.isEmpty  { section(title: "Downloaded Tracks",  items: tracks) }
        }
    }

    // MARK: - Daily section

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Daily Mixes").font(.title2.bold())
                if daily.isGenerating {
                    ProgressView().controlSize(.small)
                    Text("Generating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            if !daily.playlists.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(daily.playlists) { playlist in
                            DailyPlaylistTile(playlist: playlist)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    @ViewBuilder
    private func section(title: String, items: [BaseItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(items) { item in
                        homeTile(item)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func homeTile(_ item: BaseItem) -> some View {
        if item.type == "Audio" {
            Button {
                AudioPlayer.shared.play(items: [item])
            } label: {
                tileContent(item)
            }
            .buttonStyle(.plain)
            .trackContextMenu(item)
        } else {
            NavigationLink(value: item) {
                tileContent(item)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if item.type == "MusicAlbum" { IgnoreAlbumToggleButton(item: item) }
                else if item.type == "MusicArtist" { IgnoreArtistToggleButton(item: item) }
            }
        }
    }

    private func tileContent(_ item: BaseItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            JellyfinImage(itemId: item.artworkItemId, tag: item.artworkTag, maxWidth: 400, cornerRadius: 10)
                .frame(width: 150, height: 150)
            Text(item.Name).font(.subheadline).lineLimit(1)
            Text(item.primaryArtistName.isEmpty ? (item.Album ?? "") : item.primaryArtistName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
    }
}

// MARK: - Daily playlist tile

struct DailyPlaylistTile: View {
    let playlist: DailyPlaylist
    @EnvironmentObject var daily: DailyPlaylistStore

    private let tileWidth: CGFloat = 225  // 1.5x album tile width
    private let tileHeight: CGFloat = 150

    var body: some View {
        Button {
            AudioPlayer.shared.playMix(items: playlist.tracks, extender: daily.extender(for: playlist))
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let img = daily.artworkByPlaylist[playlist.id] {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(colors: [Color.accentColor.opacity(0.4), .black.opacity(0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(playlist.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(12)
                }
            }
            .frame(width: tileWidth, height: tileHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mood Mix (Apple Intelligence)

/// Foundation Models–backed playlist generator. The model expands a free-text
/// mood phrase into a short set of music genres + an optional decade hint;
/// Bolera then queries Jellyfin for tracks matching those genres and
/// (optionally) the decade window. Falls back gracefully on devices without
/// Apple Intelligence by surfacing an unavailable state.
struct MoodMixSheet: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) var dismiss

    @State private var prompt: String = ""
    @State private var loading = false
    @State private var error: String?
    @State private var tracks: [BaseItem] = []
    @State private var moodLabel: String = ""

    private let suggestions = [
        "Late-night drive in the rain",
        "Sunday morning coffee",
        "Throwback house party",
        "Focus & deep work",
        "Working out, high energy"
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(red: 0.06, green: 0.05, blue: 0.12),
                                        Color(red: 0.10, green: 0.05, blue: 0.18)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        inputField
                        suggestionRow
                        if let error {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 4)
                        }
                        if loading {
                            HStack {
                                ProgressView()
                                Text("Asking Apple Intelligence…")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 30)
                        }
                        if !tracks.isEmpty {
                            resultHeader
                            resultList
                        }
                        Color.clear.frame(height: 40)
                    }
                    .padding()
                }
            }
            .navigationTitle("Make a Mix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("What are you in the mood for?")
                    .font(.title3.bold())
            }
            Text("Describe a vibe, an activity, a memory — the model picks genres and Bolera builds the playlist from your library.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !LastFmService.shared.hasAppCredentials || !LastFmService.shared.isAuthenticated {
                lastFmHint
            }
        }
    }

    /// Inline nudge promoting Last.fm — results are dramatically better
    /// once the user signs in (curated tag→artist data instead of just
    /// Jellyfin genre tags).
    private var lastFmHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect Last.fm for much better mixes")
                    .font(.caption.weight(.semibold))
                Text("Tag→artist matching gives far richer, more tonally consistent results than genre-only search. Set up in Settings → Last.fm.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var inputField: some View {
        HStack(spacing: 10) {
            TextField("e.g. windows-down at sunset", text: $prompt, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.go)
                .onSubmit { Task { await generate() } }
            Button {
                Task { await generate() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
            }
            .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || loading)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button {
                        prompt = s
                        Task { await generate() }
                    } label: {
                        Text(s)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var resultHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(moodLabel.isEmpty ? "Your Mix" : moodLabel)
                    .font(.headline)
                Text("\(tracks.count) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                player.play(items: tracks)
                dismiss()
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.top, 10)
    }

    private var resultList: some View {
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                Button {
                    player.play(items: tracks, startAt: idx)
                    dismiss()
                } label: {
                    HStack {
                        Text("\(idx + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.Name).lineLimit(1)
                            Text(track.primaryArtistName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if idx < tracks.count - 1 {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Generation

    private func generate() async {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        loading = true
        error = nil
        tracks = []
        defer { loading = false }
        await MoodMixGenerator.shared.generate(
            prompt: p,
            auth: auth,
            onResult: { mood, items in
                self.moodLabel = mood
                self.tracks = items
            },
            onError: { self.error = $0 }
        )
    }
}

/// Wraps the Foundation Models call and the matching step.
///
/// When Last.fm is configured we follow this pipeline:
///   1. LLM expands the user's phrase to Last.fm-style tags
///      (genres + mood adjectives) + an optional decade hint.
///   2. For each tag → `tag.getTopArtists` on Last.fm (curated list of
///      artists strongly associated with that tag worldwide).
///   3. Resolve each Last.fm artist name to a Jellyfin MusicArtist in
///      the user's library (diacritic-insensitive name search).
///   4. For each resolved artist, fetch their top tracks from Jellyfin.
///   5. Apply decade filter (if it leaves a reasonable pool), cap per
///      artist for diversity, shuffle, trim to 25.
///
/// When Last.fm isn't configured we fall back to genre tags only and use
/// Jellyfin's own `Genres` query — works but is much sparser since track
/// genre tagging varies wildly between libraries.
@MainActor
final class MoodMixGenerator {
    static let shared = MoodMixGenerator()

    func generate(prompt: String,
                  auth: AuthManager,
                  onResult: @escaping (_ mood: String, _ tracks: [BaseItem]) -> Void,
                  onError: @escaping (String) -> Void) async {
        guard let serverURL = auth.serverURL else {
            onError("Not signed in to a Jellyfin server"); return
        }
        let analysis: MoodAnalysis
        do {
            analysis = try await analyse(prompt: prompt)
        } catch let e as MoodMixError {
            onError(e.message); return
        } catch {
            onError(error.localizedDescription); return
        }

        let client = JellyfinClient(baseURL: serverURL, auth: auth)
        let lastFm = LastFmService.shared

        print("[MoodMix] prompt=\(prompt) → tags=\(analysis.tags) decade=\(analysis.decade) mood=\(analysis.mood)")

        var combined: [BaseItem] = []
        var seenTrackIds: Set<String> = []

        // Always run both pipelines and combine — gives the widest pool
        // and protects against any one source coming back empty.
        if lastFm.hasAppCredentials {
            let viaLastFm = await buildViaLastFm(
                analysis: analysis,
                lastFm: lastFm,
                client: client,
                seenTrackIds: &seenTrackIds
            )
            print("[MoodMix] Last.fm pool: \(viaLastFm.count) tracks")
            combined.append(contentsOf: viaLastFm)
        }

        let viaGenres = await buildViaJellyfinGenres(
            analysis: analysis,
            client: client,
            seenTrackIds: &seenTrackIds
        )
        print("[MoodMix] Jellyfin genre pool: \(viaGenres.count) tracks")
        combined.append(contentsOf: viaGenres)

        // Tertiary source — Last.fm tag.getTopTracks. Returns specific
        // tracks tagged with each mood/genre worldwide. Match by title +
        // artist against the user's library. Catches mood-only tags like
        // "morning" / "chill" where the top-artist endpoint produced no
        // library overlap.
        if lastFm.hasAppCredentials && combined.count < 10 {
            let viaTagTracks = await buildViaLastFmTagTracks(
                analysis: analysis,
                lastFm: lastFm,
                client: client,
                seenTrackIds: &seenTrackIds
            )
            print("[MoodMix] Last.fm tag-tracks pool: \(viaTagTracks.count) tracks")
            combined.append(contentsOf: viaTagTracks)
        }

        // Drop tracks the user has explicitly ignored (or any track whose
        // artist or album sits on the ignore lists), and live recordings when
        // the user has chosen to exclude them.
        combined = LibraryVisibilityStore.shared.filter(LiveFilterStore.shared.filter(IgnoredTracksStore.shared.filter(combined)))

        // Optional decade filter — only apply if it leaves a healthy pool
        // AND doesn't shrink the result by more than 60%. Decade is a soft
        // preference; a niche decade shouldn't gut an otherwise good mix.
        if let range = decadeRange(analysis.decade) {
            let filtered = combined.filter { ($0.ProductionYear).map(range.contains) ?? false }
            let keepRatio = Double(filtered.count) / Double(max(1, combined.count))
            if filtered.count >= 15 && keepRatio >= 0.4 { combined = filtered }
        }
        // Diversity cap so one heavy-tagged artist doesn't dominate.
        var perArtist: [String: Int] = [:]
        let capped = combined.shuffled().filter { t in
            let key = t.primaryArtistName.lowercased()
            let c = perArtist[key] ?? 0
            if c >= 4 { return false }
            perArtist[key] = c + 1
            return true
        }
        let final = Array(capped.prefix(25))
        print("[MoodMix] combined=\(combined.count) → final=\(final.count)")
        if final.isEmpty {
            onError("No matching tracks for tags: \(analysis.tags.joined(separator: ", ")). Try a different phrase.")
        } else {
            onResult(analysis.mood, final)
        }
    }

    /// Resolve Last.fm tag suggestions to library tracks.
    private func buildViaLastFm(analysis: MoodAnalysis,
                                lastFm: LastFmService,
                                client: JellyfinClient,
                                seenTrackIds: inout Set<String>) async -> [BaseItem] {
        var out: [BaseItem] = []
        var resolvedArtistIds: Set<String> = []

        // Collect candidate artist names across all tags first.
        var candidateNames: [String] = []
        for tag in analysis.tags.prefix(5) where !tag.isEmpty {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let artists = try await lastFm.topArtists(forTag: trimmed, limit: 50)
                print("[MoodMix] Last.fm tag '\(trimmed)' → \(artists.count) artists")
                for a in artists where !candidateNames.contains(where: {
                    $0.compare(a.name, options: .caseInsensitive) == .orderedSame
                }) {
                    candidateNames.append(a.name)
                }
            } catch {
                print("[MoodMix] Last.fm tag '\(trimmed)' failed: \(error)")
            }
            if candidateNames.count >= 200 { break }
        }
        print("[MoodMix] \(candidateNames.count) unique Last.fm artist candidates")

        // Resolve each Last.fm artist → Jellyfin artist in library.
        for name in candidateNames {
            if resolvedArtistIds.count >= 30 { break }
            let hits = (try? await client.artists(search: name)) ?? []
            let needle = name.folding(options: .diacriticInsensitive, locale: .current)
            guard let match = hits.first(where: {
                $0.type == "MusicArtist" &&
                $0.Name.folding(options: .diacriticInsensitive, locale: .current)
                    .compare(needle, options: .caseInsensitive) == .orderedSame
            }) else { continue }
            guard resolvedArtistIds.insert(match.Id).inserted else { continue }

            if let tracks = try? await client.topTracksForArtist(match.Id, name: match.Name, limit: 6) {
                for t in tracks where t.type == "Audio" && seenTrackIds.insert(t.Id).inserted {
                    out.append(t)
                }
            }
        }
        return out
    }

    /// Last.fm tag.getTopTracks → match each (title, artist) pair against
    /// the user's library. Slower than the artist pipeline (one search per
    /// candidate track), so we cap aggressively and stop once we have a
    /// reasonable pool.
    private func buildViaLastFmTagTracks(analysis: MoodAnalysis,
                                          lastFm: LastFmService,
                                          client: JellyfinClient,
                                          seenTrackIds: inout Set<String>) async -> [BaseItem] {
        var candidates: [LastFmService.TagTrack] = []
        for tag in analysis.tags.prefix(5) where !tag.isEmpty {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let tracks = try await lastFm.topTracks(forTag: trimmed, limit: 50)
                candidates.append(contentsOf: tracks)
                print("[MoodMix] Last.fm tag-tracks '\(trimmed)' → \(tracks.count)")
            } catch {
                print("[MoodMix] Last.fm tag-tracks '\(trimmed)' failed: \(error)")
            }
            if candidates.count >= 150 { break }
        }
        // Dedupe by (artist|title) key.
        var seenKeys: Set<String> = []
        let unique = candidates.filter { seenKeys.insert($0.id).inserted }

        var out: [BaseItem] = []
        var checked = 0
        for cand in unique.shuffled() {
            if out.count >= 20 || checked >= 60 { break }
            checked += 1
            // Search Jellyfin for the track title — many libraries only
            // have it once, so the first artist-matching hit wins.
            let hits = (try? await client.searchTracks(cand.name, limit: 6)) ?? []
            let artistNeedle = cand.artist.name.folding(options: .diacriticInsensitive, locale: .current)
            for hit in hits where hit.type == "Audio" && seenTrackIds.insert(hit.Id).inserted {
                let artistMatch = hit.primaryArtistName
                    .folding(options: .diacriticInsensitive, locale: .current)
                if artistMatch.compare(artistNeedle, options: .caseInsensitive) == .orderedSame {
                    out.append(hit)
                    break
                }
            }
        }
        return out
    }

    /// Last-resort genre-tag query against Jellyfin's own track Genres.
    private func buildViaJellyfinGenres(analysis: MoodAnalysis,
                                        client: JellyfinClient,
                                        seenTrackIds: inout Set<String>) async -> [BaseItem] {
        var out: [BaseItem] = []
        for tag in analysis.tags.prefix(5) where !tag.isEmpty {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if let items = try? await client.audioByGenre(trimmed, limit: 40) {
                for t in items where seenTrackIds.insert(t.Id).inserted {
                    out.append(t)
                }
            }
        }
        return out
    }

    /// Foundation Models analysis. Wrapped in availability checks so older
    /// OS versions or non-AI devices surface a clear error.
    private func analyse(prompt: String) async throws -> MoodAnalysis {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return try await FoundationModelsAdapter.analyse(prompt: prompt)
        }
        #endif
        throw MoodMixError.unavailable
    }

    private func decadeRange(_ s: String) -> ClosedRange<Int>? {
        let digits = s.filter(\.isNumber)
        guard let n = Int(digits), n >= 0, n <= 2099 else { return nil }
        let base: Int
        if n >= 1900 { base = (n / 10) * 10 }                  // "1980" → 1980
        else if n < 30 { base = 2000 + (n / 10) * 10 }         // "20" → 2020, "10" → 2010
        else { base = 1900 + (n / 10) * 10 }                   // "80" → 1980
        return base...(base + 9)
    }
}

struct MoodAnalysis {
    /// Mix of music genres + Last.fm-style mood/descriptor tags
    /// (e.g. "synthwave", "chill", "melancholic", "driving").
    let tags: [String]
    let decade: String
    let mood: String
}

enum MoodMixError: Error {
    case unavailable
    var message: String {
        switch self {
        case .unavailable:
            return "Apple Intelligence isn't available on this device or OS version."
        }
    }
}

#if canImport(FoundationModels)
import struct Foundation.Date

@available(iOS 26, macOS 26, *)
enum FoundationModelsAdapter {
    /// Generable schema for the on-device model. Apple's Foundation Models
    /// framework can be steered into structured output via the @Generable
    /// macro on iOS/macOS 26.
    @Generable
    struct Analysis {
        @Guide(description: "4 to 5 Last.fm tags that fit the mood. MUST include at least 2 specific MUSIC GENRES (e.g. 'indie pop', 'folk', 'soul', 'jazz', 'singer-songwriter', 'acoustic', 'reggae', 'rock', 'hip hop', 'r&b', 'electronic', 'synthwave', 'pop', 'punk', 'country'). Then 1-3 mood/descriptor adjectives (e.g. 'chill', 'melancholic', 'driving', 'upbeat', 'energetic'). Use lowercase. Avoid niche compound tags.")
        let tags: [String]

        @Guide(description: "A decade preference matching the mood, like '70s', '80s', '90s', '00s', '10s', '20s'. Leave empty string if the mood doesn't suggest a decade.")
        let decade: String

        @Guide(description: "A short 2-4 word playlist name describing the mood, in Title Case.")
        let mood: String
    }

    static func analyse(prompt: String) async throws -> MoodAnalysis {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            throw MoodMixError.unavailable
        }
        let session = LanguageModelSession(
            instructions: """
            You translate a user's mood phrase into music metadata for building a playlist.
            Always respond with the requested structured output.
            For tags, ALWAYS include at least 2 specific music genres FIRST (e.g. 'indie pop', 'folk', 'soul', 'jazz', 'rock', 'hip hop', 'r&b', 'electronic'), then add 1-3 mood/descriptor adjectives.
            Genre tags are mandatory — without them the playlist cannot be built.
            Prefer tags that real Last.fm users actually use to tag tracks — avoid obscure, niche, or compound tags.
            """
        )
        let response = try await session.respond(
            to: "Mood phrase: \(prompt)",
            generating: Analysis.self
        )
        let a = response.content
        return MoodAnalysis(tags: a.tags, decade: a.decade, mood: a.mood)
    }
}
#endif
