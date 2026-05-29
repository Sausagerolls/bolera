import SwiftUI
import BoleraCore

struct LibraryView: View {
    enum Tab: String, CaseIterable { case artists = "Artists", albums = "Albums", playlists = "Playlists", downloaded = "Downloaded" }
    @State private var tab: Tab = .artists
    @EnvironmentObject var connectivity: ConnectivityStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            Group {
                // Offline: force the Downloaded view regardless of the selected
                // segment (keeping the switch as the single structural branch so
                // the view tree shape stays stable and nav doesn't reset).
                switch (connectivity.isOnline ? tab : .downloaded) {
                case .artists: ArtistsView()
                case .albums: AlbumsView()
                case .playlists: PlaylistsView()
                case .downloaded: DownloadedView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BoleraBackground())
        .navigationTitle("Library")
        .onChange(of: connectivity.isOnline) { _, online in
            if !online { tab = .downloaded }
        }
        .onAppear {
            if !connectivity.isOnline { tab = .downloaded }
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

struct ArtistsView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var items: [BaseItem] = []
    @State private var loading = false
    @State private var activeScrubLetter: String?

    private let cacheKey = "artists"

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
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
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(.white.opacity(0.06))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .overlay { if loading && items.isEmpty { ProgressView() } }

                LetterIndex(letters: LibraryView.indexLetters(for: items), onLetterTap: { letter in
                    if let target = items.first(where: { LibraryView.indexLetter(for: $0.Name) == letter }) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(target.Id, anchor: .top)
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
        }
        .navigationDestination(for: BaseItem.self) { item in
            switch item.type {
            case "MusicAlbum":  AlbumDetailView(album: item)
            case "MusicArtist": ArtistDetailView(artist: item)
            case "Playlist":    PlaylistDetailView(playlist: item)
            default:            ArtistDetailView(artist: item)
            }
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
        .navigationDestination(for: BaseItem.self) { item in
            AlbumDetailView(album: item)
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
            await dm.backfillDownloadedAlbums(using: JellyfinClient(baseURL: url, auth: auth))
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
                VStack(alignment: .leading) {
                    Text(t.Name).lineLimit(1)
                    Text(t.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(t.durationSeconds.mmSS).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
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
