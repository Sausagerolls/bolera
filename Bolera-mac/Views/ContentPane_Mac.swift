import SwiftUI
import BoleraCore

struct ContentPane_Mac: View {
    let selection: SidebarSelection
    @Binding var searchQuery: String

    var body: some View {
        Group {
            switch selection {
            case .home:        HomeContent_Mac()
            case .search:      SearchContent_Mac(query: $searchQuery)
            case .favorites:   FavoritesContent_Mac()
            case .downloads:   DownloadsContent_Mac()
            case .artists:     ArtistsContent_Mac()
            case .albums:      AlbumsContent_Mac()
            case .playlists:   PlaylistsContent_Mac()
            case .genres:      GenresContent_Mac()
            case .tags:        TagsContent_Mac()
            case .libraryFilter(let f): FilterDetail_Mac(filter: f)
            case .homeSection(let s): HomeSectionList_Mac(section: s)
            case .library(let id):
                LibraryContent_Mac(libraryId: id)
            case .albumDetail(let album):
                AlbumDetail_Mac(album: album)
            case .artistDetail(let artist):
                ArtistDetail_Mac(artist: artist)
            case .playlistDetail(let pl):
                PlaylistDetail_Mac(playlist: pl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }
}

// MARK: - Home

private struct HomeContent_Mac: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var daily: DailyPlaylistStore
    @EnvironmentObject var lastFm: LastFmService
    @EnvironmentObject var nav: MacNavCoordinator
    @AppStorage("bolera.ai.moodMixEnabled") private var moodMixEnabled: Bool = true
    @State private var showMoodMix = false
    @State private var showMixesList = false
    @ObservedObject private var connectivity = ConnectivityStore.shared
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if connectivity.isOnline {
                    if moodMixEnabled {
                        moodMixCard
                    }
                    if !daily.playlists.isEmpty || daily.isGenerating {
                        dailySection
                    }
                    if !library.recentlyPlayed.isEmpty {
                        section("Recent Tracks", items: library.recentlyPlayed) { nav.openHomeSection(.recentTracks) }
                    }
                    if !library.recentlyPlayedAlbums.isEmpty {
                        section("Recent Albums", items: library.recentlyPlayedAlbums) { nav.openHomeSection(.recentAlbums) }
                    }
                    if !library.topPlayedTracks.isEmpty {
                        section("Top Played Tracks", items: library.topPlayedTracks) { nav.openHomeSection(.topTracks) }
                    }
                    if !library.recentlyAdded.isEmpty {
                        section("Recently Added", items: library.recentlyAdded) { nav.openHomeSection(.recentlyAdded) }
                    }
                    if !library.favoriteTracks.isEmpty {
                        section("Favorite Tracks", items: library.favoriteTracks) { nav.openFavorites(mode: "Tracks") }
                    }
                    if !library.favoriteAlbums.isEmpty {
                        section("Favorite Albums", items: library.favoriteAlbums) { nav.openFavorites(mode: "Albums") }
                    }
                } else {
                    offlineContent
                }
            }
            .padding(20)
        }
        .task {
            guard let url = auth.serverURL else { return }
            let client = JellyfinClient(baseURL: url, auth: auth)
            await library.refresh(client: client)
            await daily.refreshIfNeeded(client: client, auth: auth, lastFm: lastFm)
        }
        .onReceive(connectivity.didReconnect) { _ in
            Task {
                guard let url = auth.serverURL else { return }
                let client = JellyfinClient(baseURL: url, auth: auth)
                await library.refresh(client: client)
                await daily.refreshIfNeeded(client: client, auth: auth, lastFm: lastFm)
            }
        }
        // Refresh "Recent Tracks/Albums" when the playing track changes, so the
        // home view updates live instead of only on re-appear. Small delay lets
        // Jellyfin record the play first (playback start is reported ~2s in).
        .onReceive(AudioPlayer.shared.$currentIndex.dropFirst()) { _ in
            guard let url = auth.serverURL else { return }
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await library.refresh(client: JellyfinClient(baseURL: url, auth: auth))
            }
        }
        .sheet(isPresented: $showMoodMix) {
            MoodMixSheet_Mac()
        }
        .sheet(isPresented: $showMixesList) {
            DailyMixesListView_Mac()
        }
    }

    /// Gradient banner that mirrors the iOS Make-a-Mix card.
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
        }
        .buttonStyle(.plain)
    }

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { showMixesList = true } label: {
                    HStack(spacing: 6) {
                        Text("Daily Mixes").font(.title3).bold()
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("See all mixes from this week")
                if daily.isGenerating {
                    ProgressView().controlSize(.small)
                    Text("Generating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await regenerateMixes() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .rotationEffect(.degrees(daily.isGenerating ? 360 : 0))
                        .animation(daily.isGenerating
                                   ? .linear(duration: 1.2).repeatForever(autoreverses: false)
                                   : .default,
                                   value: daily.isGenerating)
                }
                .buttonStyle(.plain)
                .disabled(daily.isGenerating)
                .help("Regenerate Daily Mixes")
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            if !daily.playlists.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(daily.playlists) { playlist in
                            DailyPlaylistTile_Mac(playlist: playlist)
                        }
                    }
                }
            }
        }
    }

    private func regenerateMixes() async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        await daily.regenerate(client: client, auth: auth, lastFm: lastFm)
    }

    /// Downloaded-only content shown when the server is unreachable.
    @ViewBuilder
    private var offlineContent: some View {
        let artists = downloads.downloadedArtistReps()
        let albums  = downloads.downloadedAlbumReps()
        let tracks  = downloads.individuallyDownloadedTracks()
        if artists.isEmpty && albums.isEmpty && tracks.isEmpty {
            ContentUnavailableView("You're Offline", systemImage: "wifi.slash",
                description: Text("Download music while connected to listen offline."))
                .frame(minHeight: 300)
        } else {
            if !albums.isEmpty  { section("Downloaded Albums",  items: albums) }
            if !artists.isEmpty { section("Downloaded Artists", items: artists) }
            if !tracks.isEmpty  { section("Downloaded Tracks",  items: tracks) }
        }
    }

    private func section(_ title: String, items: [BaseItem], onOpen: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let onOpen {
                // Header taps through to the full list for this section.
                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        Text(title).font(.title3).bold()
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text(title).font(.title3).bold()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(items) { item in
                        AlbumTile_Mac(item: item)
                            .frame(width: 160)
                    }
                }
            }
        }
    }
}

// MARK: - Track row with artwork (mac)

/// A track row showing album art, title/artist, album and length. Plays on
/// click. Used by the home section lists and the Favourites tracks view so
/// track lists show cover art (the old SwiftUI Table had none).
struct MacTrackRow_Mac: View {
    let track: BaseItem
    let onPlay: () -> Void
    @EnvironmentObject var auth: AuthManager
    @State private var image: PlatformImage?

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                ZStack {
                    Color.white.opacity(0.06)
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.Name).lineLimit(1)
                    Text(track.primaryArtistName)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(track.Album ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: 220, alignment: .trailing)
                Text(track.durationSeconds.mmSS)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: track.Id) { await loadArt() }
    }

    private func loadArt() async {
        guard image == nil, let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        let img = await ImageCache.shared.loadArtwork(
            itemId: track.AlbumId ?? track.artworkItemId,
            tag: track.AlbumPrimaryImageTag ?? track.artworkTag,
            client: client, maxWidth: 120,
            headers: ["Authorization": auth.authHeader()])
        await MainActor.run { self.image = img }
    }
}

/// Scrollable list of `MacTrackRow_Mac`. `onPlay(index)` starts playback at the
/// tapped row against the whole list.
struct MacTrackListView_Mac: View {
    let tracks: [BaseItem]
    let onPlay: (Int) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, t in
                    MacTrackRow_Mac(track: t) { onPlay(idx) }
                    Divider().padding(.leading, 68)
                }
            }
            Color.clear.frame(height: 20)
        }
    }
}

// MARK: - Home section → full list (mac)

/// Full-list page for a home rail (Recent Tracks/Albums, Top Played, Recently
/// Added). Track sections render a sortable Table that plays on double-click;
/// album sections a grid of album tiles.
private struct HomeSectionList_Mac: View {
    let section: MacHomeSection
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @State private var items: [BaseItem] = []

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(.title2).bold()
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if section.isTrackList {
                MacTrackListView_Mac(tracks: items) { idx in
                    player.play(items: items, startAt: idx)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(items) { AlbumTile_Mac(item: $0) }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        let vis = LibraryVisibilityStore.shared, ign = IgnoredTracksStore.shared
        do {
            switch section {
            case .recentTracks:
                items = ign.filter(vis.filter(try await client.recentlyPlayed(limit: 200)))
            case .topTracks:
                items = ign.filter(vis.filter(try await client.topPlayedTracks(limit: 200)))
            case .recentAlbums:
                items = vis.filter(try await client.recentlyPlayedAlbums(limit: 200))
            case .recentlyAdded:
                items = vis.filter(try await client.recentlyAdded(limit: 200))
            }
        } catch {
            // Keep whatever's shown.
        }
    }
}

struct DailyPlaylistTile_Mac: View {
    let playlist: DailyPlaylist
    @EnvironmentObject var daily: DailyPlaylistStore

    private let tileWidth: CGFloat = 240   // 1.5x of 160 album tile
    private let tileHeight: CGFloat = 160

    var body: some View {
        Button {
            AudioPlayer.shared.playMix(items: playlist.tracks, extender: daily.extender(for: playlist))
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let img = daily.artworkByPlaylist[playlist.id] {
                    Image(nsImage: img)
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

// MARK: - Daily Mixes (rolling week)

/// All daily mixes from the last week (synced across devices), grouped by day.
struct DailyMixesListView_Mac: View {
    @ObservedObject private var daily = DailyPlaylistStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Daily Mixes").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            if daily.recentMixes.isEmpty {
                ContentUnavailableView("No Mixes Yet", systemImage: "square.stack",
                    description: Text("Daily mixes from the last week appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(grouped(), id: \.date) { group in
                        Section(Self.sectionTitle(group.date)) {
                            ForEach(group.mixes) { mix in
                                Button {
                                    AudioPlayer.shared.playMix(items: mix.tracks,
                                                               extender: daily.extender(for: mix))
                                    dismiss()
                                } label: { row(mix) }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 440, height: 540)
    }

    private func row(_ mix: DailyPlaylist) -> some View {
        HStack(spacing: 12) {
            Group {
                if let img = daily.artworkByPlaylist[mix.id] {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [Color.accentColor.opacity(0.4), .black.opacity(0.6)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(mix.name).lineLimit(1)
                Text("\(mix.tracks.count) tracks").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "play.circle.fill").foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func grouped() -> [(date: String, mixes: [DailyPlaylist])] {
        var order: [String] = []
        var byDate: [String: [DailyPlaylist]] = [:]
        for m in daily.recentMixes {
            if byDate[m.date] == nil { order.append(m.date) }
            byDate[m.date, default: []].append(m)
        }
        return order.map { ($0, byDate[$0] ?? []) }
    }

    static func sectionTitle(_ date: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        guard let d = f.date(from: date) else { return date }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let out = DateFormatter(); out.dateFormat = "EEEE, d MMM"; return out.string(from: d)
    }
}

// MARK: - Shimmer loading placeholder

/// Faint gradient stripe that sweeps across a muted background while
/// artwork is loading. Used in place of the static gray rectangle so the
/// user can tell the difference between "loading" and "image broken".
struct ShimmerView_Mac: View {
    var cornerRadius: CGFloat = 8
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { _ in
            ZStack {
                Color.white.opacity(0.06)
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0),    location: 0.0),
                        .init(color: .white.opacity(0.18), location: 0.5),
                        .init(color: .white.opacity(0),    location: 1.0)
                    ],
                    startPoint: UnitPoint(x: phase, y: 0.5),
                    endPoint:   UnitPoint(x: phase + 0.6, y: 0.5)
                )
                .blendMode(.plusLighter)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                phase = 1.4
            }
        }
    }
}

// MARK: - Artist prefetcher
//
// Warms artist-detail caches (albums, top tracks, similar artists, bio)
// when an artist tile becomes visible — the next tap finds data on disk
// and ArtistDetail_Mac renders instantly. Dedupes per session and skips
// artists whose cache slots are already populated.

@MainActor
final class ArtistPrefetcher {
    static let shared = ArtistPrefetcher()
    private var inFlight: Set<String> = []

    func prefetch(_ artist: BaseItem, auth: AuthManager, lastFm: LastFmService) {
        let id = artist.Id
        guard !id.isEmpty,
              !inFlight.contains(id),
              let serverURL = auth.serverURL else { return }

        let albumsKey  = "artist.\(id).albums"
        let tracksKey  = "artist.\(id).topTracks"
        let similarKey = "artist.\(id).similar.v4"
        let bioKey     = "artist.\(id).bio"

        let cache = LibraryCache.shared
        let hasAlbums  = cache.read(albumsKey,  as: [BaseItem].self) != nil
        let hasTracks  = cache.read(tracksKey,  as: [BaseItem].self) != nil
        let hasSimilar = cache.read(similarKey, as: [BaseItem].self) != nil
        let hasBio     = cache.read(bioKey,     as: String.self) != nil
        if hasAlbums && hasTracks && hasSimilar && hasBio { return }

        inFlight.insert(id)
        let client = JellyfinClient(baseURL: serverURL, auth: auth)
        let name = artist.Name

        Task { @MainActor in
            defer { inFlight.remove(id) }

            if !hasAlbums,
               let a = try? await client.albumsForArtist(id, name: name) {
                var seen: Set<String> = []
                let cleaned = a.filter { $0.type == "MusicAlbum" && seen.insert($0.Id).inserted }
                cache.write(albumsKey, value: cleaned)
            }
            if !hasTracks {
                let poolLimit = lastFm.hasAppCredentials ? 300 : 15
                if let t = try? await client.topTracksForArtist(id, name: name, limit: poolLimit) {
                    var seen: Set<String> = []
                    let cleaned = t.filter { seen.insert($0.Id).inserted }
                    var ordered = cleaned
                    if lastFm.hasAppCredentials,
                       let lfTop = try? await lastFm.topTracks(forName: name, limit: 25) {
                        ordered = ArtistDetail_Mac.reorderByLastFm(
                            localTracks: cleaned,
                            lastFmNames: lfTop.map { $0.name })
                    }
                    cache.write(tracksKey, value: Array(ordered.prefix(10)))
                }
            }
            if !hasBio {
                if let full = try? await client.item(id),
                   let ov = full.Overview, !ov.isEmpty {
                    cache.write(bioKey, value: ov)
                } else if lastFm.hasAppCredentials,
                          let info = try? await lastFm.artistInfo(forName: name) {
                    cache.write(bioKey, value: info.summary)
                }
            }
            if !hasSimilar, lastFm.hasAppCredentials,
               let lfNames = try? await lastFm.similarArtists(forName: name, limit: 25) {
                var resolved: [BaseItem] = []
                for cand in lfNames {
                    if resolved.count >= 5 { break }
                    let hits = (try? await client.artists(search: cand.name)) ?? []
                    let needle = cand.name.folding(options: .diacriticInsensitive, locale: .current)
                    if let match = hits.first(where: {
                        $0.type == "MusicArtist" &&
                        $0.Name.folding(options: .diacriticInsensitive, locale: .current)
                            .compare(needle, options: .caseInsensitive) == .orderedSame
                    }) {
                        resolved.append(match)
                    }
                }
                cache.write(similarKey, value: resolved)
            }
        }
    }
}

// MARK: - Artist tile

struct ArtistTile_Mac: View {
    let item: BaseItem
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var pinned: PinnedItemsStore
    @EnvironmentObject var nav: MacNavCoordinator
    @EnvironmentObject var lastFm: LastFmService
    @EnvironmentObject var ignored: IgnoredTracksStore
    @State private var image: PlatformImage?
    @State private var loadFailed = false

    var body: some View {
        Button {
            nav.openArtist(item)
        } label: {
            VStack(alignment: .center, spacing: 6) {
                ZStack {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else if loadFailed {
                        Color.white.opacity(0.06)
                        Image(systemName: "music.mic")
                            .font(.system(size: 38))
                            .foregroundStyle(.secondary)
                    } else {
                        ShimmerView_Mac(cornerRadius: 80)
                    }
                }
                .frame(width: 160, height: 160)
                .clipShape(Circle())
                Text(item.Name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 160)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                pinned.togglePin(item)
            } label: {
                Label(pinned.isPinned(itemId: item.Id) ? "Unpin from Sidebar" : "Pin to Sidebar",
                      systemImage: pinned.isPinned(itemId: item.Id) ? "pin.slash" : "pin")
            }
            Divider()
            Button {
                if ignored.isArtistIgnored(item.Id) {
                    ignored.unignoreArtist(item.Id)
                } else {
                    ignored.ignoreArtist(item)
                }
            } label: {
                Label(ignored.isArtistIgnored(item.Id) ? "Stop Ignoring Artist" : "Ignore Artist",
                      systemImage: ignored.isArtistIgnored(item.Id) ? "eye" : "eye.slash")
            }
        }
        .task(id: item.Id) { await loadImage() }
        .onAppear {
            ArtistPrefetcher.shared.prefetch(item, auth: auth, lastFm: lastFm)
        }
    }

    private func loadImage() async {
        guard image == nil, let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        guard let imgURL = client.imageURL(for: item.Id, tag: item.ImageTags?["Primary"], maxWidth: 320) else {
            await MainActor.run { self.loadFailed = true }
            return
        }
        let img = await ImageCache.shared.load(url: imgURL, headers: ["Authorization": auth.authHeader()])
        await MainActor.run {
            self.image = img
            self.loadFailed = (img == nil)
        }
    }
}

// MARK: - Album tile

struct AlbumTile_Mac: View {
    let item: BaseItem
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var pinned: PinnedItemsStore
    @EnvironmentObject var nav: MacNavCoordinator
    @EnvironmentObject var ignored: IgnoredTracksStore
    @State private var image: PlatformImage?
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if loadFailed {
                    Color.white.opacity(0.06)
                    Image(systemName: "opticaldisc")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    ShimmerView_Mac(cornerRadius: 8)
                }
            }
            .frame(width: 160, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(item.Name).font(.subheadline).lineLimit(1)
            Text(item.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { tapAction() }
        .contextMenu {
            if item.type != "Audio" {
                Button {
                    playFromTile()
                } label: { Label("Play", systemImage: "play.fill") }
            }
            if item.type == "Audio", let albumId = item.AlbumId {
                Button {
                    let stub = BaseItem.stub(id: albumId, name: item.Album ?? "", type: "MusicAlbum")
                    nav.openAlbum(stub)
                } label: { Label("Go to Album", systemImage: "opticaldisc") }
            }
            Button {
                pinned.togglePin(item)
            } label: {
                Label(pinned.isPinned(itemId: item.Id) ? "Unpin from Sidebar" : "Pin to Sidebar",
                      systemImage: pinned.isPinned(itemId: item.Id) ? "pin.slash" : "pin")
            }
            if item.type == "MusicAlbum" {
                Divider()
                Button {
                    if ignored.isAlbumIgnored(item.Id) {
                        ignored.unignoreAlbum(item.Id)
                    } else {
                        ignored.ignoreAlbum(item)
                    }
                } label: {
                    Label(ignored.isAlbumIgnored(item.Id) ? "Stop Ignoring Album" : "Ignore Album",
                          systemImage: ignored.isAlbumIgnored(item.Id) ? "eye" : "eye.slash")
                }
            }
        }
        .task { await loadImage() }
    }

    /// Audio tiles play the track immediately; album tiles open the album page.
    private func tapAction() {
        if item.type == "Audio" {
            AudioPlayer.shared.play(items: [item])
        } else {
            nav.openAlbum(item)
        }
    }

    private func loadImage() async {
        guard image == nil,
              let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        // Prefer a downloaded item's local cover art so it shows offline.
        let img = await ImageCache.shared.loadArtwork(itemId: item.artworkItemId,
                                                      tag: item.artworkTag,
                                                      client: client,
                                                      maxWidth: 320,
                                                      headers: ["Authorization": auth.authHeader()])
        await MainActor.run {
            self.image = img
            self.loadFailed = (img == nil)
        }
    }

    private func playFromTile() {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        Task {
            if item.type == "MusicAlbum" {
                if let songs = try? await client.songs(parentId: item.Id) {
                    await MainActor.run { AudioPlayer.shared.play(items: songs) }
                }
            } else {
                await MainActor.run { AudioPlayer.shared.play(items: [item]) }
            }
        }
    }
}

// MARK: - Stubs (artists, albums, playlists, search, etc.)
//
// Minimal first cut. Each fetches and lists items in a Table.

private struct ArtistsContent_Mac: View {
    @EnvironmentObject var auth: AuthManager
    @State private var items: [BaseItem] = []

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items) { artist in ArtistTile_Mac(item: artist) }
            }
            .padding(20)
        }
        .task { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let fresh = try? await client.artists(limit: 500) {
            items = LibraryVisibilityStore.shared.filter(fresh)
        }
    }
}

// MARK: - Genres & Tags (mac)

/// All music genres on the server; click one to browse its artists + albums.
private struct GenresContent_Mac: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var nav: MacNavCoordinator
    @State private var genres: [BaseItem] = []
    @State private var loading = false

    var body: some View {
        Group {
            if genres.isEmpty && !loading {
                ContentUnavailableView("No Genres", systemImage: "guitars",
                    description: Text("Your server has no music genres set."))
            } else {
                List(genres) { g in
                    Button { nav.openFilter(MacLibraryFilter(kind: .genre, name: g.Name)) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "guitars").foregroundStyle(.tint).frame(width: 24)
                            Text(g.Name)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay { if loading && genres.isEmpty { ProgressView() } }
        .task { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        if genres.isEmpty { loading = true }
        defer { loading = false }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let fresh = try? await client.musicGenres() { genres = fresh }
    }
}

/// All server tags applied to music; click one to browse tagged items.
private struct TagsContent_Mac: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var nav: MacNavCoordinator
    @State private var tags: [String] = []
    @State private var loading = false

    var body: some View {
        Group {
            if tags.isEmpty && !loading {
                ContentUnavailableView("No Tags", systemImage: "tag",
                    description: Text("Tag albums or artists on your Jellyfin server and they'll appear here."))
            } else {
                List(tags, id: \.self) { t in
                    Button { nav.openFilter(MacLibraryFilter(kind: .tag, name: t)) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "tag").foregroundStyle(.tint).frame(width: 24)
                            Text(t)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay { if loading && tags.isEmpty { ProgressView() } }
        .task { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        if tags.isEmpty { loading = true }
        defer { loading = false }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let fresh = try? await client.musicTags() { tags = fresh }
    }
}

/// Artists + albums for a genre or server tag.
private struct FilterDetail_Mac: View {
    let filter: MacLibraryFilter
    @EnvironmentObject var auth: AuthManager
    @State private var artists: [BaseItem] = []
    @State private var albums: [BaseItem] = []
    @State private var loading = false

    private let artistColumns = [GridItem(.adaptive(minimum: 180), spacing: 16)]
    private let albumColumns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 8) {
                    Image(systemName: filter.kind == .genre ? "guitars" : "tag")
                        .foregroundStyle(.tint)
                    Text(filter.name).font(.title2.bold())
                    Text(filter.kind.rawValue).font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if !artists.isEmpty {
                    Text("Artists").font(.title3).bold()
                    LazyVGrid(columns: artistColumns, spacing: 18) {
                        ForEach(artists) { a in ArtistTile_Mac(item: a) }
                    }
                }
                if !albums.isEmpty {
                    Text("Albums").font(.title3).bold()
                    LazyVGrid(columns: albumColumns, spacing: 18) {
                        ForEach(albums) { al in AlbumTile_Mac(item: al) }
                    }
                }
                if artists.isEmpty && albums.isEmpty && !loading {
                    ContentUnavailableView("Nothing Here",
                        systemImage: filter.kind == .genre ? "guitars" : "tag",
                        description: Text("No artists or albums match this \(filter.kind.rawValue.lowercased())."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(20)
        }
        .overlay { if loading && artists.isEmpty && albums.isEmpty { ProgressView() } }
        .task(id: filter) { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        loading = true
        defer { loading = false }
        let client = JellyfinClient(baseURL: url, auth: auth)
        let isGenre = filter.kind == .genre
        async let ar = isGenre ? client.artists(genre: filter.name) : client.artists(tag: filter.name)
        async let al = isGenre ? client.albums(genre: filter.name) : client.albums(tag: filter.name)
        var fetchedArtists = (try? await ar) ?? []
        let fetchedAlbums = (try? await al) ?? []
        // Many libraries only genre/tag the ALBUMS — derive artists from the
        // matching albums when the artist query comes back empty.
        if fetchedArtists.isEmpty {
            var seen = Set<String>()
            fetchedArtists = fetchedAlbums.compactMap { album -> BaseItem? in
                guard let a = album.AlbumArtists?.first, seen.insert(a.Id).inserted else { return nil }
                return .stub(id: a.Id, name: a.Name, type: "MusicArtist")
            }
        }
        let vis = LibraryVisibilityStore.shared
        artists = vis.filter(fetchedArtists)
        albums = vis.filter(fetchedAlbums)
    }
}

private struct AlbumsContent_Mac: View {
    @EnvironmentObject var auth: AuthManager
    @State private var items: [BaseItem] = []

    let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items) { album in
                    AlbumTile_Mac(item: album)
                }
            }
            .padding(20)
        }
        .task { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let fresh = try? await client.albums(limit: 500) {
            items = LibraryVisibilityStore.shared.filter(fresh)
        }
    }
}

private struct PlaylistsContent_Mac: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var nav: MacNavCoordinator
    @State private var items: [BaseItem] = []
    @State private var pendingDelete: BaseItem?

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items) { pl in
                    PlaylistTile_Mac(playlist: pl,
                                     onOpen: { nav.openPlaylist(pl) },
                                     onPlay: { Task { await play(pl, shuffle: false) } },
                                     onShuffle: { Task { await play(pl, shuffle: true) } },
                                     onDelete: { pendingDelete = pl })
                }
            }
            .padding(20)
        }
        .task { await load() }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.Name ?? "")\"?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pl = pendingDelete {
                    Task { await delete(pl) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This permanently removes the playlist from your Jellyfin library.")
        }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let fresh = try? await client.playlists() {
            items = fresh
        }
    }

    private func play(_ playlist: BaseItem, shuffle: Bool) async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        guard let raw = try? await client.playlistItems(playlist.Id) else { return }
        var tracks = raw.filter { $0.type == "Audio" }
        if shuffle { tracks.shuffle() }
        await MainActor.run { player.play(items: tracks) }
    }

    private func delete(_ playlist: BaseItem) async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        do {
            try await client.deleteItem(playlist.Id)
            await MainActor.run { items.removeAll { $0.Id == playlist.Id } }
        } catch {
            // Reload from server on failure to stay accurate.
            await load()
        }
    }
}

/// Playlist breakdown: cover + Play / Shuffle / Download controls, then the
/// track list. Opened by tapping any playlist tile (instead of auto-playing).
private struct PlaylistDetail_Mac: View {
    let playlist: BaseItem
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var downloads: DownloadManager
    @State private var tracks: [BaseItem] = []
    @State private var hero: PlatformImage?
    @State private var loading = false
    @State private var downloadingAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if tracks.isEmpty && !loading {
                ContentUnavailableView("Empty Playlist", systemImage: "music.note.list")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MacTrackListView_Mac(tracks: tracks) { idx in
                    player.play(items: tracks, startAt: idx)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay { if loading && tracks.isEmpty { ProgressView() } }
        .task(id: playlist.Id) { await load() }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            ZStack {
                Color.gray.opacity(0.15)
                if let hero {
                    Image(nsImage: hero).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 44)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 8) {
                Text("Playlist").font(.caption).foregroundStyle(.secondary)
                Text(playlist.Name).font(.largeTitle.bold()).lineLimit(2)
                Text("\(tracks.count) track\(tracks.count == 1 ? "" : "s")")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        player.shuffle = false
                        player.play(items: tracks)
                    } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 70) }
                        .buttonStyle(.borderedProminent)
                        .disabled(tracks.isEmpty)
                    Button {
                        player.shuffle = true
                        player.play(items: tracks)
                    } label: { Label("Shuffle", systemImage: "shuffle") }
                        .buttonStyle(.bordered)
                        .disabled(tracks.isEmpty)
                    Button {
                        Task { await downloadAll() }
                    } label: {
                        Label(downloadingAll ? "Downloading…" : "Download",
                              systemImage: "arrow.down.circle")
                    }
                        .buttonStyle(.bordered)
                        .disabled(tracks.isEmpty || downloadingAll)
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(28)
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        loading = true
        defer { loading = false }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let raw = try? await client.playlistItems(playlist.Id) {
            tracks = raw.filter { $0.type == "Audio" }
        }
        let headers = ["Authorization": auth.authHeader()]
        if let tag = playlist.ImageTags?["Primary"],
           let u = client.imageURL(for: playlist.Id, tag: tag, maxWidth: 400) {
            hero = await ImageCache.shared.load(url: u, headers: headers)
        } else if let first = tracks.first {
            hero = await ImageCache.shared.loadArtwork(
                itemId: first.AlbumId ?? first.artworkItemId,
                tag: first.AlbumPrimaryImageTag ?? first.artworkTag,
                client: client, maxWidth: 400, headers: headers)
        }
    }

    private func downloadAll() async {
        guard let url = auth.serverURL else { return }
        downloadingAll = true
        defer { downloadingAll = false }
        let client = JellyfinClient(baseURL: url, auth: auth)
        for t in tracks where !downloads.isDownloaded(t.Id) {
            downloads.download(t, using: client)
        }
    }
}

/// Square thumbnail for a Jellyfin playlist. Tries the playlist's own
/// primary image first; falls back to a 2x2 composite built from the
/// first four track album covers.
private struct PlaylistTile_Mac: View {
    let playlist: BaseItem
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onShuffle: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var downloads: DownloadManager
    @State private var hero: PlatformImage?
    @State private var quadrants: [PlatformImage] = []
    @State private var downloading = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Color.gray.opacity(0.15)
                    if let hero {
                        Image(nsImage: hero).resizable().scaledToFill()
                    } else if quadrants.count == 4 {
                        compositeGrid
                    } else if let first = quadrants.first {
                        Image(nsImage: first).resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 38))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(playlist.Name).font(.subheadline).lineLimit(1)
                Text("\(playlist.SongCount ?? playlist.ChildCount ?? 0) tracks")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 170)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { onPlay() } label: { Label("Play", systemImage: "play.fill") }
            Button { onShuffle() } label: { Label("Shuffle", systemImage: "shuffle") }
            Button {
                Task { await downloadAll() }
            } label: {
                Label(downloading ? "Downloading…" : "Download Playlist",
                      systemImage: "arrow.down.circle")
            }
            .disabled(downloading)
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete Playlist", systemImage: "trash")
            }
        }
        .task(id: playlist.Id) { await loadArt() }
    }

    private func downloadAll() async {
        guard let serverURL = auth.serverURL else { return }
        downloading = true
        defer { downloading = false }
        let client = JellyfinClient(baseURL: serverURL, auth: auth)
        guard let tracks = try? await client.playlistItems(playlist.Id) else { return }
        for t in tracks where t.type == "Audio" {
            if !downloads.isDownloaded(t.Id) {
                downloads.download(t, using: client)
            }
        }
    }

    private var compositeGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(nsImage: quadrants[0]).resizable().scaledToFill()
                Image(nsImage: quadrants[1]).resizable().scaledToFill()
            }
            HStack(spacing: 0) {
                Image(nsImage: quadrants[2]).resizable().scaledToFill()
                Image(nsImage: quadrants[3]).resizable().scaledToFill()
            }
        }
    }

    private func loadArt() async {
        guard let serverURL = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: serverURL, auth: auth)
        let headers = ["Authorization": auth.authHeader()]

        // Prefer Jellyfin's own primary image when present.
        if let tag = playlist.ImageTags?["Primary"],
           let url = client.imageURL(for: playlist.Id, tag: tag, maxWidth: 320) {
            if let img = await ImageCache.shared.load(url: url, headers: headers) {
                await MainActor.run { self.hero = img }
                return
            }
        }

        // Composite: pull first 4 tracks, fetch each album cover.
        guard let tracks = try? await client.playlistItems(playlist.Id) else { return }
        let audioTracks = tracks.filter { $0.type == "Audio" }
        // Deduplicate by album so the composite isn't four copies of the same cover.
        var seenAlbums: Set<String> = []
        var pickedAlbumIds: [(itemId: String, tag: String?)] = []
        for t in audioTracks {
            let albumId = t.AlbumId ?? t.artworkItemId
            guard !albumId.isEmpty, seenAlbums.insert(albumId).inserted else { continue }
            pickedAlbumIds.append((albumId, t.AlbumPrimaryImageTag ?? t.artworkTag))
            if pickedAlbumIds.count == 4 { break }
        }
        var loaded: [PlatformImage] = []
        for (itemId, tag) in pickedAlbumIds {
            guard let url = client.imageURL(for: itemId, tag: tag, maxWidth: 200) else { continue }
            if let img = await ImageCache.shared.load(url: url, headers: headers) {
                loaded.append(img)
            }
        }
        await MainActor.run { self.quadrants = loaded }
    }
}

private struct SearchContent_Mac: View {
    @Binding var query: String
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var nav: MacNavCoordinator
    @State private var hints: [SearchHint] = []
    @State private var task: Task<Void, Never>?

    private var artists: [SearchHint]  { hints.filter { $0.type == "MusicArtist" } }
    private var albums: [SearchHint]   { hints.filter { $0.type == "MusicAlbum" } }
    private var songs: [SearchHint]    { hints.filter { $0.type == "Audio" } }
    private var playlists: [SearchHint] { hints.filter { $0.type == "Playlist" } }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if query.isEmpty {
                emptyHero("Search your library",
                          subtitle: "Artists, albums, songs, playlists")
            } else if hints.isEmpty {
                emptyHero("No results for \"\(query)\"",
                          subtitle: "Try a different spelling")
            } else {
                results
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Re-run the search when the view re-mounts (e.g. user navigated
        // into an album/artist and came back). The query binding lives in
        // the parent window, but `hints` is local — without this re-fetch
        // the results pane appears empty until the user types again.
        .task {
            if !query.isEmpty && hints.isEmpty {
                scheduleSearch()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Artists, albums, songs, playlists", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .onChange(of: query) { _, _ in scheduleSearch() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if !artists.isEmpty {
                    section(title: "Artists", count: artists.count) {
                        horizontalRail(artists) { hint in
                            ArtistTile_Mac(item: artistStub(hint))
                                .frame(width: 160)
                        }
                    }
                }
                if !albums.isEmpty {
                    section(title: "Albums", count: albums.count) {
                        horizontalRail(albums) { hint in
                            AlbumTile_Mac(item: albumStub(hint))
                                .frame(width: 160)
                        }
                    }
                }
                if !songs.isEmpty {
                    section(title: "Songs", count: songs.count) {
                        VStack(spacing: 0) {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { idx, hint in
                                SongRow_Search(hint: hint, onTap: { Task { await playSong(hint) } })
                                if idx < songs.count - 1 {
                                    Divider().padding(.leading, 60)
                                }
                            }
                        }
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                if !playlists.isEmpty {
                    section(title: "Playlists", count: playlists.count) {
                        horizontalRail(playlists) { hint in
                            PlaylistResultTile(hint: hint,
                                               onPlay: { nav.openPlaylist(playlistStub(hint)) })
                                .frame(width: 160)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, count: Int,
                                        @ViewBuilder body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.title3).bold()
                Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            body()
        }
    }

    @ViewBuilder
    private func horizontalRail<Item: Identifiable, Content: View>(
        _ items: [Item],
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(items) { item in content(item) }
            }
        }
    }

    private func emptyHero(_ title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3).foregroundStyle(.secondary)
            Text(subtitle).font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hint → BaseItem stubs

    private func artistStub(_ hint: SearchHint) -> BaseItem {
        let id = hint.ItemId ?? hint.Id ?? ""
        let tag = hint.PrimaryImageTag
        return BaseItem(
            Id: id, Name: hint.Name, type: "MusicArtist",
            AlbumId: nil, Album: nil, AlbumArtist: nil,
            AlbumArtists: nil, ArtistItems: nil, Artists: nil,
            ParentId: nil, CollectionType: nil,
            RunTimeTicks: nil, IndexNumber: nil, ParentIndexNumber: nil, ProductionYear: nil,
            UserData: nil,
            ImageTags: tag.map { ["Primary": $0] },
            AlbumPrimaryImageTag: nil, BackdropImageTags: nil,
            ChildCount: nil, SongCount: nil, AlbumCount: nil,
            Overview: nil, Genres: nil
        )
    }

    private func albumStub(_ hint: SearchHint) -> BaseItem {
        let id = hint.ItemId ?? hint.Id ?? ""
        let tag = hint.PrimaryImageTag
        return BaseItem(
            Id: id, Name: hint.Name, type: "MusicAlbum",
            AlbumId: id, Album: hint.Name, AlbumArtist: hint.AlbumArtist,
            AlbumArtists: nil, ArtistItems: nil, Artists: nil,
            ParentId: nil, CollectionType: nil,
            RunTimeTicks: nil, IndexNumber: nil, ParentIndexNumber: nil, ProductionYear: nil,
            UserData: nil,
            ImageTags: tag.map { ["Primary": $0] },
            AlbumPrimaryImageTag: tag, BackdropImageTags: nil,
            ChildCount: nil, SongCount: nil, AlbumCount: nil,
            Overview: nil, Genres: nil
        )
    }

    private func playlistStub(_ hint: SearchHint) -> BaseItem {
        let id = hint.ItemId ?? hint.Id ?? ""
        let tag = hint.PrimaryImageTag
        return BaseItem(
            Id: id, Name: hint.Name, type: "Playlist",
            AlbumId: nil, Album: nil, AlbumArtist: nil,
            AlbumArtists: nil, ArtistItems: nil, Artists: nil,
            ParentId: nil, CollectionType: nil,
            RunTimeTicks: nil, IndexNumber: nil, ParentIndexNumber: nil, ProductionYear: nil,
            UserData: nil,
            ImageTags: tag.map { ["Primary": $0] },
            AlbumPrimaryImageTag: nil, BackdropImageTags: nil,
            ChildCount: nil, SongCount: nil, AlbumCount: nil,
            Overview: nil, Genres: nil
        )
    }

    // MARK: - Actions

    private func playSong(_ hint: SearchHint) async {
        guard let url = auth.serverURL, let id = hint.ItemId ?? hint.Id else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        guard let item = try? await client.item(id) else { return }
        await MainActor.run { player.play(items: [item]) }
    }

    private func playPlaylist(_ hint: SearchHint) async {
        guard let url = auth.serverURL, let id = hint.ItemId ?? hint.Id else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        guard let songs = try? await client.playlistItems(id) else { return }
        await MainActor.run { player.play(items: songs.filter { $0.type == "Audio" }) }
    }

    private func scheduleSearch() {
        task?.cancel()
        task = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            guard !query.isEmpty, let url = auth.serverURL else {
                await MainActor.run { hints = [] }
                return
            }
            let client = JellyfinClient(baseURL: url, auth: auth)
            let results = (try? await client.search(query)) ?? []
            await MainActor.run { hints = results }
        }
    }
}

private struct SongRow_Search: View {
    let hint: SearchHint
    let onTap: () -> Void

    @EnvironmentObject var auth: AuthManager
    @State private var artwork: PlatformImage?

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Color.gray.opacity(0.15)
                    if let artwork {
                        Image(nsImage: artwork).resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(hint.Name).lineLimit(1)
                    Text(hint.AlbumArtist ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: hint.id) { await loadArt() }
    }

    private func loadArt() async {
        guard let serverURL = auth.serverURL,
              let imageId = hint.AlbumId ?? hint.ItemId ?? hint.Id,
              !imageId.isEmpty else { return }
        let client = JellyfinClient(baseURL: serverURL, auth: auth)
        guard let url = client.imageURL(for: imageId, tag: hint.PrimaryImageTag, maxWidth: 120) else { return }
        let img = await ImageCache.shared.load(
            url: url,
            headers: ["Authorization": auth.authHeader()])
        await MainActor.run { self.artwork = img }
    }
}

private struct PlaylistResultTile: View {
    let hint: SearchHint
    let onPlay: () -> Void

    @EnvironmentObject var auth: AuthManager
    @State private var artwork: PlatformImage?

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Color.gray.opacity(0.15)
                    if let artwork {
                        Image(nsImage: artwork).resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 38))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(hint.Name).font(.subheadline).lineLimit(1)
                Text("Playlist").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 160, alignment: .leading)
        }
        .buttonStyle(.plain)
        .task(id: hint.id) { await loadArt() }
    }

    private func loadArt() async {
        guard let serverURL = auth.serverURL,
              let id = hint.ItemId ?? hint.Id,
              let tag = hint.PrimaryImageTag else { return }
        let client = JellyfinClient(baseURL: serverURL, auth: auth)
        guard let url = client.imageURL(for: id, tag: tag, maxWidth: 320) else { return }
        let img = await ImageCache.shared.load(
            url: url,
            headers: ["Authorization": auth.authHeader()])
        await MainActor.run { self.artwork = img }
    }
}

private struct FavoritesContent_Mac: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var nav: MacNavCoordinator

    enum Mode: String, CaseIterable, Identifiable {
        case tracks = "Tracks", albums = "Albums", artists = "Artists"
        var id: String { rawValue }
    }
    @State private var mode: Mode = .albums
    @State private var tracks: [BaseItem] = []
    @State private var albums: [BaseItem] = []
    @State private var artists: [BaseItem] = []

    let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .frame(maxWidth: 360)

            switch mode {
            case .tracks:
                if tracks.isEmpty {
                    favoritesEmpty("No individual songs favourited",
                                   icon: "music.note")
                } else {
                    MacTrackListView_Mac(tracks: tracks) { idx in
                        player.play(items: tracks, startAt: idx)
                    }
                }
            case .albums:
                if albums.isEmpty {
                    favoritesEmpty("No Albums Favourited",
                                   icon: "square.stack")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(albums) { album in AlbumTile_Mac(item: album) }
                        }
                        .padding(20)
                    }
                }
            case .artists:
                if artists.isEmpty {
                    favoritesEmpty("No artists favourited",
                                   icon: "music.mic")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(artists) { artist in ArtistTile_Mac(item: artist) }
                        }
                        .padding(20)
                    }
                }
            }
        }
        .task { await load() }
        .onAppear {
            // Honour a tab requested by a home favourites rail header.
            if let m = nav.pendingFavoritesMode, let parsed = Mode(rawValue: m) {
                mode = parsed
                nav.pendingFavoritesMode = nil
            }
        }
    }

    @ViewBuilder
    private func favoritesEmpty(_ text: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        async let tracksTask = client.favorites(type: "Audio", limit: 500)
        async let albumsTask = client.favorites(type: "MusicAlbum", limit: 500)
        async let artistsTask = client.favorites(type: "MusicArtist", limit: 500)
        let t = (try? await tracksTask) ?? []
        let a = (try? await albumsTask) ?? []
        let ar = (try? await artistsTask) ?? []
        tracks = LibraryVisibilityStore.shared.filter(t)
        albums = LibraryVisibilityStore.shared.filter(a)
        artists = LibraryVisibilityStore.shared.filter(ar)
    }
}

private struct DownloadsContent_Mac: View {
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var auth: AuthManager

    enum Mode: String, CaseIterable, Identifiable {
        case tracks = "Tracks", albums = "Albums", artists = "Artists", genres = "Genres"
        var id: String { rawValue }
    }
    @State private var mode: Mode = .tracks
    @State private var confirmDeleteAll = false

    private var allTracks: [BaseItem] {
        downloads.completed.compactMap { downloads.metadata[$0] }
            .sorted { $0.Name.localizedCaseInsensitiveCompare($1.Name) == .orderedAscending }
    }

    private var totalSizeLabel: String {
        let bytes = downloads.totalBytesOnDisk()
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Management header — track count, size on disk, delete-all.
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(allTracks.count) tracks")
                        .font(.subheadline.weight(.medium))
                    Text(totalSizeLabel)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    confirmDeleteAll = true
                } label: {
                    Label("Delete All", systemImage: "trash")
                }
                .disabled(allTracks.isEmpty)
                .help("Remove all downloaded tracks from this device")
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 6)

            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .frame(maxWidth: 460)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog(
            "Delete all \(allTracks.count) downloaded tracks?",
            isPresented: $confirmDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                downloads.deleteAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees up \(totalSizeLabel). Tracks can be re-downloaded later.")
        }
        .task { await backfillIfNeeded() }
    }

    /// Legacy downloads were stored without the Genres field, leaving the
    /// Genres tab blank. Refetch full metadata for any that are missing it.
    private func backfillIfNeeded() async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        await downloads.backfillMissingMetadata(using: client)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .tracks:
            Table(allTracks) {
                TableColumn("Name") { Text($0.Name) }
                TableColumn("Artist") { Text($0.primaryArtistName) }
                TableColumn("Album") { Text($0.Album ?? "") }
                TableColumn("Length") { item in Text(item.durationSeconds.mmSS) }
            }
            .contextMenu(forSelectionType: BaseItem.ID.self) { ids in
                if !ids.isEmpty {
                    Button(role: .destructive) {
                        for id in ids { downloads.delete(id) }
                    } label: {
                        Label("Remove from Downloads", systemImage: "trash")
                    }
                }
            } primaryAction: { ids in
                let list = allTracks
                guard let id = ids.first, let idx = list.firstIndex(where: { $0.Id == id }) else { return }
                player.play(items: list, startAt: idx)
            }
        case .albums:
            let groups = groupByAlbum(allTracks)
            let cols = [GridItem(.adaptive(minimum: 160), spacing: 16)]
            ScrollView {
                LazyVGrid(columns: cols, spacing: 18) {
                    ForEach(groups, id: \.name) { group in
                        AlbumTile_Mac(item: Self.albumStub(from: group))
                            .contextMenu {
                                Button {
                                    player.play(items: group.tracks)
                                } label: { Label("Play", systemImage: "play.fill") }
                                Button(role: .destructive) {
                                    for t in group.tracks { downloads.delete(t.Id) }
                                } label: {
                                    Label("Remove Album from Downloads", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(20)
            }
        case .artists:
            let groups = groupByArtist(allTracks)
            let cols = [GridItem(.adaptive(minimum: 180), spacing: 16)]
            ScrollView {
                LazyVGrid(columns: cols, spacing: 18) {
                    ForEach(groups, id: \.name) { group in
                        ArtistTile_Mac(item: Self.artistStub(from: group))
                            .contextMenu {
                                Button {
                                    player.play(items: group.tracks)
                                } label: { Label("Play", systemImage: "play.fill") }
                                Button(role: .destructive) {
                                    for t in group.tracks { downloads.delete(t.Id) }
                                } label: {
                                    Label("Remove Artist from Downloads", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(20)
            }
        case .genres:
            let groups = groupByGenre(allTracks)
            if groups.isEmpty {
                ContentUnavailableView("No genres",
                                       systemImage: "music.note.list",
                                       description: Text("Downloaded tracks have no genre tags."))
            } else {
                List(groups, id: \.name) { group in
                    Button {
                        player.play(items: group.tracks)
                    } label: {
                        HStack {
                            Image(systemName: "guitars").foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(group.name)
                                Text("\(group.tracks.count) tracks")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private struct Grouping { let name: String; let artist: String; let tracks: [BaseItem] }

    /// Build a BaseItem stub representing an artist from a grouped Downloads
    /// pile. Uses the first track's AlbumArtists[0].Id (or ArtistItems[0].Id)
    /// so ArtistTile_Mac can fetch the real Jellyfin artist photo.
    private static func artistStub(from group: Grouping) -> BaseItem {
        let first = group.tracks.first
        let artistId = first?.AlbumArtists?.first?.Id
            ?? first?.ArtistItems?.first?.Id
            ?? ""
        return BaseItem(
            Id: artistId, Name: group.name, type: "MusicArtist",
            AlbumId: nil, Album: nil, AlbumArtist: nil,
            AlbumArtists: nil, ArtistItems: nil, Artists: nil,
            ParentId: nil, CollectionType: nil,
            RunTimeTicks: nil, IndexNumber: nil, ParentIndexNumber: nil, ProductionYear: nil,
            UserData: nil, ImageTags: nil,
            AlbumPrimaryImageTag: nil, BackdropImageTags: nil,
            ChildCount: nil, SongCount: nil, AlbumCount: nil,
            Overview: nil, Genres: nil
        )
    }

    /// Build a BaseItem stub representing an album from a grouped Downloads
    /// pile. Uses the first track's AlbumId so AlbumTile_Mac can fetch the
    /// real Jellyfin artwork.
    private static func albumStub(from group: Grouping) -> BaseItem {
        let albumId = group.tracks.first?.AlbumId ?? ""
        let tag = group.tracks.first?.AlbumPrimaryImageTag
        return BaseItem(
            Id: albumId, Name: group.name, type: "MusicAlbum",
            AlbumId: albumId, Album: group.name, AlbumArtist: group.artist,
            AlbumArtists: nil, ArtistItems: nil, Artists: nil,
            ParentId: nil, CollectionType: nil,
            RunTimeTicks: nil, IndexNumber: nil, ParentIndexNumber: nil, ProductionYear: nil,
            UserData: nil,
            ImageTags: tag.map { ["Primary": $0] },
            AlbumPrimaryImageTag: tag, BackdropImageTags: nil,
            ChildCount: nil, SongCount: nil, AlbumCount: nil,
            Overview: nil, Genres: nil
        )
    }

    private func groupByAlbum(_ tracks: [BaseItem]) -> [Grouping] {
        var by: [String: [BaseItem]] = [:]
        for t in tracks {
            let key = t.Album ?? "Unknown Album"
            by[key, default: []].append(t)
        }
        return by.map { name, ts in
            Grouping(name: name, artist: ts.first?.primaryArtistName ?? "", tracks: ts)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func groupByArtist(_ tracks: [BaseItem]) -> [Grouping] {
        var by: [String: [BaseItem]] = [:]
        for t in tracks {
            let key = t.primaryArtistName.isEmpty ? "Unknown Artist" : t.primaryArtistName
            by[key, default: []].append(t)
        }
        return by.map { name, ts in
            Grouping(name: name, artist: "", tracks: ts)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func groupByGenre(_ tracks: [BaseItem]) -> [Grouping] {
        var by: [String: [BaseItem]] = [:]
        for t in tracks {
            for g in t.Genres ?? [] {
                by[g, default: []].append(t)
            }
        }
        return by.map { name, ts in
            Grouping(name: name, artist: "", tracks: ts)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct LibraryContent_Mac: View {
    let libraryId: String
    @EnvironmentObject var auth: AuthManager
    @State private var mode: BrowseMode = .albums
    @State private var albums: [BaseItem] = []
    @State private var artists: [BaseItem] = []
    @State private var loading = false
    @ObservedObject private var connectivity = ConnectivityStore.shared

    enum BrowseMode: String, CaseIterable, Identifiable {
        case albums = "Albums"
        case artists = "Artists"
        var id: String { rawValue }
    }

    let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        Group {
            if connectivity.isOnline {
                VStack(spacing: 0) {
                    Picker("View", selection: $mode) {
                        ForEach(BrowseMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                    .frame(maxWidth: 360)

                    switch mode {
                    case .albums:
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(albums) { item in AlbumTile_Mac(item: item) }
                            }
                            .padding(20)
                        }
                    case .artists:
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(artists) { artist in ArtistTile_Mac(item: artist) }
                            }
                            .padding(20)
                        }
                    }
                }
            } else {
                // Offline: server browse unavailable — show downloaded content.
                DownloadsContent_Mac()
            }
        }
        .task(id: libraryId) {
            if connectivity.isOnline { await loadAll() }
        }
        .onReceive(connectivity.didReconnect) { _ in
            Task { await loadAll() }
        }
    }

    private func loadAll() async {
        guard let url = auth.serverURL else { return }
        loading = true
        defer { loading = false }
        let client = JellyfinClient(baseURL: url, auth: auth)
        async let albumsTask = client.albums(limit: 500, parentId: libraryId)
        async let artistsTask = client.artists(limit: 500, parentId: libraryId)
        let a = (try? await albumsTask) ?? []
        let ar = (try? await artistsTask) ?? []
        albums = a
        artists = ar
    }
}

// Duration helper (also exists in iOS Extensions.swift).
private extension Double {
    var mmSS: String {
        let total = Int(self)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - AI Mood Mix (Mac)
//
// Mirror of the iOS Make-a-Mix sheet. Foundation Models picks tags from a
// natural-language mood phrase; Last.fm tag → top-artists data + Jellyfin
// genre search + Last.fm tag.getTopTracks all combine to build a playlist
// that fits the requested vibe.

#if canImport(FoundationModels)
import FoundationModels
#endif

struct MoodMixSheet_Mac: View {
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
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inputField
                    suggestionRow
                    if !LastFmService.shared.hasAppCredentials || !LastFmService.shared.isAuthenticated {
                        lastFmHint
                    }
                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if loading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Asking Apple Intelligence…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 20)
                    }
                    if !tracks.isEmpty {
                        resultHeader
                        resultList
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 540, height: 640)
    }

    private var header: some View {
        HStack {
            Image(systemName: "wand.and.stars")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("Make a Mix").font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var inputField: some View {
        HStack(spacing: 8) {
            TextField("Describe a vibe, an activity, a memory", text: $prompt)
                .textFieldStyle(.plain)
                .font(.title3)
                .onSubmit { Task { await generate() } }
            Button {
                Task { await generate() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || loading)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
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
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

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
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if idx < tracks.count - 1 {
                    Divider().padding(.leading, 38)
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func generate() async {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        loading = true
        error = nil
        tracks = []
        defer { loading = false }
        await MoodMixGenerator_Mac.shared.generate(
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

@MainActor
final class MoodMixGenerator_Mac {
    static let shared = MoodMixGenerator_Mac()

    func generate(prompt: String,
                  auth: AuthManager,
                  onResult: @escaping (_ mood: String, _ tracks: [BaseItem]) -> Void,
                  onError: @escaping (String) -> Void) async {
        guard let serverURL = auth.serverURL else {
            onError("Not signed in to a Jellyfin server"); return
        }
        let analysis: MoodAnalysis_Mac
        do {
            analysis = try await analyse(prompt: prompt)
        } catch let e as MoodMixError_Mac {
            onError(e.message); return
        } catch {
            onError(error.localizedDescription); return
        }

        let client = JellyfinClient(baseURL: serverURL, auth: auth)
        let lastFm = LastFmService.shared
        print("[MoodMix-Mac] prompt=\(prompt) → tags=\(analysis.tags) decade=\(analysis.decade) mood=\(analysis.mood)")

        var combined: [BaseItem] = []
        var seen: Set<String> = []

        if lastFm.hasAppCredentials {
            let viaLastFm = await buildViaLastFm(analysis: analysis, lastFm: lastFm, client: client, seenTrackIds: &seen)
            combined.append(contentsOf: viaLastFm)
            print("[MoodMix-Mac] Last.fm pool: \(viaLastFm.count)")
        }
        let viaGenres = await buildViaJellyfinGenres(analysis: analysis, client: client, seenTrackIds: &seen)
        combined.append(contentsOf: viaGenres)
        print("[MoodMix-Mac] Jellyfin genre pool: \(viaGenres.count)")

        if lastFm.hasAppCredentials && combined.count < 10 {
            let viaTracks = await buildViaLastFmTagTracks(analysis: analysis, lastFm: lastFm, client: client, seenTrackIds: &seen)
            combined.append(contentsOf: viaTracks)
            print("[MoodMix-Mac] Last.fm tag-tracks pool: \(viaTracks.count)")
        }

        combined = LiveFilterStore.shared.filter(IgnoredTracksStore.shared.filter(combined))

        if let range = decadeRange(analysis.decade) {
            let filtered = combined.filter { ($0.ProductionYear).map(range.contains) ?? false }
            let keepRatio = Double(filtered.count) / Double(max(1, combined.count))
            if filtered.count >= 15 && keepRatio >= 0.4 { combined = filtered }
        }

        var perArtist: [String: Int] = [:]
        let capped = combined.shuffled().filter { t in
            let key = t.primaryArtistName.lowercased()
            let c = perArtist[key] ?? 0
            if c >= 4 { return false }
            perArtist[key] = c + 1
            return true
        }
        let final = Array(capped.prefix(25))
        print("[MoodMix-Mac] combined=\(combined.count) → final=\(final.count)")
        if final.isEmpty {
            onError("No matching tracks for tags: \(analysis.tags.joined(separator: ", ")). Try a different phrase.")
        } else {
            onResult(analysis.mood, final)
        }
    }

    private func buildViaLastFm(analysis: MoodAnalysis_Mac, lastFm: LastFmService, client: JellyfinClient, seenTrackIds: inout Set<String>) async -> [BaseItem] {
        var out: [BaseItem] = []
        var resolvedIds: Set<String> = []
        var candidates: [String] = []
        for tag in analysis.tags.prefix(5) where !tag.isEmpty {
            let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if let artists = try? await lastFm.topArtists(forTag: t, limit: 50) {
                for a in artists where !candidates.contains(where: { $0.compare(a.name, options: .caseInsensitive) == .orderedSame }) {
                    candidates.append(a.name)
                }
            }
            if candidates.count >= 200 { break }
        }
        for name in candidates {
            if resolvedIds.count >= 30 { break }
            let hits = (try? await client.artists(search: name)) ?? []
            let needle = name.folding(options: .diacriticInsensitive, locale: .current)
            guard let match = hits.first(where: {
                $0.type == "MusicArtist" &&
                $0.Name.folding(options: .diacriticInsensitive, locale: .current)
                    .compare(needle, options: .caseInsensitive) == .orderedSame
            }) else { continue }
            guard resolvedIds.insert(match.Id).inserted else { continue }
            if let tracks = try? await client.topTracksForArtist(match.Id, name: match.Name, limit: 6) {
                for t in tracks where t.type == "Audio" && seenTrackIds.insert(t.Id).inserted {
                    out.append(t)
                }
            }
        }
        return out
    }

    private func buildViaLastFmTagTracks(analysis: MoodAnalysis_Mac, lastFm: LastFmService, client: JellyfinClient, seenTrackIds: inout Set<String>) async -> [BaseItem] {
        var candidates: [LastFmService.TagTrack] = []
        for tag in analysis.tags.prefix(5) where !tag.isEmpty {
            let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if let tracks = try? await lastFm.topTracks(forTag: t, limit: 50) {
                candidates.append(contentsOf: tracks)
            }
            if candidates.count >= 150 { break }
        }
        var seenKeys: Set<String> = []
        let unique = candidates.filter { seenKeys.insert($0.id).inserted }
        var out: [BaseItem] = []
        var checked = 0
        for cand in unique.shuffled() {
            if out.count >= 20 || checked >= 60 { break }
            checked += 1
            let hits = (try? await client.searchTracks(cand.name, limit: 6)) ?? []
            let needle = cand.artist.name.folding(options: .diacriticInsensitive, locale: .current)
            for hit in hits where hit.type == "Audio" && seenTrackIds.insert(hit.Id).inserted {
                let am = hit.primaryArtistName.folding(options: .diacriticInsensitive, locale: .current)
                if am.compare(needle, options: .caseInsensitive) == .orderedSame {
                    out.append(hit); break
                }
            }
        }
        return out
    }

    private func buildViaJellyfinGenres(analysis: MoodAnalysis_Mac, client: JellyfinClient, seenTrackIds: inout Set<String>) async -> [BaseItem] {
        var out: [BaseItem] = []
        for tag in analysis.tags.prefix(5) where !tag.isEmpty {
            let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if let items = try? await client.audioByGenre(t, limit: 40) {
                for x in items where seenTrackIds.insert(x.Id).inserted {
                    out.append(x)
                }
            }
        }
        return out
    }

    private func analyse(prompt: String) async throws -> MoodAnalysis_Mac {
        // User-configured custom AI (Pro, opt-in) takes precedence. Gate on the
        // live Pro entitlement so it stops if Pro lapses; analyze() throws a
        // clear error if enabled-but-unconfigured or consent not yet granted.
        if ProEntitlementStore.shared.isPro && CustomAIStore.shared.enabled {
            let r = try await CustomAIStore.shared.analyze(prompt: prompt)
            return MoodAnalysis_Mac(tags: r.tags, decade: r.decade, mood: r.mood)
        }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return try await FoundationModelsAdapter_Mac.analyse(prompt: prompt)
        }
        #endif
        throw MoodMixError_Mac.unavailable
    }

    private func decadeRange(_ s: String) -> ClosedRange<Int>? {
        let digits = s.filter(\.isNumber)
        guard let n = Int(digits), n >= 0, n <= 2099 else { return nil }
        let base: Int
        if n >= 1900 { base = (n / 10) * 10 }
        else if n < 30 { base = 2000 + (n / 10) * 10 }
        else { base = 1900 + (n / 10) * 10 }
        return base...(base + 9)
    }
}

struct MoodAnalysis_Mac {
    let tags: [String]
    let decade: String
    let mood: String
}

enum MoodMixError_Mac: Error {
    case unavailable
    var message: String {
        switch self {
        case .unavailable: return "Apple Intelligence isn't available on this Mac or OS version."
        }
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
enum FoundationModelsAdapter_Mac {
    @Generable
    struct Analysis {
        @Guide(description: "4 to 5 Last.fm tags that fit the mood. MUST include at least 2 specific MUSIC GENRES (e.g. 'indie pop', 'folk', 'soul', 'jazz', 'singer-songwriter', 'acoustic', 'reggae', 'rock', 'hip hop', 'r&b', 'electronic', 'synthwave', 'pop', 'punk', 'country'). Then 1-3 mood/descriptor adjectives (e.g. 'chill', 'melancholic', 'driving', 'upbeat', 'energetic'). Use lowercase. Avoid niche compound tags.")
        let tags: [String]
        @Guide(description: "A decade preference matching the mood, like '70s', '80s', '90s', '00s', '10s', '20s'. Leave empty string if none.")
        let decade: String
        @Guide(description: "A short 2-4 word playlist name describing the mood, in Title Case.")
        let mood: String
    }
    static func analyse(prompt: String) async throws -> MoodAnalysis_Mac {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            throw MoodMixError_Mac.unavailable
        }
        let session = LanguageModelSession(
            instructions: """
            You translate a user's mood phrase into music metadata for building a playlist.
            Always respond with the requested structured output.
            For tags, ALWAYS include at least 2 specific music genres FIRST, then add 1-3 mood/descriptor adjectives.
            Genre tags are mandatory — without them the playlist cannot be built.
            Prefer tags real Last.fm users apply to tracks — avoid obscure or compound tags.
            """
        )
        let response = try await session.respond(
            to: "Mood phrase: \(prompt)",
            generating: Analysis.self
        )
        let a = response.content
        return MoodAnalysis_Mac(tags: a.tags, decade: a.decade, mood: a.mood)
    }
}
#endif
