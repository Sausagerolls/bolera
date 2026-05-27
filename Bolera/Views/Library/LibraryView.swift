import SwiftUI
import BoleraCore

struct LibraryView: View {
    enum Tab: String, CaseIterable { case artists = "Artists", albums = "Albums", playlists = "Playlists" }
    @State private var tab: Tab = .artists

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            Group {
                switch tab {
                case .artists: ArtistsView()
                case .albums: AlbumsView()
                case .playlists: PlaylistsView()
                }
            }
        }
        .navigationTitle("Library")
    }
}

struct ArtistsView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var items: [BaseItem] = []
    @State private var loading = false

    private let cacheKey = "artists"

    var body: some View {
        List(items) { artist in
            NavigationLink(value: artist) {
                HStack(spacing: 12) {
                    JellyfinImage(itemId: artist.Id, tag: artist.ImageTags?["Primary"], maxWidth: 180, cornerRadius: 28)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading) {
                        Text(artist.Name).font(.body)
                        if let count = artist.AlbumCount {
                            Text("\(count) album\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationDestination(for: BaseItem.self) { item in
            ArtistDetailView(artist: item)
        }
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .task {
            if items.isEmpty, let cached = LibraryCache.shared.read(cacheKey, as: [BaseItem].self) {
                items = cached
            }
            await load()
        }
        .refreshable { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        if items.isEmpty { loading = true }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let fresh = try? await client.artists(limit: 500) {
            items = LibraryVisibilityStore.shared.filter(fresh)
            LibraryCache.shared.write(cacheKey, value: fresh)
        }
        loading = false
    }
}

struct AlbumsView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var items: [BaseItem] = []
    @State private var loading = false

    let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]
    private let cacheKey = "albums"

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items) { album in
                    NavigationLink(value: album) {
                        VStack(alignment: .leading, spacing: 6) {
                            JellyfinImage(itemId: album.Id, tag: album.ImageTags?["Primary"], maxWidth: 400, cornerRadius: 10)
                                .aspectRatio(1, contentMode: .fit)
                            Text(album.Name).font(.subheadline).lineLimit(1)
                            Text(album.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            Color.clear.frame(height: 100)
        }
        .navigationDestination(for: BaseItem.self) { item in
            AlbumDetailView(album: item)
        }
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .task {
            if items.isEmpty, let cached = LibraryCache.shared.read(cacheKey, as: [BaseItem].self) {
                items = cached
            }
            await load()
        }
        .refreshable { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        if items.isEmpty { loading = true }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let fresh = try? await client.albums(limit: 500) {
            items = LibraryVisibilityStore.shared.filter(fresh)
            LibraryCache.shared.write(cacheKey, value: fresh)
        }
        loading = false
    }
}

struct PlaylistsView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var items: [BaseItem] = []

    private let cacheKey = "playlists"

    var body: some View {
        List(items) { playlist in
            NavigationLink(value: playlist) {
                HStack(spacing: 12) {
                    JellyfinImage(itemId: playlist.Id, tag: playlist.ImageTags?["Primary"], maxWidth: 180, cornerRadius: 8)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading) {
                        Text(playlist.Name).font(.body)
                        if let songs = playlist.SongCount ?? playlist.ChildCount {
                            Text("\(songs) tracks").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationDestination(for: BaseItem.self) { item in
            PlaylistDetailView(playlist: item)
        }
        .task {
            if items.isEmpty, let cached = LibraryCache.shared.read(cacheKey, as: [BaseItem].self) {
                items = cached
            }
            await load()
        }
        .refreshable { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let fresh = try? await client.playlists() {
            items = fresh
            LibraryCache.shared.write(cacheKey, value: fresh)
        }
    }
}
