import SwiftUI
import BoleraCore

struct SearchView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var query: String = ""
    @State private var hints: [SearchHint] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            ForEach(grouped, id: \.0) { (sectionTitle, items) in
                Section(sectionTitle) {
                    ForEach(items) { hint in
                        SearchRow(hint: hint)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, albums, artists, playlists")
        .onChange(of: query) { _, new in scheduleSearch(new) }
        .navigationTitle("Search")
        .navigationDestination(for: BaseItem.self) { item in
            switch item.type {
            case "MusicArtist": ArtistDetailView(artist: item)
            case "MusicAlbum":  AlbumDetailView(album: item)
            case "Playlist":    PlaylistDetailView(playlist: item)
            default:            EmptyView()
            }
        }
    }

    private var grouped: [(String, [SearchHint])] {
        let order: [(String, String)] = [
            ("Artists", "MusicArtist"),
            ("Albums", "MusicAlbum"),
            ("Songs", "Audio"),
            ("Playlists", "Playlist")
        ]
        return order.compactMap { (title, type) in
            let items = hints.filter { $0.type == type }
            return items.isEmpty ? nil : (title, items)
        }
    }

    private func scheduleSearch(_ term: String) {
        searchTask?.cancel()
        guard !term.isEmpty, let url = auth.serverURL else { hints = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let client = JellyfinClient(baseURL: url, auth: auth)
            let results = (try? await client.search(term)) ?? []
            // Hidden libraries are promised to be skipped in Search too. Map
            // each hint to a stub the visibility filter understands (Audio →
            // AlbumId, album/artist → its own id) and keep only survivors.
            let stubs = results.map { Self.stub(for: $0) }
            await MainActor.run {
                let keptIds = Set(LibraryVisibilityStore.shared.filter(stubs).map { $0.Id })
                self.hints = results.filter { keptIds.contains($0.ItemId ?? $0.Id ?? "") }
            }
        }
    }

    /// Minimal BaseItem stub from a search hint, carrying just the fields the
    /// LibraryVisibilityStore filter inspects (id, type, album id).
    private static func stub(for hint: SearchHint) -> BaseItem {
        BaseItem(
            Id: hint.ItemId ?? hint.Id ?? "", Name: hint.Name, type: hint.type,
            AlbumId: hint.AlbumId, Album: nil, AlbumArtist: hint.AlbumArtist,
            AlbumArtists: nil, ArtistItems: nil, Artists: nil,
            ParentId: nil, CollectionType: nil,
            RunTimeTicks: nil, IndexNumber: nil, ParentIndexNumber: nil, ProductionYear: nil,
            UserData: nil, ImageTags: nil, AlbumPrimaryImageTag: nil, BackdropImageTags: nil,
            ChildCount: nil, SongCount: nil, AlbumCount: nil, Overview: nil, Genres: nil
        )
    }
}

struct SearchRow: View {
    let hint: SearchHint
    @EnvironmentObject var auth: AuthManager

    var body: some View {
        // Songs play directly; everything else navigates to its detail page
        // via NavigationLink (was previously broken — Button-only rows
        // never let the user open the detail screens).
        if hint.type == "Audio" {
            Button(action: playSong) { rowContent }
                .buttonStyle(.plain)
                .trackContextMenu(hintItemStub)
        } else {
            NavigationLink(value: hintItemStub) { rowContent }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            JellyfinImage(itemId: imageId, tag: hint.PrimaryImageTag, maxWidth: 120, cornerRadius: hint.type == "MusicArtist" ? 22 : 6)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading) {
                Text(hint.Name).foregroundStyle(.primary).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
    }

    /// Build a navigable BaseItem stub from the search hint. Detail views
    /// fetch full data themselves; we only need Id/Name/type/ImageTags.
    private var hintItemStub: BaseItem {
        let id = hint.ItemId ?? hint.Id ?? ""
        let tag = hint.PrimaryImageTag
        return BaseItem(
            Id: id, Name: hint.Name, type: hint.type,
            AlbumId: hint.AlbumId, Album: nil, AlbumArtist: hint.AlbumArtist,
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

    private var imageId: String {
        if hint.type == "Audio" { return hint.AlbumId ?? hint.ItemId ?? "" }
        return hint.ItemId ?? hint.Id ?? ""
    }

    private var subtitle: String {
        switch hint.type {
        case "MusicArtist": return "Artist"
        case "MusicAlbum": return "Album • \(hint.AlbumArtist ?? "")"
        case "Audio": return "Song • \(hint.AlbumArtist ?? "")"
        case "Playlist": return "Playlist"
        default: return hint.type ?? ""
        }
    }

    private func playSong() {
        guard let url = auth.serverURL, let id = hint.ItemId ?? hint.Id else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        Task {
            guard let item = try? await client.item(id) else { return }
            await MainActor.run { AudioPlayer.shared.play(items: [item]) }
        }
    }
}
