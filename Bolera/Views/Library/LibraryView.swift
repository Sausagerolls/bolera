import SwiftUI
import BoleraCore

struct LibraryView: View {
    @EnvironmentObject var connectivity: ConnectivityStore

    /// A list of categories that each drill into their own full screen — keeps
    /// the Library uncluttered as sections grow (vs a cramped segmented bar).
    /// Library categories — pushed as VALUES (not view-based NavigationLinks),
    /// so the whole stack is value-driven. Mixing view-based `NavigationLink {}`
    /// rows with a value-based `navigationDestination` in one NavigationStack is
    /// what double-fired the first push (tap album → flick → list reappears).
    enum Category: String, Hashable, CaseIterable {
        case favorites = "Favorites", artists = "Artists", albums = "Albums"
        case genres = "Genres", tags = "Tags"
        case playlists = "Playlists", downloaded = "Downloaded"
        var icon: String {
            switch self {
            case .favorites:  return "heart.fill"
            case .artists:    return "music.mic"
            case .albums:     return "square.stack.fill"
            case .genres:     return "guitars.fill"
            case .tags:       return "tag.fill"
            case .playlists:  return "list.bullet.rectangle.portrait.fill"
            case .downloaded: return "arrow.down.circle.fill"
            }
        }
        var tint: Color { self == .favorites ? .pink : (self == .downloaded ? .green : .accentColor) }
    }

    /// A genre or server tag the user drilled into — pushed as a VALUE so the
    /// whole stack stays value-driven (see Category doc above).
    /// `matches` = the RAW server genre names to query. File tags often hold
    /// multiple genres in one field ("Rock; Pop") and Jellyfin stores that as a
    /// single genre entity; we split those for display, so one displayed genre
    /// can map to several underlying server genres.
    struct Filter: Hashable {
        enum Kind: String { case genre = "Genre", tag = "Tag" }
        let kind: Kind
        let name: String
        var matches: [String] = []
        var queryNames: [String] { matches.isEmpty ? [name] : matches }
    }

    /// Split a server genre entity into displayable genres ("Rock; Pop" → 2).
    static func splitGenre(_ name: String) -> [String] {
        let parts = name.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [name] : parts
    }

    var body: some View {
        List {
            if connectivity.isOnline {
                Section {
                    ForEach([Category.favorites, .artists, .albums, .genres, .tags, .playlists], id: \.self) { categoryRow($0) }
                }
            } else {
                Section {
                    Label("You're offline — showing downloads", systemImage: "wifi.slash")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section { categoryRow(.downloaded) }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BoleraBackground())
        .navigationTitle("Library")
        // Everything in this stack is value-based + every destination is declared
        // at the ROOT (here) — no view-based links, no mid-stack destinations.
        .navigationDestination(for: Category.self) { cat in
            categoryDestination(cat).navigationTitle(cat.rawValue)
        }
        .navigationDestination(for: BaseItem.self) { item in
            switch item.type {
            case "MusicArtist": ArtistDetailView(artist: item)
            case "Playlist":    PlaylistDetailView(playlist: item)
            default:            AlbumDetailView(album: item)
            }
        }
        .navigationDestination(for: Filter.self) { f in
            FilterDetailView(filter: f).navigationTitle(f.name)
        }
    }

    private func categoryRow(_ cat: Category) -> some View {
        NavigationLink(value: cat) {
            Label {
                Text(cat.rawValue).font(.body)
            } icon: {
                Image(systemName: cat.icon).foregroundStyle(cat.tint).frame(width: 28)
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func categoryDestination(_ cat: Category) -> some View {
        switch cat {
        case .favorites:  FavoritesView()
        case .artists:    ArtistsView()
        case .albums:     AlbumsView()
        case .genres:     GenresView()
        case .tags:       TagsView()
        case .playlists:  PlaylistsView()
        case .downloaded: DownloadedView()
        }
    }

    /// Maps an item name to the single character used in the alphabet
    /// scrubber. Strips a leading "The " article so "The Beatles" sorts
    /// under B; non-alphabetic leading characters bucket under "#".
    static func indexLetter(for name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower.hasPrefix("the ") {
            s = String(s.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        guard let first = s.unicodeScalars.first else { return "#" }
        if CharacterSet.letters.contains(first) {
            return String(Character(first)).uppercased()
        }
        return "#"
    }

    /// Sorted list of the letter buckets actually present in `items`.
    /// Drives which letters render in the alphabet scrubber so tapping a
    /// letter always lands on a real row.
    static func indexLetters(for items: [BaseItem]) -> [String] {
        let present = Set(items.map { indexLetter(for: $0.Name) })
        var ordered = ("A"..."Z").map { String($0) }.filter { present.contains($0) }
        if present.contains("#") { ordered.insert("#", at: 0) }
        return ordered
    }
}

private extension ClosedRange where Bound == String {
    func map<T>(_ transform: (String) -> T) -> [T] {
        var out: [T] = []
        var s = lowerBound
        while s <= upperBound {
            out.append(transform(s))
            guard let scalar = s.unicodeScalars.first.flatMap({ Unicode.Scalar($0.value + 1) }) else { break }
            s = String(scalar)
        }
        return out
    }
}

/// Vertical A-Z strip pinned to the trailing edge of the library lists.
/// Tap a letter to jump to its first item; drag finger up/down to scrub.
///
/// While the finger is down, letters scale up Dock-style — the letter
/// directly under the touch grows the most and the magnification falls
/// off smoothly with distance, so the active letter is easy to read
/// without the user having to lift to check.
///
/// `onActiveChange` fires with the currently-focused letter (or nil on
/// release). Parents use that to drive an at-thumb overlay showing the
/// big version of the letter.
struct LetterIndex: View {
    let letters: [String]
    var onLetterTap: (String) -> Void
    var onActiveChange: (String?) -> Void = { _ in }

    @State private var dragLetter: String?
    @State private var dragY: CGFloat?
    private let rowHeight: CGFloat = 14
    private let rowSpacing: CGFloat = 1
    private let vPadding: CGFloat = 6
    /// Points within which a letter still feels the drag's magnification.
    /// Wider = more letters move; smaller = sharper "lens".
    private let falloff: CGFloat = 48
    /// Cap on how much the focal letter scales up under the touch.
    private let maxScale: CGFloat = 1.9

    private var rowStride: CGFloat { rowHeight + rowSpacing }

    var body: some View {
        VStack(spacing: rowSpacing) {
            ForEach(Array(letters.enumerated()), id: \.element) { idx, letter in
                let centerY = vPadding + (CGFloat(idx) + 0.5) * rowStride - rowSpacing / 2
                let scale = magnification(for: centerY)
                Text(letter)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(dragLetter == letter ? Color.accentColor : Color.white.opacity(0.75))
                    .frame(width: 16, height: rowHeight)
                    .scaleEffect(scale, anchor: .trailing)
                    .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.85), value: dragY)
            }
        }
        .padding(.vertical, vPadding)
        .padding(.horizontal, 3)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .opacity(0.45)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let totalHeight = CGFloat(letters.count) * rowStride - rowSpacing
                    let local = max(0, min(totalHeight, value.location.y - vPadding))
                    let idx = min(letters.count - 1, max(0, Int(local / rowStride)))
                    let letter = letters[idx]
                    dragY = value.location.y
                    if dragLetter != letter {
                        dragLetter = letter
                        onLetterTap(letter)
                        onActiveChange(letter)
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        #endif
                    }
                }
                .onEnded { _ in
                    dragLetter = nil
                    dragY = nil
                    onActiveChange(nil)
                }
        )
    }

    /// Dock-style magnification. Returns 1.0 when not dragging or when
    /// the finger is far from this letter; ramps toward `maxScale` as
    /// the touch approaches the letter's vertical centre.
    private func magnification(for centerY: CGFloat) -> CGFloat {
        guard let y = dragY else { return 1.0 }
        let distance = abs(centerY - y)
        guard distance < falloff else { return 1.0 }
        // Cosine ease — smooth, peaks at 1.0 when distance=0, hits 0
        // when distance==falloff. Multiplied by `maxScale - 1` and added
        // to 1 so the resting scale stays at 1.0.
        let normalized = distance / falloff
        let bump = (cos(normalized * .pi) + 1) / 2  // 0…1
        return 1.0 + (maxScale - 1.0) * bump
    }
}

/// Large centred letter shown while the user is dragging the alphabet
/// scrubber. Fades in fast (so the first letter shows immediately) and
/// fades out over ~half a second after the finger lifts.
struct LetterScrubOverlay: View {
    let letter: String?

    @State private var visible: Bool = false
    @State private var lastSeen: String = ""

    var body: some View {
        Text(letter ?? lastSeen)
            .font(.system(size: 140, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 220, height: 220)
            .background {
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.7)
            }
            .opacity(visible ? 0.95 : 0)
            .allowsHitTesting(false)
            .onChange(of: letter) { _, new in
                if let new {
                    lastSeen = new
                    withAnimation(.easeOut(duration: 0.08)) { visible = true }
                } else {
                    withAnimation(.easeOut(duration: 0.5)) { visible = false }
                }
            }
    }
}

/// Dedicated Favourites browser (Tracks / Albums / Artists) — mirrors the mac
/// `FavoritesContent_Mac`. Tracks play on tap; albums/artists push to detail.
struct FavoritesView: View {
    enum Mode: String, CaseIterable { case tracks = "Tracks", albums = "Albums", artists = "Artists" }
    @EnvironmentObject var auth: AuthManager
    @State private var mode: Mode

    init(initialMode: Mode = .tracks) {
        _mode = State(initialValue: initialMode)
    }
    @State private var tracks: [BaseItem] = []
    @State private var albums: [BaseItem] = []
    @State private var artists: [BaseItem] = []
    @State private var loading = false

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            Group {
                switch mode {
                case .tracks:  trackList
                case .albums:  grid(albums, isArtist: false)
                case .artists: grid(artists, isArtist: true)
                }
            }
            .overlay { if loading && tracks.isEmpty && albums.isEmpty && artists.isEmpty { ProgressView() } }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder private var trackList: some View {
        if tracks.isEmpty && !loading {
            ContentUnavailableView("No Favourite Tracks", systemImage: "heart",
                description: Text("Tap the heart on a track to add it here."))
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                        Button { AudioPlayer.shared.play(items: tracks, startAt: idx) } label: {
                            HStack(spacing: 12) {
                                JellyfinImage(itemId: track.AlbumId ?? track.Id, tag: track.AlbumPrimaryImageTag, maxWidth: 120, cornerRadius: 6)
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.Name).lineLimit(1)
                                    Text(track.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .trackContextMenu(track)
                        Divider().padding(.leading, 68)
                    }
                }
                Color.clear.frame(height: 100)
            }
        }
    }

    @ViewBuilder private func grid(_ items: [BaseItem], isArtist: Bool) -> some View {
        if items.isEmpty && !loading {
            ContentUnavailableView(isArtist ? "No Favourite Artists" : "No Favourite Albums", systemImage: "heart")
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            VStack(alignment: .leading, spacing: 6) {
                                Color.clear.aspectRatio(1, contentMode: .fit)
                                    .overlay(JellyfinImage(itemId: item.artworkItemId, tag: item.artworkTag, maxWidth: 400, cornerRadius: isArtist ? 999 : 10))
                                Text(item.Name).font(.subheadline).lineLimit(1)
                                if !isArtist {
                                    Text(item.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                Color.clear.frame(height: 100)
            }
        }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        loading = true
        defer { loading = false }
        let client = JellyfinClient(baseURL: url, auth: auth)
        async let t = client.favorites(type: "Audio", limit: 500)
        async let al = client.favorites(type: "MusicAlbum", limit: 500)
        async let ar = client.favorites(type: "MusicArtist", limit: 500)
        let tr = (try? await t) ?? [], alb = (try? await al) ?? [], art = (try? await ar) ?? []
        let vis = LibraryVisibilityStore.shared, ign = IgnoredTracksStore.shared
        tracks = ign.filter(vis.filter(tr))
        albums = vis.filter(alb)
        artists = vis.filter(art)
    }
}

struct ArtistsView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var items: [BaseItem] = []
    @State private var loading = false
    @State private var activeScrubLetter: String?
    @State private var scrollTarget: String?

    // Three flexible columns (fixed, not adaptive) so cell widths are
    // deterministic — same stable-layout reasoning as AlbumsView.
    let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    private let cacheKey = "artists"

    var body: some View {
        ZStack(alignment: .trailing) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(items) { artist in
                        NavigationLink(value: artist) {
                            VStack(spacing: 6) {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay(
                                        JellyfinImage(itemId: artist.Id, tag: artist.ImageTags?["Primary"], maxWidth: 300, cornerRadius: 200)
                                    )
                                Text(artist.Name).font(.subheadline).lineLimit(1).multilineTextAlignment(.center)
                                if let count = artist.AlbumCount {
                                    Text("\(count) album\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            IgnoreArtistToggleButton(item: artist)
                        }
                    }
                }
                .padding()
                Color.clear.frame(height: 100)
            }
            // Modern scroll API — survives in-flight momentum, unlike
            // ScrollViewReader.scrollTo which the deceleration animation
            // swallowed (scrubber did nothing while the list was still moving).
            .scrollPosition(id: $scrollTarget, anchor: .top)
            .scrollContentBackground(.hidden)
            .overlay { if loading && items.isEmpty { ProgressView() } }

            LetterIndex(letters: LibraryView.indexLetters(for: items), onLetterTap: { letter in
                if let target = items.first(where: { LibraryView.indexLetter(for: $0.Name) == letter }) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scrollTarget = target.Id
                    }
                }
            }, onActiveChange: { letter in
                activeScrubLetter = letter
            })
            .padding(.trailing, 4)

            LetterScrubOverlay(letter: activeScrubLetter)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false)
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
        if items.isEmpty { loading = true }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let fresh = try? await client.artists(limit: 500) {
            // Dedupe by Id — Jellyfin sometimes returns the same item
            // twice when version-grouped, which causes ForEach identity
            // collisions and breaks scroll boundaries in LazyVGrid.
            var seen = Set<String>()
            let unique = fresh.filter { seen.insert($0.Id).inserted }
            items = LibraryVisibilityStore.shared.filter(unique)
            LibraryCache.shared.write(cacheKey, value: unique)
        }
        loading = false
    }
}

struct AlbumsView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var items: [BaseItem] = []
    @State private var loading = false
    @State private var activeScrubLetter: String?
    @State private var scrollTarget: String?

    // Fixed two-column flexible layout instead of `.adaptive` so cell
    // widths are deterministic and the LazyVGrid's content-size estimate
    // doesn't shift while scrolling. Adaptive sizing combined with cells
    // whose intrinsic size could fluctuate (e.g. images that load late)
    // produced a scroll-boundary lock-up where scrolling past a certain
    // point made it impossible to scroll back above it.
    let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    private let cacheKey = "albums"

    var body: some View {
        ZStack(alignment: .trailing) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(items) { album in
                        NavigationLink(value: album) {
                            VStack(alignment: .leading, spacing: 6) {
                                // Square placeholder reserves the cell's
                                // image footprint regardless of whether
                                // the artwork has loaded. The image
                                // overlays it without participating in
                                // layout — so cell height is invariant
                                // to image load state.
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay(
                                        JellyfinImage(itemId: album.Id, tag: album.ImageTags?["Primary"], maxWidth: 400, cornerRadius: 10)
                                    )
                                Text(album.Name).font(.subheadline).lineLimit(1)
                                Text(album.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            IgnoreAlbumToggleButton(item: album)
                        }
                    }
                }
                .padding()
                Color.clear.frame(height: 100)
            }
            .scrollPosition(id: $scrollTarget, anchor: .top)
            .overlay { if loading && items.isEmpty { ProgressView() } }

            LetterIndex(letters: LibraryView.indexLetters(for: items), onLetterTap: { letter in
                if let target = items.first(where: { LibraryView.indexLetter(for: $0.Name) == letter }) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scrollTarget = target.Id
                    }
                }
            }, onActiveChange: { letter in
                activeScrubLetter = letter
            })
            .padding(.trailing, 4)

            LetterScrubOverlay(letter: activeScrubLetter)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false)
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
        if items.isEmpty { loading = true }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let fresh = try? await client.albums(limit: 500) {
            // Dedupe by Id — Jellyfin sometimes returns the same item
            // twice when version-grouped, which causes ForEach identity
            // collisions and breaks scroll boundaries in LazyVGrid.
            var seen = Set<String>()
            let unique = fresh.filter { seen.insert($0.Id).inserted }
            items = LibraryVisibilityStore.shared.filter(unique)
            LibraryCache.shared.write(cacheKey, value: unique)
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
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(.white.opacity(0.06))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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

// MARK: - Genres & Tags

/// All music genres on the server; tap one to browse its artists + albums.
/// Multi-genre entities ("Rock; Pop" — unsplit file tags the server kept as
/// one genre) are split for display; each displayed genre remembers the raw
/// server names so drilling in still matches everything.
struct GenresView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var genres: [BaseItem] = []
    @State private var loading = false
    private let cacheKey = "genres"

    /// display name → raw server genre names containing it, alphabetised.
    private var displayGenres: [(name: String, matches: [String])] {
        var map: [String: Set<String>] = [:]
        for g in genres {
            for part in LibraryView.splitGenre(g.Name) {
                map[part, default: []].insert(g.Name)
            }
        }
        return map
            .map { (name: $0.key, matches: Array($0.value).sorted()) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List(displayGenres, id: \.name) { g in
            NavigationLink(value: LibraryView.Filter(kind: .genre, name: g.name, matches: g.matches)) {
                Label {
                    Text(g.name).font(.body)
                } icon: {
                    Image(systemName: "guitars").foregroundStyle(.tint).frame(width: 28)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(.white.opacity(0.06))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if loading && genres.isEmpty { ProgressView() }
            else if genres.isEmpty && !loading {
                ContentUnavailableView("No Genres", systemImage: "guitars",
                    description: Text("Your server has no music genres set."))
            }
        }
        .task {
            if genres.isEmpty, let cached = LibraryCache.shared.read(cacheKey, as: [BaseItem].self) {
                genres = cached
            }
            await load()
        }
        .refreshable { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        if genres.isEmpty { loading = true }
        defer { loading = false }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let fresh = try? await client.musicGenres() {
            genres = fresh
            LibraryCache.shared.write(cacheKey, value: fresh)
        }
    }
}

/// All tags applied to music on the server; tap one to browse tagged items.
struct TagsView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var tags: [String] = []
    @State private var loading = false
    private let cacheKey = "tags"

    var body: some View {
        List(tags, id: \.self) { t in
            NavigationLink(value: LibraryView.Filter(kind: .tag, name: t)) {
                Label {
                    Text(t).font(.body)
                } icon: {
                    Image(systemName: "tag").foregroundStyle(.tint).frame(width: 28)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(.white.opacity(0.06))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if loading && tags.isEmpty { ProgressView() }
            else if tags.isEmpty && !loading {
                ContentUnavailableView("No Tags", systemImage: "tag",
                    description: Text("Tag albums or artists on your Jellyfin server and they'll appear here."))
            }
        }
        .task {
            if tags.isEmpty, let cached = LibraryCache.shared.read(cacheKey, as: [String].self) {
                tags = cached
            }
            await load()
        }
        .refreshable { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        if tags.isEmpty { loading = true }
        defer { loading = false }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let fresh = try? await client.musicTags() {
            tags = fresh
            LibraryCache.shared.write(cacheKey, value: fresh)
        }
    }
}

/// Artists / Albums browser for a genre or server tag, with a sticky radio:
/// "Start Radio" plays random tracks from this genre/tag, and the endless-mix
/// extender keeps drawing from the SAME genre/tag as the queue runs down.
struct FilterDetailView: View {
    let filter: LibraryView.Filter
    @EnvironmentObject var auth: AuthManager
    enum Mode: String, CaseIterable { case artists = "Artists", albums = "Albums" }
    @State private var mode: Mode = .albums
    @State private var artists: [BaseItem] = []
    @State private var albums: [BaseItem] = []
    @State private var loading = false
    @State private var startingRadio = false

    private let albumColumns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    private let artistColumns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            Button {
                startRadio()
            } label: {
                HStack {
                    if startingRadio { ProgressView().tint(.white) }
                    else { Image(systemName: "antenna.radiowaves.left.and.right") }
                    Text("Start \(filter.name) Radio")
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color.accentColor).foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(startingRadio)
            .padding(.horizontal)
            .padding(.bottom, 10)

            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            ScrollView {
                switch mode {
                case .artists:
                    LazyVGrid(columns: artistColumns, spacing: 18) {
                        ForEach(artists) { artist in
                            NavigationLink(value: artist) {
                                VStack(spacing: 6) {
                                    Color.clear.aspectRatio(1, contentMode: .fit)
                                        .overlay(JellyfinImage(itemId: artist.Id, tag: artist.ImageTags?["Primary"], maxWidth: 300, cornerRadius: 200))
                                    Text(artist.Name).font(.caption).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                case .albums:
                    LazyVGrid(columns: albumColumns, spacing: 18) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Color.clear.aspectRatio(1, contentMode: .fit)
                                        .overlay(JellyfinImage(itemId: album.Id, tag: album.ImageTags?["Primary"], maxWidth: 400, cornerRadius: 10))
                                    Text(album.Name).font(.subheadline).lineLimit(1)
                                    Text(album.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                Color.clear.frame(height: 100)
            }
            .overlay {
                if loading && artists.isEmpty && albums.isEmpty { ProgressView() }
                else if !loading && (mode == .artists ? artists.isEmpty : albums.isEmpty) {
                    ContentUnavailableView("No \(mode.rawValue)",
                        systemImage: filter.kind == .genre ? "guitars" : "tag",
                        description: Text("No \(mode.rawValue.lowercased()) match this \(filter.kind.rawValue.lowercased())."))
                }
            }
        }
        .padding(.top, 8)
        .task(id: filter) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        loading = true
        defer { loading = false }
        let client = JellyfinClient(baseURL: url, auth: auth)
        let isGenre = filter.kind == .genre
        // A displayed genre can map to several RAW server genres (unsplit
        // "Rock; Pop" file tags) — query each and merge, de-duped by id.
        var fetchedArtists: [BaseItem] = []
        var fetchedAlbums: [BaseItem] = []
        var seenArtist = Set<String>(), seenAlbum = Set<String>()
        for raw in filter.queryNames {
            async let ar = isGenre ? client.artists(genre: raw) : client.artists(tag: raw)
            async let al = isGenre ? client.albums(genre: raw) : client.albums(tag: raw)
            for a in (try? await ar) ?? [] where seenArtist.insert(a.Id).inserted { fetchedArtists.append(a) }
            for a in (try? await al) ?? [] where seenAlbum.insert(a.Id).inserted { fetchedAlbums.append(a) }
        }
        // Many libraries only genre/tag the ALBUMS — derive the artists from the
        // matching albums when the artist query itself comes back empty.
        if fetchedArtists.isEmpty {
            var seen = Set<String>()
            fetchedArtists = fetchedAlbums.compactMap { album -> BaseItem? in
                guard let a = album.AlbumArtists?.first, seen.insert(a.Id).inserted else { return nil }
                return .stub(id: a.Id, name: a.Name, type: "MusicArtist")
            }
        }
        let vis = LibraryVisibilityStore.shared
        artists = vis.filter(fetchedArtists)
            .sorted { $0.Name.localizedCaseInsensitiveCompare($1.Name) == .orderedAscending }
        albums = vis.filter(fetchedAlbums)
    }

    private func startRadio() {
        guard let url = auth.serverURL else { return }
        startingRadio = true
        Task {
            defer { startingRadio = false }
            await GenreTagRadio.start(filter.kind == .genre ? .genre : .tag,
                                      names: filter.queryNames,
                                      client: JellyfinClient(baseURL: url, auth: auth))
        }
    }
}

// MARK: - Downloaded (offline) — mirrors the CarPlay "Downloaded Music" breakdown

/// Entry screen for the Library "Downloaded" segment: four rows
/// (Artists / Albums / Tracks / Playlists) reading entirely from
/// DownloadManager's on-device state, so it works offline. Tracks is the
/// individual-only list, matching CarPlay.
struct DownloadedView: View {
    @ObservedObject private var dm = DownloadManager.shared
    @EnvironmentObject var auth: AuthManager

    var body: some View {
        List {
            if dm.completed.isEmpty {
                ContentUnavailableView("No Downloads",
                                       systemImage: "arrow.down.circle",
                                       description: Text("Download music from an album, artist, or playlist to listen offline."))
                    .listRowBackground(Color.clear)
            } else {
                Group {
                    NavigationLink { DownloadedArtistsView() } label: { menuRow("Artists", "person.circle", dm.downloadedArtistReps().count) }
                    NavigationLink { DownloadedAlbumsView() } label: { menuRow("Albums", "square.stack", dm.downloadedAlbumReps().count) }
                    NavigationLink { DownloadedTracksView() } label: { menuRow("Tracks", "music.note", dm.individuallyDownloadedTracks().count) }
                    NavigationLink { DownloadedPlaylistsView() } label: { menuRow("Playlists", "music.note.list", dm.downloadedPlaylistList().count) }
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(.white.opacity(0.06))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .task {
            // Backfill album provenance for albums downloaded before tracking
            // existed, so they appear under Albums (and their tracks leave the
            // Individual list). No-op offline / once everything's recorded.
            guard let url = auth.serverURL else { return }
            let client = JellyfinClient(baseURL: url, auth: auth)
            await dm.backfillDownloadedAlbums(using: client)
            // Persist cover art for downloads made before art-caching existed,
            // so they show artwork offline. No-op offline / once all cached.
            await dm.cacheMissingArtwork(using: client)
        }
    }

    private func menuRow(_ title: String, _ icon: String, _ count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 28).foregroundStyle(.tint)
            Text(title)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
        }
    }
}

/// Play / Shuffle buttons that queue the whole `tracks` array (continues to
/// the next track, like starting a playlist).
private struct DownloadedPlayBar: View {
    let tracks: [BaseItem]
    var body: some View {
        HStack(spacing: 12) {
            Button {
                AudioPlayer.shared.shuffle = false
                AudioPlayer.shared.play(items: tracks)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Color.accentColor).foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Button {
                AudioPlayer.shared.shuffle = true
                AudioPlayer.shared.play(items: tracks)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .disabled(tracks.isEmpty)
    }
}

/// A tappable track row that starts playback at its index against the full
/// `tracks` array (so the queue continues afterwards).
private struct DownloadedTrackRow: View {
    let index: Int
    let tracks: [BaseItem]
    var body: some View {
        let t = tracks[index]
        Button {
            AudioPlayer.shared.play(items: tracks, startAt: index)
        } label: {
            HStack(spacing: 12) {
                JellyfinImage(itemId: t.artworkItemId, tag: t.artworkTag, maxWidth: 120, cornerRadius: 6)
                    .frame(width: 44, height: 44)
                    .overlay(NowPlayingArtworkBadge(trackId: t.Id))
                VStack(alignment: .leading) {
                    Text(t.Name).lineLimit(1)
                    Text(t.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(t.durationSeconds.mmSS).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .trackContextMenu(t)
    }
}

private struct DownloadedTrackListBody: View {
    let tracks: [BaseItem]
    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(tracks.indices, id: \.self) { i in
                DownloadedTrackRow(index: i, tracks: tracks)
                    .padding(.vertical, 8)
                    .padding(.horizontal)
                Divider().padding(.leading, 56)
            }
        }
    }
}

struct DownloadedArtistsView: View {
    @ObservedObject private var dm = DownloadManager.shared
    var body: some View {
        let reps = dm.downloadedArtistReps()
        List(reps, id: \.Id) { rep in
            NavigationLink {
                DownloadedArtistDetailView(artistName: rep.primaryArtistName)
            } label: {
                HStack(spacing: 12) {
                    JellyfinImage(itemId: rep.artworkItemId, tag: rep.artworkTag, maxWidth: 180, cornerRadius: 28)
                        .frame(width: 56, height: 56)
                    Text(rep.primaryArtistName).font(.body)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(.white.opacity(0.06))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(BoleraBackground().ignoresSafeArea())
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DownloadedArtistDetailView: View {
    let artistName: String
    @ObservedObject private var dm = DownloadManager.shared
    var body: some View {
        // Two buckets: full albums (drill in) and "odd" tracks downloaded
        // individually / via a playlist (not part of a downloaded album).
        let albums = dm.downloadedAlbumReps(forArtist: artistName)
        let looseTracks = dm.looseDownloadedTracks(forArtist: artistName)
        let allTracks = dm.downloadedTracks(forArtist: artistName)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DownloadedPlayBar(tracks: allTracks).padding(.horizontal).padding(.top, 8)
                if !albums.isEmpty {
                    Text("Albums").font(.title3.bold()).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(albums, id: \.Id) { rep in
                                NavigationLink {
                                    DownloadedAlbumDetailView(albumId: rep.AlbumId ?? rep.Id,
                                                              title: rep.Album ?? rep.Name,
                                                              artist: rep.primaryArtistName)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        JellyfinImage(itemId: rep.artworkItemId, tag: rep.artworkTag, maxWidth: 400, cornerRadius: 10)
                                            .frame(width: 130, height: 130)
                                        Text(rep.Album ?? rep.Name).font(.subheadline).lineLimit(1)
                                            .frame(width: 130, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                if !looseTracks.isEmpty {
                    Text("Individual Tracks").font(.title3.bold()).padding(.horizontal)
                    DownloadedTrackListBody(tracks: looseTracks)
                }
                Color.clear.frame(height: 120)
            }
        }
        .background(BoleraBackground().ignoresSafeArea())
        .navigationTitle(artistName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DownloadedAlbumsView: View {
    @ObservedObject private var dm = DownloadManager.shared
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    var body: some View {
        let reps = dm.downloadedAlbumReps()
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(reps, id: \.Id) { rep in
                    NavigationLink {
                        DownloadedAlbumDetailView(albumId: rep.AlbumId ?? rep.Id,
                                                  title: rep.Album ?? rep.Name,
                                                  artist: rep.primaryArtistName)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Color.clear.aspectRatio(1, contentMode: .fit).overlay(
                                JellyfinImage(itemId: rep.artworkItemId, tag: rep.artworkTag, maxWidth: 400, cornerRadius: 10))
                            Text(rep.Album ?? rep.Name).font(.subheadline).lineLimit(1)
                            Text(rep.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            Color.clear.frame(height: 100)
        }
        .background(BoleraBackground().ignoresSafeArea())
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DownloadedAlbumDetailView: View {
    let albumId: String
    let title: String
    let artist: String
    @ObservedObject private var dm = DownloadManager.shared
    var body: some View {
        let tracks = dm.downloadedTracks(forAlbumId: albumId)
        ScrollView {
            VStack(spacing: 14) {
                if let art = tracks.first {
                    JellyfinImage(itemId: art.artworkItemId, tag: art.artworkTag, maxWidth: 600, cornerRadius: 14)
                        .frame(width: 240, height: 240).shadow(radius: 20)
                }
                Text(title).font(.title2.bold()).multilineTextAlignment(.center)
                Text(artist).foregroundStyle(.secondary)
                DownloadedPlayBar(tracks: tracks).padding(.horizontal)
                DownloadedTrackListBody(tracks: tracks)
                Color.clear.frame(height: 120)
            }
        }
        .background(BoleraBackground().ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DownloadedTracksView: View {
    @ObservedObject private var dm = DownloadManager.shared
    var body: some View {
        let tracks = dm.individuallyDownloadedTracks()
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if tracks.isEmpty {
                    ContentUnavailableView("No Individual Downloads",
                                           systemImage: "music.note",
                                           description: Text("Tracks you download one at a time appear here — not ones from a bulk album, artist, or playlist download."))
                        .padding(.top, 60)
                } else {
                    DownloadedPlayBar(tracks: tracks).padding(.horizontal).padding(.top, 8)
                    DownloadedTrackListBody(tracks: tracks)
                }
                Color.clear.frame(height: 120)
            }
        }
        .background(BoleraBackground().ignoresSafeArea())
        .navigationTitle("Tracks")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DownloadedPlaylistsView: View {
    @ObservedObject private var dm = DownloadManager.shared
    var body: some View {
        let playlists = dm.downloadedPlaylistList()
        List(playlists) { pl in
            let tracks = dm.downloadedTracks(forPlaylist: pl.id)
            NavigationLink {
                DownloadedPlaylistDetailView(playlistId: pl.id, title: pl.name)
            } label: {
                HStack(spacing: 12) {
                    JellyfinImage(itemId: tracks.first?.artworkItemId, tag: tracks.first?.artworkTag, maxWidth: 180, cornerRadius: 8)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading) {
                        Text(pl.name).font(.body)
                        Text("\(tracks.count) track\(tracks.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(.white.opacity(0.06))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(BoleraBackground().ignoresSafeArea())
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DownloadedPlaylistDetailView: View {
    let playlistId: String
    let title: String
    @ObservedObject private var dm = DownloadManager.shared
    var body: some View {
        let tracks = dm.downloadedTracks(forPlaylist: playlistId)
        ScrollView {
            VStack(spacing: 14) {
                DownloadedPlayBar(tracks: tracks).padding(.horizontal).padding(.top, 8)
                DownloadedTrackListBody(tracks: tracks)
                Color.clear.frame(height: 120)
            }
        }
        .background(BoleraBackground().ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
