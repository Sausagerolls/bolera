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
            case .library(let id):
                LibraryContent_Mac(libraryId: id)
            case .albumDetail(let album):
                AlbumDetail_Mac(album: album)
            case .artistDetail(let artist):
                ArtistDetail_Mac(artist: artist)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !daily.playlists.isEmpty {
                    dailySection
                }
                if !library.recentlyPlayed.isEmpty {
                    section("Recently Played", items: library.recentlyPlayed)
                }
                if !library.recentlyAdded.isEmpty {
                    section("Recently Added", items: library.recentlyAdded)
                }
                if !library.frequentAlbums.isEmpty {
                    section("On Repeat", items: library.frequentAlbums)
                }
                if !library.favoriteAlbums.isEmpty {
                    section("Favorites", items: library.favoriteAlbums)
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
    }

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Daily Mixes").font(.title3).bold()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(daily.playlists) { playlist in
                        DailyPlaylistTile_Mac(playlist: playlist)
                    }
                }
            }
        }
    }

    private func section(_ title: String, items: [BaseItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3).bold()
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

struct DailyPlaylistTile_Mac: View {
    let playlist: DailyPlaylist
    @EnvironmentObject var daily: DailyPlaylistStore

    private let tileWidth: CGFloat = 240   // 1.5x of 160 album tile
    private let tileHeight: CGFloat = 160

    var body: some View {
        Button {
            AudioPlayer.shared.play(items: playlist.tracks)
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
    @State private var image: PlatformImage?

    var body: some View {
        Button {
            nav.openArtist(item)
        } label: {
            VStack(alignment: .center, spacing: 6) {
                ZStack {
                    Color.gray.opacity(0.15)
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.mic")
                            .font(.system(size: 38))
                            .foregroundStyle(.secondary)
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
        }
        .task(id: item.Id) { await loadImage() }
        .onAppear {
            ArtistPrefetcher.shared.prefetch(item, auth: auth, lastFm: lastFm)
        }
    }

    private func loadImage() async {
        guard image == nil, let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        let imgURL = client.imageURL(for: item.Id, tag: item.ImageTags?["Primary"], maxWidth: 320)
        guard let imgURL else { return }
        let img = await ImageCache.shared.load(url: imgURL, headers: ["Authorization": auth.authHeader()])
        await MainActor.run { self.image = img }
    }
}

// MARK: - Album tile

struct AlbumTile_Mac: View {
    let item: BaseItem
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var pinned: PinnedItemsStore
    @EnvironmentObject var nav: MacNavCoordinator
    @State private var image: PlatformImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.gray.opacity(0.15)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
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
        let imgURL = client.imageURL(for: item.artworkItemId, tag: item.artworkTag, maxWidth: 320)
        guard let imgURL else { return }
        let img = await ImageCache.shared.load(url: imgURL, headers: ["Authorization": auth.authHeader()])
        await MainActor.run { self.image = img }
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
    @State private var items: [BaseItem] = []
    @State private var pendingDelete: BaseItem?

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items) { pl in
                    PlaylistTile_Mac(playlist: pl,
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

/// Square thumbnail for a Jellyfin playlist. Tries the playlist's own
/// primary image first; falls back to a 2x2 composite built from the
/// first four track album covers.
private struct PlaylistTile_Mac: View {
    let playlist: BaseItem
    let onPlay: () -> Void
    let onShuffle: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var downloads: DownloadManager
    @State private var hero: PlatformImage?
    @State private var quadrants: [PlatformImage] = []
    @State private var downloading = false

    var body: some View {
        Button(action: onPlay) {
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
                                               onPlay: { Task { await playPlaylist(hint) } })
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
                    Table(tracks) {
                        TableColumn("Name") { Text($0.Name) }
                        TableColumn("Artist") { Text($0.primaryArtistName) }
                        TableColumn("Album") { Text($0.Album ?? "") }
                        TableColumn("Length") { item in Text(item.durationSeconds.mmSS) }
                    }
                    .contextMenu(forSelectionType: BaseItem.ID.self) { _ in
                    } primaryAction: { ids in
                        guard let id = ids.first, let idx = tracks.firstIndex(where: { $0.Id == id }) else { return }
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

    enum BrowseMode: String, CaseIterable, Identifiable {
        case albums = "Albums"
        case artists = "Artists"
        var id: String { rawValue }
    }

    let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
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
        .task(id: libraryId) { await loadAll() }
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
