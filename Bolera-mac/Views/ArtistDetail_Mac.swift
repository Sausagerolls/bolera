import SwiftUI
import BoleraCore

struct ArtistDetail_Mac: View {
    let artist: BaseItem
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var pinned: PinnedItemsStore
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var lastFm: LastFmService
    @EnvironmentObject var nav: MacNavCoordinator

    @State private var fullArtist: BaseItem?
    @State private var albums: [BaseItem] = []
    @State private var topTracks: [BaseItem] = []
    @State private var similar: [BaseItem] = []
    @State private var artwork: PlatformImage?
    @State private var favOverride: Bool?
    @State private var bio: String?
    @State private var bioExpanded: Bool = false

    private var current: BaseItem { fullArtist ?? artist }
    private var isFavorite: Bool {
        favOverride ?? (current.UserData?.IsFavorite ?? false)
    }
    private var isPinned: Bool { pinned.isPinned(itemId: current.Id) }

    private let albumColumns = [GridItem(.adaptive(minimum: 160), spacing: 16)]
    private let artistColumns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                backButtonRow
                header
                if let bio, !bio.isEmpty {
                    bioBlock(bio)
                }
                actionBar
                if !topTracks.isEmpty {
                    section("Top Tracks") {
                        topTracksList
                    }
                }
                if !albums.isEmpty {
                    section("Albums") {
                        LazyVGrid(columns: albumColumns, spacing: 18) {
                            ForEach(albums) { album in AlbumTile_Mac(item: album) }
                        }
                    }
                }
                if lastFm.hasAppCredentials && !similar.isEmpty {
                    section("Similar Artists") {
                        LazyVGrid(columns: artistColumns, spacing: 18) {
                            ForEach(similar) { a in ArtistTile_Mac(item: a) }
                        }
                    }
                }
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: artist.Id) { await load() }
    }

    private var backButtonRow: some View {
        HStack {
            Button { nav.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back (⌘[)")
            Spacer()
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 24) {
            ZStack {
                Color.gray.opacity(0.15)
                if let artwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.mic")
                        .font(.system(size: 72))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 220, height: 220)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 10)

            VStack(alignment: .leading, spacing: 6) {
                Text("Artist").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                Text(current.Name).font(.system(size: 38, weight: .bold)).lineLimit(2)
                HStack(spacing: 6) {
                    if albums.count > 0 {
                        Text("\(albums.count) albums").foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func bioBlock(_ text: String) -> some View {
        let collapsedLines = 3
        // Heuristic: only worth showing the toggle if the text plausibly
        // overflows three lines. ~220 chars or 3+ paragraph breaks does it.
        let needsToggle = text.count > 220 ||
                          text.components(separatedBy: "\n").count >= 4
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(needsToggle && !bioExpanded ? collapsedLines : nil)
                .fixedSize(horizontal: false, vertical: true)
            if needsToggle {
                Button(bioExpanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.2)) { bioExpanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tint)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await playInstantMix() }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(artist.Id.isEmpty)

            Button {
                Task { await playInstantMix(shuffle: true) }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .controlSize(.large)

            iconActionButton(isFavorite ? "heart.fill" : "heart",
                             active: isFavorite,
                             help: isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                toggleFavorite()
            }
            iconActionButton("arrow.down.circle",
                             help: "Download All Albums") {
                Task { await downloadAllAlbums() }
            }
            iconActionButton(isPinned ? "pin.slash" : "pin",
                             active: isPinned,
                             help: isPinned ? "Unpin from Sidebar" : "Pin to Sidebar") {
                pinned.togglePin(current)
            }
            Spacer()
        }
    }

    private func downloadAllAlbums() async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        for album in albums {
            if let songs = try? await client.songs(parentId: album.Id) {
                for song in songs where !downloads.isDownloaded(song.Id) {
                    downloads.download(song, using: client)
                }
            }
        }
    }

    @ViewBuilder
    private func iconActionButton(_ icon: String, active: Bool = false, help: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(active ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3).bold()
            content()
        }
    }

    private var topTracksList: some View {
        VStack(spacing: 0) {
            ForEach(Array(topTracks.prefix(10).enumerated()), id: \.element.id) { idx, song in
                HStack {
                    Group {
                        if player.current?.Id == song.Id {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                        } else {
                            Text("\(idx + 1)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 32, alignment: .trailing)
                    VStack(alignment: .leading) {
                        Text(song.Name).lineLimit(1)
                        Text(song.Album ?? "")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(song.durationSeconds.mmSS)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .contentShape(Rectangle())
                .onTapGesture {
                    let list = Array(topTracks.prefix(10))
                    player.play(items: list, startAt: idx)
                }
                if idx < min(10, topTracks.count) - 1 {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private func toggleFavorite() {
        guard let url = auth.serverURL else { return }
        let target = !isFavorite
        favOverride = target
        let client = JellyfinClient(baseURL: url, auth: auth)
        Task {
            do { try await client.setFavorite(current.Id, favorite: target) }
            catch { await MainActor.run { favOverride = !target } }
        }
    }

    private func playInstantMix(shuffle: Bool = false) async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let mix = try? await client.instantMix(itemId: current.Id, limit: 80) {
            var tracks = mix.filter { $0.type == "Audio" }
            if shuffle { tracks.shuffle() }
            await MainActor.run { player.play(items: tracks) }
        }
    }

    @MainActor
    private func load() async {
        favOverride = nil
        artwork = nil
        bioExpanded = false
        let albumsKey = "artist.\(artist.Id).albums"
        let tracksKey = "artist.\(artist.Id).topTracks"
        let similarKey = "artist.\(artist.Id).similar.v4"
        let bioKey = "artist.\(artist.Id).bio"
        albums = LibraryCache.shared.read(albumsKey, as: [BaseItem].self) ?? []
        topTracks = LibraryCache.shared.read(tracksKey, as: [BaseItem].self) ?? []
        similar = LibraryCache.shared.read(similarKey, as: [BaseItem].self) ?? []
        bio = LibraryCache.shared.read(bioKey, as: String.self)

        guard let url = auth.serverURL, !artist.Id.isEmpty else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        let header = ["Authorization": auth.authHeader()]

        let imgURL = client.imageURL(for: artist.Id, tag: artist.ImageTags?["Primary"], maxWidth: 600)

        // Sequential awaits. async-let / Task.detached over the AuthManager
        // class reference inside JellyfinClient trips a Swift 6 isolation
        // assertion at runtime → SIGABRT.
        if let imgURL = imgURL {
            if let img = await ImageCache.shared.load(url: imgURL, headers: header) {
                self.artwork = img
            }
        }
        if let full = try? await client.item(artist.Id) {
            fullArtist = full
            // Prefer Jellyfin's own Overview text if present.
            if let ov = full.Overview, !ov.isEmpty {
                bio = ov
                LibraryCache.shared.write(bioKey, value: ov)
            }
        }
        // Fall back to Last.fm bio when Jellyfin has nothing.
        if bio == nil, lastFm.hasAppCredentials {
            if let info = try? await lastFm.artistInfo(forName: artist.Name) {
                bio = info.summary
                LibraryCache.shared.write(bioKey, value: info.summary)
            }
        }
        if let a = try? await client.albumsForArtist(artist.Id, name: artist.Name) {
            let cleaned = dedupe(a.filter { $0.type == "MusicAlbum" })
            albums = cleaned
            LibraryCache.shared.write(albumsKey, value: cleaned)
        }
        // Top tracks: when Last.fm configured, fetch a wide pool of the
        // artist's tracks from Jellyfin, then reorder/filter by Last.fm's
        // global top tracks so the most-popular hits appear first. Falls
        // back to Jellyfin play-count ordering when Last.fm unavailable.
        let poolLimit = lastFm.hasAppCredentials ? 300 : 15
        if let t = try? await client.topTracksForArtist(artist.Id, name: artist.Name, limit: poolLimit) {
            let cleaned = dedupe(t)
            var ordered = cleaned
            if lastFm.hasAppCredentials,
               let lfTop = try? await lastFm.topTracks(forName: artist.Name, limit: 25) {
                ordered = Self.reorderByLastFm(localTracks: cleaned, lastFmNames: lfTop.map { $0.name })
            }
            let trimmed = Array(ordered.prefix(10))
            topTracks = trimmed
            LibraryCache.shared.write(tracksKey, value: trimmed)
        }
        // Similar artists via Last.fm. Only show artists the user actually
        // has in their library — Last.fm names get resolved against
        // Jellyfin search, diacritic-insensitive.
        if lastFm.hasAppCredentials {
            if let lfNames = try? await lastFm.similarArtists(forName: artist.Name, limit: 25) {
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
                similar = resolved
                LibraryCache.shared.write(similarKey, value: resolved)
            }
        } else {
            similar = []
        }
    }

    /// ForEach crashes if it sees duplicate IDs in its data — strip dupes.
    private func dedupe(_ items: [BaseItem]) -> [BaseItem] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0.Id).inserted }
    }

    /// Normalize a track title for fuzzy matching: lowercase, fold
    /// diacritics, strip trailing parenthesised suffix, collapse whitespace.
    /// `Gimme! Gimme! Gimme! (A Man After Midnight)` → `gimme! gimme! gimme!`
    static func normalize(_ title: String) -> String {
        var s = title.lowercased()
        s = s.folding(options: .diacriticInsensitive, locale: .current)
        s = s.replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*$",
                                   with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+",
                                   with: " ",
                                   options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Reorder `localTracks` so anything matching a Last.fm top-track name
    /// comes first, in Last.fm's ranking. Unmatched local tracks follow,
    /// preserving their server order, so the list never goes empty.
    static func reorderByLastFm(localTracks: [BaseItem],
                                lastFmNames: [String]) -> [BaseItem] {
        var byNorm: [String: [BaseItem]] = [:]
        for t in localTracks {
            byNorm[normalize(t.Name), default: []].append(t)
        }
        var picked: [BaseItem] = []
        var pickedIds: Set<String> = []
        for name in lastFmNames {
            let key = normalize(name)
            guard let candidates = byNorm[key] else { continue }
            for c in candidates where pickedIds.insert(c.Id).inserted {
                picked.append(c)
                break  // one local track per Last.fm rank
            }
        }
        let remainder = localTracks.filter { !pickedIds.contains($0.Id) }
        return picked + remainder
    }
}

private extension Double {
    var mmSS: String {
        guard !isNaN, isFinite else { return "0:00" }
        let total = max(0, Int(self))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
